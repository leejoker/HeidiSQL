# 会话管理器 PostgreSQL 数据库列表修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让会话管理器的 `»`（拉取数据库列表）按钮在 PostgreSQL 会话上可用，不再因 libpq 把用户名当库名而报 `FATAL: database "<user>" does not exist`。

**Architecture:** 把 PG 的"列库"SQL 从表单收进 SQL provider（新增一个 `TQueryId`）；在连接层新增 `GetDatabaseNames`（PG 走 provider SQL，其余引擎保持 `AllDatabases` 透传，所有权形态不变）；表单只负责参数准备——PG 保留会话库名（空则用维护库 `postgres`），其余引擎照旧清空库名——然后调用该 API。

**Tech Stack:** Object Pascal（`{$mode delphi}{$H+}`）、FPC 3.2.2 + Lazarus 4.x、Qt6 Release 构建、SQL provider 模式（`dbstructures.pas` / `dbstructures.postgresql.pas`）。

**设计依据：** `docs/superpowers/specs/2026-10-14-session-manager-pg-database-list-design.md`（已批准，commit `5cf27ad2`）。规格与计划冲突时以规格为准。

## Global Constraints

- 每个 `.pas` 保持 `{$mode delphi}{$H+}`；**不新增单元、不新增设置项、不改 `heidisql.lpi` / `Makefile` / 构建模式**。
- 不在表单里硬编码 SQL（AGENTS.md §14），不拼接标识符（§5）——本次新增 SQL 只出现在 provider 里。
- 不新增用户可见文案，因此无需 `_()` / `f_()`（若执行时发现需要新增文案，必须包 `_()`）。
- 不提交构建产物：`bin/`、`out/`、`*.ppu`、`*.o`（本计划只 `git add` 被改的 `.pas`）。
- 提交信息用英文 conventional 前缀（`feat:` / `fix:` / `refactor:`）。
- **标准编译门禁**（每个任务末尾都要跑，逐字照抄）：

```bash
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:/data/fpc_tools/lazarus:$PATH
cd /data/projects_local/pascal/HeidiSQL
make build-qt6 > /tmp/heidisql-build.log 2>&1; echo "exit=$?"; tail -5 /tmp/heidisql-build.log
```

期望：`exit=0`，日志末行为 `renamed './out/heidisql' -> './out/qt6/heidisql'`（GNU coreutils 的 `mv -v` 措辞，个别版本为 `'./out/heidisql' -> './out/qt6/heidisql'`），日志中不出现 `Fatal:`。
（注意不能用 `make ... | tail` 判断退出码——管道退出码来自 `tail`。）

## Verification strategy（为什么没有"写失败测试"步骤）

本仓库的自动化测试只有 `tests/*.lpr` 控制台程序，且只覆盖不依赖 LCL 的单元（`redisclient`、`dbeaver_import`，见 `README.md:48` 与 `README.md:59`）。本次改动落在 LCL 依赖链上：`dbstructures.pas`（interface `uses ... Graphics`）→ implementation `uses apphelpers` → `laz.VirtualTrees` → SynEdit/LCL widgetset。已实测无法用 `fpc` 无界面链接：即使补齐 `lcl/units/x86_64-linux{,/qt6}`、`lazutils`、`virtualtreeview/lib/x86_64-linux-qt6`、`lclextensions/lib/x86_64-linux-qt6` 后，仍继续要求 SynEdit 等 GUI 包。

因此本计划沿用仓库既有的 GUI 任务做法（参见 `.git/sdd/task-10-report.md`）：**每个任务以"编译门禁 + 源码断言（grep）"验收**，最后一个任务做**真机手工验收**。不要为本次改动新建测试工程（YAGNI）。

---

### Task 1: SQL provider 新增 `qListDatabases`

**Files:**
- Modify: `source/dbstructures.pas:78-80`（`TQueryId` 枚举末尾）
- Modify: `source/dbstructures.postgresql.pas:925-931`（`TPostgreSQLProvider.GetSql` 的 case 末尾）

