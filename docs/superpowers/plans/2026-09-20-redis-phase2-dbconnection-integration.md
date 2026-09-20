# Redis 支持 — 阶段 2 实现计划（TDBConnection 集成 + 会话对话框门控）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把阶段 1 的纯 Pascal RESP 客户端接入 HeidiSQL 主程序：新增 `ngRedis`/`ntRedis_*` 枚举、`TRedisConnection : TDBConnection`、`TRedisQuery : TDBQuery`、`TRedisProvider`，扩展 `dbconnection.pas` 的 21 处 `case NetTypeGroup` 分支，并在会话管理器对话框门控字段——使"Redis (TCP/IP)"出现在网络类型下拉框，能保存会话并连接。

**Architecture:** 阶段 1 的 `redisclient.pas`（`TRedisClient`）是底层传输。阶段 2 包一层 `TRedisConnection : TDBConnection`，把 Redis 命令适配为 HeidiSQL 的 `Query`/`GetResults`/`TDBQuery` 结果流转接口，复用连接生命周期、会话存储、日志、线程。`ERedisError` 在 `TRedisConnection` 边界映射为 `EDbError`。键树/值查看器/命令台是阶段 3-4，本阶段只让会话能建立、能 PING、能在日志区看到连接成功。

**Tech Stack:** Free Pascal 3.2.2（`{$mode delphi}{$H+}`）、Lazarus LCL、阶段 1 的 `redisclient.pas`。无新第三方依赖。

## Global Constraints

- 编译器: `/data/fpc_tools/fpc/bin/x86_64-linux/fpc`，Delphi 模式：每个 `.pas`/`.lpr` 首行 `{$mode delphi}{$H+}`。
- **FPC 3.2.2 不支持内联变量声明**——所有变量在 `var` 区声明。
- 源单元扁平放在 `source/`，文件名 = 单元名。
- **不提交**（用户指示）：所有改动留在工作区，不 `git commit`。
- 主程序编译命令: `make build-qt6`（验证未破坏现有项目）。
- 枚举值追加在末尾，不重排现有值（避免破坏已保存会话的整数序列化）。
- `TDBConnection` 的 `else raise Exception(MsgUnhandledNetType)` 分支必须为 `ngRedis` 加分支，否则一连接就崩。
- 阶段 1 已验证 `redisclient.pas` 的 `TRedisClient.Connect(Host, Port, User, Pass, Db)` 可用（RESP2/RESP3+ACL 冒烟通过）。

---

## 文件结构

| 文件 | 改动 | 说明 |
|---|---|---|
| `source/dbstructures.pas` | 修改 | `TNetType` 加 5 个 Redis 值；`TNetTypeGroup` 加 `ngRedis` |
| `source/const.inc` | 修改 | 加 `REDIS_DEFAULT_PORT=6379`、`REDIS_DEFAULT_DB=0` 常量 |
| `source/dbconnection.pas` | 修改 | 加 `TRedisConnection`/`TRedisQuery` 类声明；扩展 21 处 case 分支；`ERedisError`→`EDbError` 映射 |
| `source/dbstructures.redis.pas` | 新建 | `TRedisProvider : TSqlProvider` |
| `source/connections.pas` | 修改 | 会话对话框字段门控（`in [...]` 成员检查加 Redis） |
| `source/main.pas` | 修改 | 4 处会话进入/动作的 case 分支（SQL dialect、routine、pagination、processes） |
| `heidisql.lpi` | 修改 | 注册新单元 `dbstructures.redis.pas`（如需要） |

---

## Task 1: 枚举扩展 + 常量

**Files:**
- Modify: `source/dbstructures.pas`（`TNetType`、`TNetTypeGroup`）
- Modify: `source/const.inc`（Redis 常量）

**Interfaces:**
- Produces: `ntRedis_TCPIP`、`ntRedis_SSHtunnel`、`ntRedis_TLS`、`ntRedis_Sentinel`、`ntRedis_Cluster`（追加在 `TNetType` 末尾）；`ngRedis`（追加在 `TNetTypeGroup` 末尾）；`REDIS_DEFAULT_PORT`、`REDIS_DEFAULT_DB`。

