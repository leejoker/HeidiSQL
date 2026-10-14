# 会话管理器 PostgreSQL 数据库列表修复 — 设计文档

**日期**：2026-10-14
**状态**：待实现（已通过头脑风暴确认关键决策）
**目标模块**：`source/`（HeidiSQL 主 GUI，Lazarus/FPC）
**关联代码**：`connections.pas`（`Tconnform` 会话管理器）、`dbconnection.pas`（`TPgConnection`）、`dbstructures.pas` / `dbstructures.postgresql.pas`（SQL provider）

---

## 1. 背景与根因

在会话管理器（`Tconnform`）里，Database(s) 输入框右侧的 `»` 按钮会临时建立一条连接并拉取数据库列表
（`Tconnform.editDatabasesRightButtonClick`）。对 PostgreSQL 会话，该操作稳定失败：

```
/* [ai_agent] Connecting to 10.10.239.167 via PostgreSQL (TCP/IP), username root, using password: Yes ... */
/* [ai_agent] connection to server at "10.10.239.167", port 5432 failed: FATAL:  database "root" does not exist */
```

根因链（已核实到行）：

1. `connections.pas:1344` 在建立临时连接后**无条件**清空库名：`Connection.Parameters.AllDatabasesStr := '';`
2. `dbconnection.pas:2882-2883` 只在库名非空时才把 `dbname` 放进 conninfo；
3. libpq 在没有 `dbname` 时的默认行为是**用用户名当库名**，于是尝试连接 `database "root"`，报 FATAL；
4. 该路径的异常被 `connections.pas:1365-1367` 静默吞掉，只有日志里能看到失败，界面上表现为"点了 `»` 没反应/空菜单"。

为什么清空逻辑本身没错：MySQL/MSSQL/Interbase/Redis 清空库名后仍能连上各自的默认库，拉列表反而更稳；
**只有 PostgreSQL 必须先连上一个真实存在的数据库**才能发查询（`pg_database` 虽然是全集群共享的，但连接本身需要 `dbname`）。

同一个根因还有第二个表现（本次不修，见 §3 非目标）：会话本身 Databases 字段为空的 PG 会话，
在主树连接阶段同样会因 libpq 回退到用户名而失败。

## 2. 关键决策（头脑风暴结论）

| 维度 | 决策 |
|---|---|
| 修复入口 | 只修 `»` 按钮这条路径，不做全局兜底 |
| PG 库名来源 | 优先用会话已配置的库名（该会话此前能连上，说明它有效）；库名为空时用维护库 `postgres` |
| 其他引擎 | `AllDatabasesStr := ''` 行为保持不变 |
| SQL 归属 | PG 的"列库"SQL 从表单移入 SQL provider（新增 `TQueryId`），表单不再持有 SQL |
| 列表内容 | 语义不变：仍 `datistemplate = FALSE`，不新增 `datallowconn` 过滤、不新增 `ORDER BY` |
| 失败提示 | 沿用现状（静默 + 日志），本次不改为可见提示 |
| 进程 | 先写本设计文档，确认后直接实现 |

### 非目标（YAGNI）

- 不给 `TPgConnection.SetActive` 加全局兜底：不改变"PG 会话未填库名时主树连接失败"的现状
- 不在 `»` 拉库失败时弹提示框（仍只记日志，菜单为空）
- 不引入 `template1` 重试链（`postgres` 不存在时仍失败，属已知限制）
- 不改动 `createdatabase.pas` / `copytable.pas` 等其他调用 `AllDatabases` 的地方

## 3. 设计

### 3.1 变更点总览

| 文件 | 变更 |
|---|---|
| `source/dbstructures.pas` | `TQueryId` 末尾追加 `qListDatabases` |
| `source/dbstructures.postgresql.pas` | `TPostgreSQLProvider.GetSql` 实现 `qListDatabases` |
| `source/dbconnection.pas` | `TDBConnection` 新增 public 虚方法 `GetDatabaseNames`；`TPgConnection` override |
| `source/connections.pas` | `editDatabasesRightButtonClick`：PG 保留/兜底库名，改用 `GetDatabaseNames` |

### 3.2 SQL provider 新增查询位

`dbstructures.pas`，`TQueryId` 枚举**末尾**追加（追加不改变既有序号）：

```pascal
    qPgRolemanDefaultPrivGrant,
    qPgRolemanDefaultPrivRevoke,
    qListDatabases
    );
```

`qListDatabases` 的语义是"列出服务器上的物理数据库名"，供连接对话框的库选择器使用。
base `TSqlProvider.GetSql` 的 `else` 分支返回空串，因此 `Has(qListDatabases)` 对未实现的引擎自动为
`False`，无需为其他引擎补实现。

`dbstructures.postgresql.pas`，`TPostgreSQLProvider.GetSql` 新增分支：

```pascal
    qListDatabases: Result := 'SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = FALSE';
```

与今天的表单内硬编码 SQL（`connections.pas:1353`）语义完全一致，只是显式限定 `pg_catalog`。

### 3.3 连接层新增"物理库名"API

`dbconnection.pas` 中 `TDBConnection`（public 区，紧邻 `RefreshAllDatabases`）：