**Interfaces:**
- Consumes: 无
- Produces:
  - `TQueryId.qListDatabases`（枚举值，位于 `TQueryId` 末尾）
  - `TPostgreSQLProvider.GetSql(qListDatabases): string` = `SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = FALSE`
  - 其他引擎未实现该 id：base `TSqlProvider.GetSql` 的 `else Result := ''`，故 `Has(qListDatabases) = False`（见 `source/dbstructures.pas:242`）

- [ ] **Step 1: 记录改动前的编译基线**

```bash
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:/data/fpc_tools/lazarus:$PATH
cd /data/projects_local/pascal/HeidiSQL
make build-qt6 > /tmp/heidisql-build-baseline.log 2>&1; echo "exit=$?"; grep -c "Warning:" /tmp/heidisql-build-baseline.log; tail -3 /tmp/heidisql-build-baseline.log
```

期望：`exit=0`，并把 warning 数量记下来，供后续对比（只允许"不新增 warning 类别/数量"）。

- [ ] **Step 2: 在 `TQueryId` 末尾追加枚举值**

把 `source/dbstructures.pas` 中：

```pascal
    qPgRolemanDefaultPrivGrant,
    qPgRolemanDefaultPrivRevoke
    );
```

改为：

```pascal
    qPgRolemanDefaultPrivGrant,
    qPgRolemanDefaultPrivRevoke,
    qListDatabases
    );
```

> 必须追加在末尾：追加不改变既有枚举序号，且 `TSqlProvider.GetSql` 的 `else` 分支返回空串，其他引擎无需补实现。

- [ ] **Step 3: 在 PG provider 中实现该查询位**

把 `source/dbstructures.postgresql.pas` 中：

```pascal
    qPgRolemanDefaultPrivRevoke: Result :=
      'ALTER DEFAULT PRIVILEGES FOR ROLE %s%s REVOKE %s ON %s FROM %s';

    qAutoInc: Result := 'SERIAL';
```

改为：

```pascal
    qPgRolemanDefaultPrivRevoke: Result :=
      'ALTER DEFAULT PRIVILEGES FOR ROLE %s%s REVOKE %s ON %s FROM %s';

    // Physical database names, for the connection dialog's database picker.
    // pg_database is cluster-wide, so this works from any connected database.
    qListDatabases: Result :=
      'SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = FALSE';

    qAutoInc: Result := 'SERIAL';
```

> SQL 语义与移入前的 `connections.pas:1353` 完全一致（仍是 `datistemplate = FALSE`，不加 `datallowconn`、不加 `ORDER BY`），只是显式限定 `pg_catalog`。

- [ ] **Step 4: 编译门禁**

Run: 见 Global Constraints 的标准编译命令。
Expected: `exit=0`，无 `Fatal:`，warning 数与 Step 1 基线相同。

- [ ] **Step 5: 源码断言**

```bash
cd /data/projects_local/pascal/HeidiSQL
grep -n "qListDatabases" source/dbstructures.pas source/dbstructures.postgresql.pas
```

Expected: 恰好 2 处命中（`source/dbstructures.pas` 的枚举、`source/dbstructures.postgresql.pas` 的 case 分支）。

- [ ] **Step 6: 提交**

```bash
cd /data/projects_local/pascal/HeidiSQL
git add source/dbstructures.pas source/dbstructures.postgresql.pas
git commit -m "feat: add qListDatabases query id for the PostgreSQL database picker"
```

---

### Task 2: 连接层新增 `GetDatabaseNames`

**Files:**
- Modify: `source/dbconnection.pas:553`（`TDBConnection` public 区声明）
- Modify: `source/dbconnection.pas:4852-4864` 之后（`TDBConnection.GetAllDatabases` 实现之后）
- Modify: `source/dbconnection.pas:736-748`（`TPgConnection` 的 public 区声明）
- Modify: `source/dbconnection.pas:4927` 之后（`TPGConnection.GetAllDatabases` 实现之后）