- [ ] **Step 1: 在 `dbstructures.pas` 的 `TNetType` 末尾追加 Redis 值**

将 `ntSQLiteEncrypted` 后的 `);` 前：
```pascal
    ntSQLiteEncrypted
    );
```
改为：
```pascal
    ntSQLiteEncrypted,
    ntRedis_TCPIP,
    ntRedis_SSHtunnel,
    ntRedis_TLS,
    ntRedis_Sentinel,
    ntRedis_Cluster
    );
```

- [ ] **Step 2: 在 `TNetTypeGroup` 末尾追加 `ngRedis`**

将：
```pascal
  TNetTypeGroup = (ngMySQL, ngMSSQL, ngPgSQL, ngSQLite, ngInterbase);
```
改为：
```pascal
  TNetTypeGroup = (ngMySQL, ngMSSQL, ngPgSQL, ngSQLite, ngInterbase, ngRedis);
```

- [ ] **Step 3: 在 `const.inc` 末尾追加 Redis 常量**

在 `SLogPrefixInfo = 'Info';` 行之后追加：
```pascal
  // Redis defaults
  REDIS_DEFAULT_PORT = 6379;
  REDIS_DEFAULT_DB = 0;
```

- [ ] **Step 4: 编译验证（预期失败——else 分支未改）**

Run: `make build-qt6 2>&1 | tail -20`
Expected: 编译可能仍通过（枚举只是新增值，现有 case 不报错），但运行时选 Redis 会崩。本步只确认枚举语法正确。

- [ ] **Step 5: 不提交。**

---

## Task 2: TRedisProvider（dbstructures.redis.pas）

**Files:**
- Create: `source/dbstructures.redis.pas`

**Interfaces:**
- Produces: `TRedisProvider : TSqlProvider`，override `GetSql(AId)` 对所有 `TQueryId` 返回 `SNotImplemented`。存在只为让 `dbconnection.pas:3169` 的 `FSqlProvider := ...Create(...)` 编译通过。

- [ ] **Step 1: 创建 `source/dbstructures.redis.pas`**

```pascal
unit dbstructures.redis;

{$mode delphi}{$H+}

interface

uses
  dbstructures;

type
  { TRedisProvider — Redis 不使用 SQL provider。此类存在仅是为了让
    TDBConnection.Connect 的 case NetTypeGroup 能为 ngRedis 创建一个 provider
    实例而不落入 else raise。GetSql 对所有 id 返回 SNotImplemented。 }
  TRedisProvider = class(TSqlProvider)
  public
    function GetSql(AId: TQueryId): string; overload; override;
  end;

implementation

uses
  SysUtils;

{$I const.inc}

function TRedisProvider.GetSql(AId: TQueryId): string;
begin
  raise EDbError.CreateFmt(_(SUnsupported), []);
end;

end.
```

> 注意：`SUnsupported` 与 `EDbError` 来自 `const.inc`/`dbconnection`。`dbstructures.redis` 的 implementation `uses` 可能需加 `dbconnection`（`EDbError` 定义处）。若 `EDbError` 在 `dbconnection.pas`，则 implementation `uses dbconnection;`。`_()` 是翻译函数，在 `apphelpers`。先尝试 `uses SysUtils, dbconnection;`，若 `_` 未定义再加 `apphelpers`。编译时据报错调整。

- [ ] **Step 2: 编译验证（单独编译此单元）**

Run:
```bash
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Fuout/lib/x86_64-linux \
  source/dbstructures.redis.pas -o/dev/null 2>&1 | tail -10
```
Expected: 0 errors（可能需迭代修 `uses`）。若报 `EDbError` 未定义→加 `dbconnection`；报 `_` 未定义→加 `apphelpers`。

- [ ] **Step 3: 不提交。**

---

## Task 3: TRedisConnection + TRedisQuery（dbconnection.pas 类声明）

**Files:**
- Modify: `source/dbconnection.pas`（在 `TInterbaseConnection` 注释块之后、`TDBQuery` 声明之前加 `TRedisConnection` 声明；在 `TSQLiteQuery` 之后加 `TRedisQuery` 声明）