```pascal
      // Physical database names, for the connection dialog's database picker.
      // Differs from AllDatabases on PostgreSQL, where AllDatabases lists schemata for the tree.
      function GetDatabaseNames: TStringList; virtual;
```

默认实现保持其他引擎现状：

```pascal
function TDBConnection.GetDatabaseNames: TStringList;
begin
  Result := AllDatabases;
end;
```

`TPgConnection` override（可见性与基类一致）：

```pascal
function TPgConnection.GetDatabaseNames: TStringList;
begin
  Result := GetCol(FSqlProvider.GetSql(qListDatabases));
end;
```

这样表单侧不再有"PG 走一条 SQL、其他引擎走 `AllDatabases`"的引擎分支，也不持有 SQL 字面量，
符合 AGENTS.md §5（UI 不直接拼 SQL）与 §14（不在表单里硬编码 SQL）。

**返回值所有权**：契约是"调用方负责 `Free` 返回值"，与今天调用点的写法一致——
调用点本来就在读完菜单项后 `Databases.Free`。两个实现分支的所有权形态刻意保持与改动前逐位相同：

- 非 PG：`Result := AllDatabases;` 直接透传连接内部列表（`TDBConnection.ClearCache` 与析构都不释放
  `FAllDatabases`，今天正是这里的 `Free` 释放它，因此不能改成返回副本，否则每次点 `»` 会多一份泄漏）；
- PG：`GetCol` 返回新建列表，`Free` 同样正确。

即：`GetDatabaseNames` 只做"选哪条 SQL"的分流，不改变任何一方的所有权形态。

### 3.4 表单侧：保留/兜底库名

`connections.pas`，`editDatabasesRightButtonClick` 中把无条件的清空改为按引擎分组。
常量定义在使用点附近的实现段，不放进 `const.inc`：

```pascal
const
  PG_FALLBACK_DATABASE = 'postgres';
```

```pascal
    Params := CurrentParams;
    Connection := Params.CreateConnection(Self);
    if Params.NetTypeGroup = ngPgSQL then begin
      // PostgreSQL cannot connect without an existing database: libpq falls back to
      // the user name. Keep the session's database, use the maintenance one if empty.
      if Connection.Parameters.AllDatabasesStr.IsEmpty then
        Connection.Parameters.AllDatabasesStr := PG_FALLBACK_DATABASE;
    end else
      Connection.Parameters.AllDatabasesStr := '';
```

取列表处，删掉引擎分支：

```pascal
      Connection.Active := True;
      Databases := Connection.GetDatabaseNames;
```

`CurrentParams` 已经把 Databases 输入框的当前内容带进 `AllDatabasesStr`（`connections.pas:760`），
所以"会话已配置库名"指的是用户此刻在表单里看到的值，不依赖注册表中保存的旧值。

### 3.5 数据流

1. 用户点 `»` → `CurrentParams` 复制当前表单参数 → `CreateConnection` 建临时连接；
2. PG：库名保留（空则 `postgres`）；其他引擎：清空库名（保持现状）；
3. `Connection.Active := True` → `DoAfterConnect` 照旧执行 information_schema 对象名探测；
4. `GetDatabaseNames` → PG 走 provider 的 `pg_database` 查询，其他引擎走各自的 `GetAllDatabases`；
5. 结果生成 `FPopupDatabases` 菜单项（PG 为单选 `RadioItem`）→ 弹窗 → 勾选写回
   `editDatabases.Text`（分号拼接）。

### 3.6 错误处理

不变：整段仍在 `try ... except` 中静默处理，失败只写日志（`TDBConnection.Log` → `MainForm.LogSQL`），
菜单为空。验收时以日志中不再出现 `database "root" does not exist` 为准。

## 4. 验收与测试

| 项 | 方法 | 通过标准 |
|---|---|---|
| 编译 | `make build-qt6`（Release / qt6） | 零新增错误，无新增警告类别 |
| 主验收 | 会话管理器选 PG 会话（库名已填，如 `ai_agent`）→ 点 `»` | 弹出物理数据库列表，可勾选写回；日志无 `database "root" does not exist` |
| 边界（空库名） | PG 会话清空 Databases → 点 `»` | 以 `postgres` 连接并列出库；服务器无 `postgres` 库时仍失败（已知限制） |
| 回归（MySQL） | MySQL 会话点 `»` | 行为与改动前一致（临时连接不带库名、列出全部库） |
| 回归（MSSQL/Redis） | 同上 | 行为与改动前一致（走 `AllDatabases` 默认实现） |

若本机可达 10.10.239.167（PostgreSQL），用改动后的二进制直接实测；否则由报障者在其环境验收。

## 5. 风险与限制

- PG 服务器上 `postgres` 库被删除时，"库名为空"的场景仍失败（不引入 `template1` 重试链）。
- PG 会话配置的库已被删除时，`»` 也会失败。改动前该场景只有在"用户名恰好等于某个存在的库名"时才会
  偶然成功，这种偶然成功会消失——属于更正确、更可预期的行为。
- `GetDatabaseNames` 是 `TDBConnection` 的新公开 API；除本处外暂无调用方，未做其他引擎的特化实现。