**Interfaces:**
- Consumes: `TQueryId.qListDatabases`（Task 1）；`FSqlProvider`（`TDBConnection` 的 `private` 字段，同单元可见）；`GetCol(SQL: String; ...): TStringList`；`AllDatabases: TStringList`（public 属性）
- Produces:
  - `TDBConnection.GetDatabaseNames: TStringList; virtual;`（public）
  - `TPgConnection.GetDatabaseNames: TStringList; override;`（public）
  - 契约：调用方负责 `Free` 返回值。非 PG 分支**必须**透传 `AllDatabases`（连接内部列表），**不得**改成返回副本——`TDBConnection.ClearCache` 和析构都不会释放 `FAllDatabases`，今天正是调用点 `Databases.Free` 释放它（`connections.pas:1364`），改成副本会让每次点 `»` 泄漏一份列表。

- [ ] **Step 1: 声明基类虚方法**

把 `source/dbconnection.pas` 中：

```pascal
      function RefreshAllDatabases: TStringList;
      function GetDBObjects(db: String; Refresh: Boolean=False; OnlyNodeType: TListNodeType=lntNone): TDBObjectList;
```

改为：

```pascal
      function RefreshAllDatabases: TStringList;
      // Physical database names, for the connection dialog's database picker.
      // Differs from AllDatabases on PostgreSQL, where AllDatabases lists schemata for the tree.
      function GetDatabaseNames: TStringList; virtual;
      function GetDBObjects(db: String; Refresh: Boolean=False; OnlyNodeType: TListNodeType=lntNone): TDBObjectList;
```

- [ ] **Step 2: 实现基类默认行为**

把 `source/dbconnection.pas` 中：

```pascal
function TDBConnection.GetAllDatabases: TStringList;
begin
  // Get user passed delimited list
  // Ignore value in case of ntSQLiteEncrypted, when AllDatabasesStr holds encryption parameters
  if not Assigned(FAllDatabases) then begin
    if (FParameters.AllDatabasesStr <> '') and (not FParameters.IsAnySQLite) then begin
      FAllDatabases := FParameters.AllDatabasesList;
      ApplyIgnoreDatabasePattern(FAllDatabases);
    end;
  end;
  Result := FAllDatabases;
end;
```

改为（在该函数后新增一个函数，其余文字不变）：

```pascal
function TDBConnection.GetAllDatabases: TStringList;
begin
  // Get user passed delimited list
  // Ignore value in case of ntSQLiteEncrypted, when AllDatabasesStr holds encryption parameters
  if not Assigned(FAllDatabases) then begin
    if (FParameters.AllDatabasesStr <> '') and (not FParameters.IsAnySQLite) then begin
      FAllDatabases := FParameters.AllDatabasesList;
      ApplyIgnoreDatabasePattern(FAllDatabases);
    end;
  end;
  Result := FAllDatabases;
end;


function TDBConnection.GetDatabaseNames: TStringList;
begin
  Result := AllDatabases;
end;
```

- [ ] **Step 3: 声明 PG 覆盖**

把 `source/dbconnection.pas` 的 `TPgConnection` public 区中：

```pascal
      function GetCreateCode(Obj: TDBObject): String; override;
      function ConnectionInfo: TStringList; override;
```

改为：

```pascal
      function GetCreateCode(Obj: TDBObject): String; override;
      function ConnectionInfo: TStringList; override;
      function GetDatabaseNames: TStringList; override;
```

- [ ] **Step 4: 实现 PG 覆盖**

把 `source/dbconnection.pas` 中（`TPGConnection.GetAllDatabases` 的结尾与其后的 SQLite 实现之间）：

```pascal
    ApplyIgnoreDatabasePattern(FAllDatabases);
  end;
  Result := FAllDatabases;
end;


function TSQLiteConnection.GetAllDatabases: TStringList;
```

改为：

```pascal
    ApplyIgnoreDatabasePattern(FAllDatabases);
  end;
  Result := FAllDatabases;
end;


function TPGConnection.GetDatabaseNames: TStringList;
begin
  // Physical databases, while AllDatabases lists schemata for the tree
  Result := GetCol(FSqlProvider.GetSql(qListDatabases));
end;


function TSQLiteConnection.GetAllDatabases: TStringList;
```