**Interfaces:**
- Consumes: 阶段 1 `redisclient`（`TRedisClient`/`TRedisValue`/`ERedisError`）
- Produces:
  - `TRedisConnection : TDBConnection`：override `SetActive`、`Ping`、`GetThreadId`、`GetLastErrorCode`、`GetLastErrorMsg`、`GetAllDatabases`、`FetchDbObjects`、`Query`、`GetCreateCode`、`ConnectionInfo`；持有 `FClient: TRedisClient`。
  - `TRedisQuery : TDBQuery`：override `Execute`、`Col`、`ColIsPrimaryKeyPart`、`ColIsUniqueKeyPart`、`ColIsKeyPart`、`IsNull`、`HasResult`、`DatabaseName`、`TableName`、`SetRecNo`；持有 `FReply: TRedisValue`。

- [ ] **Step 1: 在 `dbconnection.pas` interface `uses` 加 `redisclient`**

在 `uses Classes, SysUtils, ...` 中加入 `redisclient`（若循环依赖则放 implementation uses——但 `TRedisConnection` 字段类型 `TRedisClient` 需 interface 可见性，故必须在 interface uses）。

- [ ] **Step 2: 在 `TInterbaseConnection` 注释块（~810 行）之后插入 `TRedisConnection` 声明**

```pascal
  { TRedisConnection — Redis 键值存储连接。复用 TDBConnection 生命周期/日志/线程，
    但 Query() 把 SQL 字符串解释为空格分词的 RESP 命令。不实现 SQL 表/列/键方法
    （抛 SNotImplemented），UI 门控确保不调用。键树/值查看器在阶段 3。 }
  TRedisConnection = class(TDBConnection)
  private
    FClient: TRedisClient;
  protected
    procedure SetActive(Value: Boolean); override;
    function GetThreadId: Int64; override;
    function GetLastErrorCode: Cardinal; override;
    function GetLastErrorMsg: String; override;
    function GetAllDatabases: TStringList; override;
    procedure FetchDbObjects(db: String; var Cache: TDBObjectList); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Query(SQL: String; DoStoreResult: Boolean=False; LogCategory: TDBLogCategory=lcSQL); override;
    function Ping(Reconnect: Boolean): Boolean; override;
    function GetCreateCode(Obj: TDBObject): String; override;
    function ConnectionInfo: TStringList; override;
    property Client: TRedisClient read FClient;
  end;
```

- [ ] **Step 3: 在 `TSQLiteQuery` 声明之后插入 `TRedisQuery` 声明**

```pascal
  { TRedisQuery — 把 TRedisValue 回复适配为 TDBQuery 列/行接口。
    标量→单行单列；hash/array→多行。只读（不支持网格编辑）。 }
  TRedisQuery = class(TDBQuery)
  private
    FReply: TRedisValue;
    FColumns: TStringList;
    FRows: array of array of string;  // [row][col]
  protected
    procedure SetRecNo(Value: Int64); override;
  public
    constructor Create(Connection: TDbConnection); override;
    destructor Destroy; override;
    procedure Execute(AddResult: Boolean=False; UseRawResult: Integer=-1); override;
    function Col(Column: Integer; IgnoreErrors: Boolean=False): String; overload; override;
    function ColIsPrimaryKeyPart(Column: Integer): Boolean; override;
    function ColIsUniqueKeyPart(Column: Integer): Boolean; override;
    function ColIsKeyPart(Column: Integer): Boolean; override;
    function IsNull(Column: Integer): Boolean; overload; override;
    function HasResult: Boolean; override;
    function DatabaseName: String; override;
    function TableName(Column: Integer): String; overload; override;
  end;
```

- [ ] **Step 4: 编译验证（预期失败——实现未写、case 未改）**

Run: `make build-qt6 2>&1 | tail -10`
Expected: 报未实现的方法 / 未注册的单元。本步确认声明语法正确。

- [ ] **Step 5: 不提交。**

---