> `connections.pas` 里被替换掉的那条 SQL 已经由 Task 1 的 provider 分支 + 这里的调用接力，表单不再持有 SQL。

- [ ] **Step 5: 编译门禁**

Run: 见 Global Constraints 的标准编译命令。
Expected: `exit=0`，无 `Fatal:`，warning 数不超过 Task 1 基线。

- [ ] **Step 6: 源码断言**

```bash
cd /data/projects_local/pascal/HeidiSQL
grep -n "GetDatabaseNames" source/dbconnection.pas
```

Expected: 恰好 4 处命中——基类声明、基类实现、PG 声明、PG 实现（`virtual;` / `override;` 各 1）。

- [ ] **Step 7: 提交**

```bash
cd /data/projects_local/pascal/HeidiSQL
git add source/dbconnection.pas
git commit -m "feat: add TDBConnection.GetDatabaseNames for the database picker"
```

---

### Task 3: 会话管理器只对 PG 保留库名并改用新 API

**Files:**
- Modify: `source/connections.pas:1332-1355`（`Tconnform.editDatabasesRightButtonClick`）

**Interfaces:**
- Consumes: `TDBConnection.GetDatabaseNames: TStringList`（Task 2）
- Produces: 无对外接口；行为变化——PG 临时连接不再清空库名，其余引擎不变

- [ ] **Step 1: 新增维护库常量**

把 `source/connections.pas` 中（`{$R *.lfm}` 与 `GetWindowCaption` 之后、`editDatabasesRightButtonClick` 之前的位置插入即可，下面给出紧随其后的锚点）：

```pascal
procedure Tconnform.editDatabasesRightButtonClick(Sender: TObject);
var
  Connection: TDBConnection;
  Params: TConnectionParameters;
  Item: TMenuItem;
  DB: String;
  Databases: TStringList;
begin
  if FPopupDatabases = nil then begin
    // Try to connect and lookup database names
    Params := CurrentParams;
    Connection := Params.CreateConnection(Self);
    Connection.Parameters.AllDatabasesStr := '';
```

改为：

```pascal
// PostgreSQL cannot connect without an existing database: libpq would fall back to
// the user name, so use the maintenance database when the session provides none.
const
  PG_FALLBACK_DATABASE = 'postgres';


procedure Tconnform.editDatabasesRightButtonClick(Sender: TObject);
var
  Connection: TDBConnection;
  Params: TConnectionParameters;
  Item: TMenuItem;
  DB: String;
  Databases: TStringList;
begin
  if FPopupDatabases = nil then begin
    // Try to connect and lookup database names
    Params := CurrentParams;
    Connection := Params.CreateConnection(Self);
    if Params.NetTypeGroup = ngPgSQL then begin
      if Connection.Parameters.AllDatabasesStr.IsEmpty then
        Connection.Parameters.AllDatabasesStr := PG_FALLBACK_DATABASE;
    end else
      Connection.Parameters.AllDatabasesStr := '';
```

> `CurrentParams` 会把 Databases 输入框当前内容带进 `AllDatabasesStr`（`source/connections.pas:760`），因此"保留会话库名"指的是用户此刻在表单里看到的值。

- [ ] **Step 2: 改用连接层 API，删掉引擎分支**

把同一过程中：

```pascal
      Connection.Active := True;
      if Params.NetTypeGroup = ngPgSQL then
        Databases := Connection.GetCol('SELECT datname FROM pg_database WHERE datistemplate=FALSE')
      else
        Databases := Connection.AllDatabases;
```

改为：

```pascal
      Connection.Active := True;
      Databases := Connection.GetDatabaseNames;
```

（`Databases.Free` 一行不动：所有权契约见 Task 2 的 Interfaces。）

- [ ] **Step 3: 编译门禁**

Run: 见 Global Constraints 的标准编译命令。
Expected: `exit=0`，无 `Fatal:`，warning 数不超过 Task 1 基线。

- [ ] **Step 4: 源码断言**

```bash
cd /data/projects_local/pascal/HeidiSQL
grep -n "PG_FALLBACK_DATABASE\|GetDatabaseNames\|SELECT datname FROM pg_database" source/connections.pas
```

Expected: 命中 `PG_FALLBACK_DATABASE` 2 处（常量定义 + 使用）、`GetDatabaseNames` 1 处；`SELECT datname FROM pg_database` **0 处**（SQL 已从表单移除）。

- [ ] **Step 5: 提交**

```bash
cd /data/projects_local/pascal/HeidiSQL
git add source/connections.pas
git commit -m "fix: list databases for PostgreSQL sessions in the session manager"
```

---

### Task 4: 真机手工验收

**Files:** 无源码改动（纯验收）。

**Interfaces:**
- Consumes: 前三个任务的构建产物 `out/qt6/heidisql`
- Produces: 验收结论（写入任务报告；未通过则回到对应任务修）

**环境事实（已核实）：** 本机 `DISPLAY=:2` 可用、`/usr/bin/psql` 存在、`10.10.239.167:5432` 可达。

- [ ] **Step 1: 启动被测程序**

```bash
cd /data/projects_local/pascal/HeidiSQL
./out/qt6/heidisql &
```

Expected: 主窗口出现；会话管理器入口为菜单里的 `Session manager`（`actSessionManager`）。

> 注意：`DISPLAY=:2` 是用户的真实桌面，启动会在桌面上弹窗。执行前先征得用户同意；用户不便时把本任务整段交给用户手工做，agent 只负责收集结果。

- [ ] **Step 2: 主验收——PG 会话点 `»`**

在会话管理器左侧选中 PG 会话（报障会话名 `ai_agent`，或任意库名已填的 PG 会话）→ 点 Databases 输入框右侧的 `»`。

Expected（全部满足才算通过）：
1. 弹出包含服务器物理数据库名的下拉菜单（可勾选，PG 为单选 `RadioItem`）；
2. 勾选一个库后 Databases 输入框被写回该库名；
3. 应用日志里**不再出现** `connection to server at "10.10.239.167", port 5432 failed: FATAL:  database "root" does not exist`；
4. 日志里出现 provider 的查询 `SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = FALSE`。

- [ ] **Step 3: 边界——PG 会话库名为空**

把 Databases 输入框清空（先不要保存会话）→ 点 `»`。

Expected: 以 `postgres` 连接并列出库（日志中连接的是 `dbname='postgres'`）；若该服务器没有 `postgres` 库，则失败并只留日志——这是规格 §5 的已知限制，记录实际结果即可。

- [ ] **Step 4: 回归——非 PG 引擎**

任一 MySQL（或 MSSQL）会话 → 点 `»`。

Expected: 与改动前一致——临时连接不带库名、列出全部库、可勾选写回。

- [ ] **Step 5: 可选——SQL 语义直连验证**

若手头有该服务器的 psql 凭据：

```bash
psql "host=10.10.239.167 port=5432 user=<user> dbname=<session-db>" \
  -c "SELECT datname FROM pg_catalog.pg_database WHERE datistemplate = FALSE"
```

Expected: 返回数据库名列表、无报错；并且不带 `dbname` 时能复现原始报错：

```bash
psql "host=10.10.239.167 port=5432 user=root" -c "SELECT 1"
```

Expected: `FATAL: database "root" does not exist`（复现根因，用于对照）。

- [ ] **Step 6: 记录验收结论**

把三条命令的实际输出（或截图/日志摘录）写进任务报告：主验收是否通过、边界结果、回归结果。**未在真机跑过就不要声称"已修复"**；若服务器不可达或没有凭据，如实标注为"待用户验收"并交回给用户。

---

## 交付物

- `source/dbstructures.pas`、`source/dbstructures.postgresql.pas`、`source/dbconnection.pas`、`source/connections.pas` 四个文件的改动（3 个 commit）
- 一次 `make build-qt6` 成功的 Release Qt6 构建
- 一份真机验收结论（Task 4）