## Task 4: TRedisConnection + TRedisQuery 实现 + dbconnection.pas 21 处 case 分支

这是最大的任务。所有 case 分支必须一起改，否则编译通过但运行崩溃。

**Files:**
- Modify: `source/dbconnection.pas`

**21 处 case 分支改动清单（MUST-BRANCH）：**

| 行 | 函数 | ngRedis 分支 |
|---|---|---|
| 1499 | CreateConnection | `Result := TRedisConnection.Create(AOwner)` |
| 1521 | CreateQuery | `Result := TRedisQuery.Create(Connection)` |
| 1555 | NetTypeName(long,case FNetType) | `ntRedis_TCPIP: Result := 'Redis (TCP/IP)'` 等 |
| 1577 | NetTypeName(short,case NetTypeGroup) | `ngRedis: Result := 'Redis'` |
| 1603 | GetNetTypeGroup(case FNetType) | `ntRedis_TCPIP,ntRedis_SSHtunnel,ntRedis_TLS,ntRedis_Sentinel,ntRedis_Cluster: Result := ngRedis` |
| 1796 | DefaultPort | `ngRedis: Result := REDIS_DEFAULT_PORT` |
| 1828+1939+1978 | GetLibraries | `ngRedis`: 无原生库，直接返回空列表（不走 regex/ldconfig） |
| 1848 | DefaultLibrary | `ngRedis: Result := ''`（无库） |
| 3169 | Connect/SqlProvider | `ngRedis: FSqlProvider := TRedisProvider.Create(FParameters.NetType)` |
| 4615 | ServerVersionInt | `ngRedis`: 用 Redis `INFO server` 的 `redis_version` 解析，或复用通用 regex |
| 4657 | ServerVersionStr | `ngRedis: Result := FServerVersionUntouched`（直接返回原串） |
| 5006 | EscapeString | `ngRedis: Result := StringReplace(Text, '''', '''''', [rfReplaceAll])`（单引号转义，Redis 无 SQL 注入概念但保持一致） |
| 6717 | ResultCount | `ngRedis: Result := TRedisConnection(Self).FLastResultCount`（新增字段） |
| 7848 | ApplyLimitClause | `ngRedis: Result := QueryBody`（无 LIMIT，直接返回） |

**main.pas 4 处：**

| 行 | 函数 | ngRedis 分支 |
|---|---|---|
| 10047 | session-enter SQL dialect | `ngRedis: SynSQLSynUsed.SQLDialect := sqlStandard` |
| 4776 | actCreateRoutineCode prefix | `ngRedis: raise EDbError.Create(SNotImplemented)` 或禁用动作 |
| 4806 | actCreateRoutineCode params | 同上 |
| 6240 | data-grid OFFSET | `ngRedis: Offset := 0` |
| 11985 | ListProcesses query | `ngRedis: Result := 'CLIENT LIST'`（或禁用 Processes 标签） |

**SSH 支持（非 case，是 `in [...]` 集合）：**
- `SshSupport`（1624 行）：加 `ntRedis_SSHtunnel`
- `DefaultSshActive`（1864 行）：加 `ntRedis_SSHtunnel`

- [ ] **Step 1: 实现 `TRedisConnection` 方法体**

在 `dbconnection.pas` implementation 区（`TSQLiteConnection` 实现之后）添加：
```pascal
{ TRedisConnection }

constructor TRedisConnection.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FClient := TRedisClient.Create;
end;

destructor TRedisConnection.Destroy;
begin
  FClient.Free;
  inherited Destroy;
end;

procedure TRedisConnection.SetActive(Value: Boolean);
begin
  if Value = FActive then Exit;
  if Value then begin
    try
      FClient.Connect(Parameters.Hostname, Parameters.Port,
        Parameters.Username, Parameters.Password, REDIS_DEFAULT_DB);
      FActive := True;
      FServerVersionUntouched := FClient.Execute(['INFO', 'server']).Str;
      // 从 INFO 输出提取 redis_version
      // ...（简化：整串存，ServerVersionStr 直接返回）
    except
      on E: ERedisError do raise EDbError.Create(E.Message);
    end;
  end else begin
    FClient.Disconnect;
    FActive := False;
  end;
end;

function TRedisConnection.GetThreadId: Int64;
begin
  Result := 0;  // Redis 无线程 id 概念
end;

function TRedisConnection.GetLastErrorCode: Cardinal;
begin
  Result := 0;
end;

function TRedisConnection.GetLastErrorMsg: String;
begin
  Result := FClient.LastError;
end;

function TRedisConnection.GetAllDatabases: TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  for i := 0 to 15 do
    Result.Add('db' + IntToStr(i));
end;

procedure TRedisConnection.FetchDbObjects(db: String; var Cache: TDBObjectList);
begin
  // 阶段 3 实现 SCAN + 键树。本阶段留空（不填充）。
  Cache := TDBObjectList.Create(True);
end;

procedure TRedisConnection.Query(SQL: String; DoStoreResult: Boolean=False; LogCategory: TDBLogCategory=lcSQL);
var
  v: TRedisValue;
begin
  Log(LogCategory, SQL);
  try
    v := FClient.Execute(SQL);  // SQL 按空格分词为 RESP 命令
  except
    on E: ERedisError do raise EDbError.Create(E.Message);
  end;
  // 存入 LastResults 供 GetResults 使用——阶段 3 完善
  v.Free;
  FRowsAffected := 0;
end;

function TRedisConnection.Ping(Reconnect: Boolean): Boolean;
begin
  if Reconnect and not FActive then
    SetActive(True);
  Result := FActive and FClient.Ping;
end;

function TRedisConnection.GetCreateCode(Obj: TDBObject): String;
begin
  Result := SUnsupported;
end;

function TRedisConnection.ConnectionInfo: TStringList;
begin
  Result := inherited ConnectionInfo;
  Result.Add('Redis ' + FServerVersionUntouched);
end;
```

> 注意：`Parameters.Hostname`/`.Port`/`.Username`/`.Password` 的确切属性名需核对 `TConnectionParameters`。`Execute(['INFO','server'])` 返回 bulk string，`.Str` 取文本。需迭代修编译错误。

- [ ] **Step 2: 实现 `TRedisQuery` 方法体**

```pascal
{ TRedisQuery }

constructor TRedisQuery.Create(Connection: TDbConnection);
begin
  inherited Create(Connection);
  FColumns := TStringList.Create;
end;

destructor TRedisQuery.Destroy;
begin
  FReply.Free;
  FColumns.Free;
  inherited Destroy;
end;

procedure TRedisQuery.Execute(AddResult: Boolean=False; UseRawResult: Integer=-1);
var
  conn: TRedisConnection;
begin
  conn := TRedisConnection(FConnection);
  try
    FReply := conn.Client.Execute(FSQL);
  except
    on E: ERedisError do raise EDbError.Create(E.Message);
  end;
  // 简化：标量→1行1列；array→多行1列。阶段 3 按命令语义细化列名。
  FColumns.Clear;
  FColumns.Add('value');
  FRecordCount := 1;  // 标量默认
  if (FReply <> nil) and (FReply.Kind in [rkArray, rkSet, rkPush]) then begin
    FRecordCount := Length(FReply.Items);
    // 转为行
  end;
  FRecNo := 0;
  FEof := FRecordCount = 0;
end;

function TRedisQuery.Col(Column: Integer; IgnoreErrors: Boolean=False): String;
begin
  // 简化：阶段 3 完善
  if (FReply <> nil) and (FReply.Kind in [rkString, rkBulk]) then
    Result := FReply.Str
  else
    Result := '';
end;

function TRedisQuery.ColIsPrimaryKeyPart(Column: Integer): Boolean;
begin
  Result := False;
end;

function TRedisQuery.ColIsUniqueKeyPart(Column: Integer): Boolean;
begin
  Result := False;
end;

function TRedisQuery.ColIsKeyPart(Column: Integer): Boolean;
begin
  Result := False;
end;

function TRedisQuery.IsNull(Column: Integer): Boolean;
begin
  Result := (FReply = nil) or (FReply.Kind = rkNull);
end;

function TRedisQuery.HasResult: Boolean;
begin
  Result := (FReply <> nil) and (FReply.Kind <> rkNull);
end;

function TRedisQuery.DatabaseName: String;
begin
  Result := FConnection.Database;
end;

function TRedisQuery.TableName(Column: Integer): String;
begin
  Result := '';
end;

procedure TRedisQuery.SetRecNo(Value: Int64);
begin
  FRecNo := Value;
  FEof := FRecNo >= FRecordCount;
end;
```

- [ ] **Step 3: 逐一修改 21 处 case 分支**

按上表逐一编辑。每处用 `edit` 工具精确替换 `else raise` 之前插入 `ngRedis:` 分支。

- [ ] **Step 4: 修改 main.pas 4 处 case 分支**

- [ ] **Step 5: 修改 SSH 支持集合（2 处 `in [...]`）**

- [ ] **Step 6: 注册 `dbstructures.redis` 到 `heidisql.lpi`**（在 sqlite 条目后加一个 `<Unit>` 块）

- [ ] **Step 7: 编译验证**

Run: `make build-qt6 2>&1 | tail -20`
Expected: 0 errors。迭代修复编译错误。

- [ ] **Step 8: 不提交。**

---

## Task 5: 会话对话框门控（connections.pas）

**Files:**
- Modify: `source/connections.pas`（`comboNetTypeChange` 的 `in [...]` 成员检查）

**改动：**
- `lblPort.Enabled`（1617 行）：`in [...]` 加 `ntRedis_TCPIP, ntRedis_SSHtunnel, ntRedis_TLS`
- `lblUsername.Enabled`（1609 行）：`in [...]` 加 `ngRedis`
- `lblDatabase.Enabled`（1620 行）：`in [...]` 加 `ngRedis`（语义为逻辑库编号）
- `chkWantSSL.Enabled`（1653 行）：`in [...]` 加 `ntRedis_TLS`
- `chkSSHActive.Enabled`（1625 行）：由 `Params.SshSupport` 决定（已在 Task 4 加 `ntRedis_SSHtunnel`）
- `chkLocalTimeZone`/`chkFullTableStatus`/`chkCleartextPlugin`/`chkForceUnicode`/`chkCompressed`：不加 Redis（保持禁用）

- [ ] **Step 1-5: 逐一修改各 `in [...]` 集合**
- [ ] **Step 6: 编译验证 `make build-qt6`**
- [ ] **Step 7: 不提交。**

---

## Task 6: 集成验证

- [ ] **Step 1: 编译主程序 `make build-qt6`，0 errors**
- [ ] **Step 2: 启动 `./out/qt6/heidisql`，打开会话管理器，确认网络类型下拉框出现 "Redis (TCP/IP)"**
- [ ] **Step 3: 新建一个 Redis 会话，填 127.0.0.1:6379，连一个无密码 redis，确认日志区显示连接成功**
- [ ] **Step 4: 在查询区执行 `PING`，确认返回 PONG**
- [ ] **Step 5: 确认现有 MySQL/PG/SQLite 会话不受影响（回归）**
- [ ] **Step 6: 不提交。**

---

## 阶段 2 完成标准

- `make build-qt6` 0 errors。
- 会话管理器网络类型下拉框出现 Redis 选项。
- 能新建 Redis 会话、保存、连接无密码 redis、PING 返回 PONG。
- 现有 MySQL/PG/SQLite 会话不受影响。
- `TRedisConnection`/`TRedisQuery` 的 Query/结果适配是**最小可用**（标量/简单命令），完整键树/值查看器/命令台在阶段 3-4。

## 后续阶段（本计划不覆盖）

- **阶段 3**: 键树（SCAN + 前缀分组）、`redis_values.pas` 只读值查看器。
- **阶段 4**: `redis_console.pas` 命令台。
- **阶段 5**: TLS（`TRedisTlsSocket`）、SSH 隧道端到端。
- **阶段 6**: 主窗体动作门控。
- **阶段 7-8（后续里程碑）**: Cluster/Sentinel、ACL 管理 UI、导出。
