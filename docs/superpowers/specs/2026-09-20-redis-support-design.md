# Redis 支持设计 — HeidiSQL (Lazarus/Free Pascal port)

- 日期: 2026-09-20
- 状态: 已批准（设计阶段），待实现
- 适用代码库: `/data/projects_local/pascal/HeidiSQL`（HeidiSQL 的 Lazarus/FPC 移植版）

## 1. 背景与目标

为 HeidiSQL 增加对 Redis 的支持。用户在头脑风暴阶段确定的范围：

- **整体范围**: 浏览器 + 命令台
- **连接特性**: ACL 用户名+密码 / 旧版密码、TLS/SSL、SSH 隧道、Cluster/Sentinel（分阶段）、RESP3
- **浏览与编辑模型**: 只读浏览键值；所有修改通过命令台执行
- **键树组织**: 按数据库(0-15) → 按键前缀（以 `:` 分隔的命名空间）分组

## 2. 关键设计决策

### 2.1 不强行套入 SQL/关系模型

HeidiSQL 的整套架构围绕 SQL 与关系对象（表/视图/例程/触发器、`TSqlProvider`、`TQueryId`、主键网格编辑）构建。Redis 是键值存储，数据模型根本不同。

决策: Redis **复用**连接生命周期、日志、线程、会话持久化、`TDBQuery` 结果流转等基础设施，但**不**强行塞进表/视图/例程编辑器、SQL provider 或主键网格编辑。这些对 `ngRedis` 直接禁用/门控。SQL 查询页由 Redis 命令台替代，表编辑器由只读值查看器替代。

### 2.2 纯 Pascal RESP 客户端（无原生库依赖）

代码库惯例是用 FFI 绑定原生客户端库（libmysql/libpq/libsqlite3/libsybdb）。但 Redis 的 RESP 协议足够简单，重新实现比绑定+hiredis 更省事，且保住了单二进制跨平台承诺。

决策: 新增 `redisclient.pas`，用 FPC 的 `Sockets` 单元做 TCP、`openssl` 单元做 TLS，纯 Pascal 实现 RESP2/RESP3。无 `TRedisLib` FFI 记录、无 `GetLibraries` 正则、无需随包分发 `.so`/`.dll`。SSH 隧道复用现有机制（Redis 连本地转发端口）。

### 2.3 枚举扩展

`dbstructures.pas`:

```pascal
TNetType = (..., ntRedis_TCPIP, ntRedis_SSHtunnel, ntRedis_TLS,
               ntRedis_Sentinel, ntRedis_Cluster);
TNetTypeGroup = (ngMySQL, ngMSSQL, ngPgSQL, ngSQLite, ngInterbase, ngRedis);
```

首期实现 `ntRedis_TCPIP`/`ntRedis_TLS`/`ntRedis_SSHtunnel`；`ntRedis_Sentinel`/`ntRedis_Cluster` 作为桩，在其里程碑前抛"未实现"。

## 3. 架构与集成模型

### 3.1 新增单元（扁平放在 `source/` 下，按项目约定）

| 单元 | 职责 |
|---|---|
| `redisclient.pas` | 纯 Pascal RESP2/RESP3 协议客户端。TCP 用 `Sockets`，TLS 用 `openssl`。发送命令数组、解析各类回复。持有 socket、负责鉴权、`HELLO`/`SELECT`、MOVED/ASK 重定向。不依赖 LCL。 |
| `dbstructures.redis.pas` | 引擎 provider `TRedisProvider : TSqlProvider`。绝大多数 `TQueryId` 返回 `SNotImplemented`；Redis 不真正使用 SQL provider，它存在只是让现有各处 `case` 分支能编译通过。 |
| `redis_console.pas` + `.lfm` | `TfrmRedisConsole : TExtForm` —— 命令台（SynEdit 输入 + 日志输出），是 SQL 查询页的 Redis 对应物。 |
| `redis_values.pas` + `.lfm` | `TfrmRedisValue : TDBObjectEditor`（frame）—— 选中键节点时显示的只读值查看器，按类型渲染（string/hash/list/set/zset/stream）。 |

### 3.2 `TRedisConnection : TDBConnection`

继承抽象基类，复用连接列表、会话存储、日志、`TQueryThread` 基础设施，但不伪装成 SQL:

- `Query(SQL, ...)` 重写: 把 `SQL` 按空格分词为 RESP 命令（如 `'GET foo'` → `["GET","foo"]`），执行后把回复塞进 `TRedisQuery : TDBQuery`，使 `main.pas`/`tabletools.pas` 已有的结果流转逻辑继续可用。
- 重写 `Ping`、`GetLastErrorCode/Msg`、`GetAllDatabases`（返回 `db0`..`db15`）、`GetCreateCode`。
- `FetchDbObjects` 重写为填充**键树**（库 → 前缀文件夹 → 键），而非 SQL 表/视图。
- 对 Redis 无意义的方法（`GetTableColumns/Keys/ForeignKeys`）抛 `EDbError(SNotImplemented)`；UI 门控确保它们不会被调用。

## 4. RESP 协议客户端与连接特性

### 4.1 `redisclient.pas` 内部结构

```
TRedisValue (变体记录)        // 一个解析后的回复
  Kind: TRedisReplyKind       // rkString, rkError, rkInteger, rkBulk,
                              //   rkArray, rkMap, rkSet, rkPush,
                              //   rkBigNumber, rkVerbatim, rkBoolean, rkNull
  Str: string                 // string/bulk/error/verbatim 文本
  Int: Int64                  // integer/boolean
  Items: TRedisValueArray     // array/map/set/push 的子项

TRedisSocket                  // 传输抽象
  ├── TRedisPlainSocket       // Sockets 单元，纯 TCP
  └── TRedisTlsSocket         // openssl 单元，TLS

TRedisClient                   // 协议 + 连接
  - FSocket: TRedisSocket
  - FProtocol: 2 or 3         // HELLO 协商后确定
  - FClusterSlots: ...        // 槽位缓存，Cluster 里程碑才实现，首期不定义
  + Connect(Params)
  + Execute(const Args: TStringArray): TRedisValue
  + Execute(cmd: string): TRedisValue   // 便捷重载，空格分词
  + SelectDb(n)
  + Authenticate(user, pass)
  + Disconnect
```

### 4.2 协议解析

递归下降读取字节流，处理 RESP2 与 RESP3 差异:

- RESP2: `+`/`-`/`:`/`$`/`*` 五种；`*-1` 和 `$-1` 均为 nil。
- RESP3: 新增 `_`(null)、`#`(boolean)、`,`(double)、`(`(big number)、`=`(verbatim, 前 3 字节为子类型)、`%`(map, 元素数为声明数 ×2)、`~`(set)、`>`(push)。HELLO 协商为 3 后才启用这些。
- 命令发送统一为 `*N\r\n$len\r\nbytes\r\n...` 数组形式，RESP2/3 一致。

### 4.3 连接流程（`TRedisClient.Connect`）

1. 建 socket（含 SSH 隧道场景: 连本地转发端口，透明）。
2. TLS: 用 `openssl` 单元建 `TSSLSocket`，复用 HeidiSQL 现有 SSL 证书/CA/验证选项（`WantSSL`、`SSLCACertificate` 等）。
3. 认证:
   - 若有用户名 → `HELLO 3 AUTH user pass`（RESP3 + ACL）。
   - 若 HELLO 失败（旧版不支持）→ 回退 `AUTH user pass`（有用户名）或 `AUTH pass`（无用户名，旧版）。
   - 协商后 `FProtocol` 设为 3 或 2。
4. `SELECT <db>`（若会话指定了库）。

### 4.4 连接特性分阶段

| 特性 | 首期 | 后续里程碑 |
|---|---|---|
| TCP + ACL 用户名/密码 + 旧版密码 | ✅ | |
| TLS | ✅ | |
| SSH 隧道 | ✅（复用现有隧道机制，Redis 连本地端口） | |
| RESP3 | ✅ 协商（失败回退 RESP2） | |
| Cluster（MOVED/ASK 重定向 + 槽位缓存） | 桩，抛"未实现" | ✅ |
| Sentinel（发现主节点） | 桩，抛"未实现" | ✅ |

### 4.5 错误处理

协议/网络错误、Redis `-ERR`/`-MOVED`/`-ASK` 均映射为 `EDbError`（携带 `ErrorCode`+`Hint`），与 `dbconnection.pas` 现有约定一致；UI 层捕获，连接内部抛出。详见 §7。

### 4.6 超时与重连

连接级读写超时（复用 `Ping` 机制）；`Ping(Reconnect)` 重写以支持断线后重新握手 + 重新认证 + `SELECT`。

### 4.7 线程安全

`redisclient.pas` 本身不碰 LCL；长命令在 `TQueryThread` 上跑，结果通过 `TRedisQuery` 回流，与现有线程模型一致。

## 5. UI 集成

### 5.1 会话管理器门控（`connections.pas`）

`comboNetTypeChange` 里 ~15 个 `case` 分支控制字段启用状态，需为 `ngRedis`/`ntRedis_*` 补分支:

| 字段 | Redis 行为 |
|---|---|
| 端口 | `ntRedis_TCPIP/TLS/SSHtunnel` 启用，默认 6379；`ntRedis_Sentinel/Cluster` 暂禁用（桩） |
| 用户名/密码 | 启用（ACL 用户名可选，密码即旧版 AUTH） |
| 数据库 | 启用，语义为"逻辑库编号 0-15"，复用 `editDatabases` 文本框（不再触发下拉列举） |
| SSL 选项 | 仅 `ntRedis_TLS`/`ntRedis_SSHtunnel+TLS` 启用 |
| SSH 隧道 | 仅 `ntRedis_SSHtunnel` 启用 |
| 禁用项 | `chkLocalTimeZone`、`chkFullTableStatus`、`chkCleartextPlugin`、`chkForceUnicode`、`chkLoginPrompt` 等 MySQL 专属项 |
| 库文件 | Redis 无原生库，`DefaultLibrary`/`GetLibraries` 返回空 |

### 5.2 左侧对象树（`main.pas`）

Redis 连接的树结构与 SQL 引擎不同，需在树填充逻辑里按 `NetTypeGroup` 分支:

```
[server] Redis on 127.0.0.1:6379
 ├── 🗄 db0  (1234 keys)
 ├── 🗄 db1  (0 keys)
 │   └── (空库灰显)
 ├── 🗄 db2
 │   ├── 📁 user
 │   │   ├── 📁 user:1001  →  🔑 user:1001 (hash)
 │   │   └── 📁 user:1002  →  🔑 user:1002 (hash)
 │   ├── 📁 session
 │   │   └── 🔑 session:abc (string)
 │   └── 🔑 cache:home (string)
 └── 🗄 db3 ...
```

- **填充方式**: `FetchDbObjects` 用 `SCAN` 增量加载（`COUNT 200`，游标存节点 `VTreeNotLoaded`/`VTREE_LOADED` 标志，懒加载子节点），而非一次性 `KEYS *`。
- **前缀分组**: 以 `:` 为分隔符，把键拆成命名空间段建虚拟文件夹节点；叶子节点为键本身，带类型图标（string/list/hash/set/zset/stream/其他）。
- **节点类型**: 新增 `TListNodeType` 值 `lntRedisDb`、`lntRedisPrefix`、`lntRedisKey`；`PlaceObjectEditor` 里加分支，`lntRedisKey` → `redis_values`，`lntRedisDb`/`lntRedisPrefix` → 无编辑器或简单统计面板。
- **图标**: 新增 `ICONINDEX_REDIS_*` 常量（`const.inc`），复用现有 image list 空位或追加图标资源。

### 5.3 右侧编辑区分派（`PlaceObjectEditor`）

```pascal
case Obj.NodeType of
  lntTable:   EditorClass := TfrmTableEditor;
  ...
  lntRedisKey: EditorClass := TfrmRedisValue;   // 新增
end;
```

**`TfrmRedisValue`（frame）**: 只读展示选中键的值，按类型渲染:

- `string`: 文本/十六进制/JSON 美化切换
- `hash`: field/value 两列表格
- `list`: 索引/元素表格
- `set`/`zset`: 成员（zset 带 score）列表
- `stream`: ID/field-value 表格
- 顶部显示 `TYPE`、`TTL`、`MEMORY USAGE`、`SIZE`
- 带刷新按钮；底部提示"只读，请用命令台修改"

### 5.4 主窗体菜单/动作门控（`main.pas`）

| 动作 | Redis 行为 |
|---|---|
| 建表/视图/例程/触发器/事件 | 禁用 |
| 用户管理器 | 禁用（ACL 管理后续里程碑，首期只读） |
| 数据库创建/删除 | 重定向为 Redis 的 `SELECT`+说明（首期禁用，避免误删库） |
| SQL 查询页 | 替换为/隐藏，改用 Redis 命令台 |
| 导出 | 首期禁用（后续可导出键为 JSON/RDB） |
| 刷新对象树 | 启用，重新 SCAN |
| 复制键名 | 启用 |
| 删除键 | 启用（`DEL`），带确认 |
| 设置 TTL/过期 | 启用（`EXPIRE`/`PERSIST`） |
| 重命名键 | 启用（`RENAME`） |

### 5.5 命令台（`redis_console.pas` + `.lfm`）

`TfrmRedisConsole : TExtForm`，类似 SQL 查询页但针对 Redis:

- 上方 SynEdit 输入区（单行/多行命令，`;` 分隔可选，回车执行）
- 下方只读日志/结果区: 彩色显示命令回显、回复、耗时、错误
- 自动补全: Redis 命令列表（内置子集 + `COMMAND` 动态拉取）
- 历史记录（上下键），复用 `REGKEY_QUERYHISTORY` 机制
- 当前库指示（`SELECT` 后更新）
- 支持管道（多命令一次发送）与订阅模式（`SUBSCRIBE` 的 push 回复持续显示，RESP3 下更自然）

### 5.6 常量与设置（`const.inc` / `apphelpers.pas`）

- `const.inc`: `ICONINDEX_REDIS_*`、`REDIS_DEFAULT_PORT=6379`、`REDIS_MAX_DB=15`、`REDIS_SCAN_COUNT=200`。
- `apphelpers.pas`: `TAppSettingIndex` 新增 `asRedisScanCount`、`asRedisDefaultDb`、`asRedisCommandHistory`（会话级）；`InitSetting` 注册默认值。

## 6. 数据流与线程模型

### 6.1 数据流示例

```
用户点击键节点 user:1001
   │
   ▼
main.pas: TreeFocusChanged → PlaceObjectEditor(lntRedisKey)
   │
   ▼
TfrmRedisValue.Init(Obj)
   │  Obj.Connection 是 TRedisConnection
   ▼
TRedisConnection.Query('TYPE user:1001')  →  TRedisQuery  →  "hash"
TRedisConnection.Query('HGETALL user:1001')  →  TRedisQuery  →  field/value 行
TRedisConnection.Query('TTL user:1001')  →  TRedisQuery  →  秒数
   │
   ▼
TfrmRedisValue 渲染只读表格
```

### 6.2 TRedisQuery 适配

`TRedisQuery : TDBQuery` 把 `TRedisValue` 回复适配为 `TDBQuery` 的列/行接口（`Col`、`RecordCount`、`Next` 等），使 `main.pas`/`tabletools.pas` 现有结果消费逻辑零改动。映射规则:

- 标量回复（string/bulk/integer/boolean/null）→ 单行单列，列名 `value`。
- Redis hash 回复（`HGETALL`，以 array 形式返回的 field/value 交替）→ 多行，2 列 `field`/`value`，每对一行。
- RESP3 map 回复（`%`）→ 多行，2 列 `key`/`value`，每对一行。
- 数组回复（`SCAN` 游标+键、`LRANGE`、`SMEMBERS` 等）→ 多行单列，列名按命令语义命名（如 `key`/`element`/`member`）。
- `ZRANGE ... WITHSCORES` → 多行 2 列 `member`/`score`。
- 错误回复在到达 `TRedisQuery` 前已转为 `EDbError`，不会作为行出现。

### 6.3 线程模型

- **短命令**（`GET`/`TYPE`/`TTL`/`HGETALL` 等）: UI 线程同步执行，沿用现有 `Query` 路径。
- **长命令**（大 `SCAN`、`KEYS`、`HGETALL` 大 hash、`XRANGE` 大 stream）: 走 `TQueryThread`（`apphelpers.pas`），与现有 SQL 查询线程一致——`TQueryThread` 调 `Connection.Query`，UI 通过 `Connection`/`Batch`/`RowsAffected` 属性读结果，日志经 `LogFromThread` 回流。**绝不**在查询线程碰 LCL 控件。
- **SCAN 懒加载**: 树节点展开时触发增量 `SCAN`，在 `TQueryThread` 上分页拉取，避免 UI 卡顿；游标存于节点状态，直到游标回 0。
- **订阅模式**（`SUBSCRIBE`/`PSUBSCRIBE`）: 命令台在后台线程持续读 push 回复（RESP3 下为 `>` push 类型），通过 `TThread.Queue`/`Synchronize` 追加到日志区；`UNSUBSCRIBE` 或关闭页时停线程。这是唯一长期占用连接的模式，需防止阻塞普通命令——首期可简单地在订阅期间禁用其它命令输入，后续可考虑独立连接。

## 7. 错误处理

- **协议/网络错误**（socket 断开、解析失败）: `TRedisClient` 抛 `EDbError`，`ErrorCode` 为自定义码（如 `REDIS_ERR_PROTO`、`REDIS_ERR_CONN`），`Hint` 含上下文。UI 层捕获并显示，连接标记为断开。
- **Redis 错误回复**（`-ERR`/`-WRONGTYPE`/`-NOAUTH`/`-MOVED`/`-ASK`）:
  - `-MOVED`/`-ASK`: Cluster 里程碑才处理；首期 `-MOVED` 抛 `EDbError` 提示"需 Cluster 连接类型"，`-ASK` 同。
  - 其它 `-ERR`: `TRedisClient` 抛 `EDbError`，`ErrorCode` 取 Redis 返回的错误类别前缀映射，`Hint` 为完整消息。
  - `-WRONGTYPE` 特别处理: 值查看器友好提示"该键类型与请求操作不匹配"。
- **鉴权失败**（`-NOAUTH`/`-WRONGPASS`）: 连接阶段抛 `EDbError`，UI 提示检查用户名/密码。
- **超时**: 读写超时映射为 `EDbError(REDIS_ERR_TIMEOUT)`，`Ping(Reconnect)` 尝试重连（重新握手+认证+`SELECT`）。
- 所有 `EDbError` 从 `redisclient.pas`/`TRedisConnection` 内部抛出，UI（`main.pas`/命令台/值查看器）捕获，与现有约定一致。

## 8. 测试策略

项目无现成测试框架（无 `tests/` 目录、无 FPCUnit 引用），故采用**可编译 + 手动冒烟**为主、**独立控制台测试程序**为辅:

1. **编译验证**（首要门槛）: 每阶段确保 `make build-qt6` 通过，无新警告。
2. **协议单元测试（独立程序）**: 新增 `tests/test_redis_proto.lpr`（控制台程序，不依赖 LCL）:
   - 构造 RESP2/RESP3 字节流喂给 `TRedisClient` 的解析器，断言 `TRedisValue.Kind`/`Str`/`Int`/`Items`。
   - 覆盖: 5 种 RESP2 类型、RESP3 新类型、嵌套 array/map、null、big number、verbatim、boolean、`$-1`/`*-1`。
   - 覆盖命令序列化（`*N\r\n$len...`）。
   - 不连真实 Redis，纯解析层。
3. **端到端冒烟**（需真实 Redis 实例，手动）:
   - 用 docker 起 `redis:7`（含 ACL + RESP3）和 `redis:6`（RESP2 兼容性）。
   - 手工验证: 连接、鉴权、SELECT、SCAN 浏览、各类型键查看、TTL、命令台 GET/SET/HSET、TLS（docker 带 stunnel 或 redis --tls）、SSH 隧道（本地 sshd）。
   - 记录为 `docs/redis-smoke-test.md` 清单，供回归。
4. **不引入 FPCUnit**: 避免为单一特性给项目加测试框架依赖，与现有项目风格一致；若后续项目统一上 FPCUnit 再迁移。

## 9. 实现阶段划分

> 注: 阶段编号是**实现顺序**，与"首期/后续"发布分组不同。阶段 1–6 合起来构成**首期发布**（对应 §4.4 表中所有标 ✅ 的特性）；阶段 7–8 为**后续里程碑**（对应表中桩 → ✅ 的特性）。TLS 标为"首期"是指首期发布即包含，但其实现在阶段 5（命令台之后），因为命令台是更高优先级的可见功能。

1. **阶段 1 — 协议核心与连接**: `redisclient.pas`（RESP2/RESP3 解析 + 序列化 + plain TCP + 认证 + HELLO 协商 + SELECT）。独立协议测试程序。无 UI。
2. **阶段 2 — TRedisConnection 与会话对话框**: 枚举扩展、`TRedisConnection`/`TRedisQuery`、`dbstructures.redis.pas`、`connections.pas` 门控、`DefaultPort`/`DefaultUsername`/`GetImageIndex`/`GetNetTypeGroup`/`GetLibraries` 分支。能保存并打开一个 Redis 会话。
3. **阶段 3 — 键树与值查看器**: `FetchDbObjects` SCAN + 前缀分组、`lntRedisDb/Prefix/Key` 节点类型、`redis_values.pas` 只读值查看器、`PlaceObjectEditor` 分派。
4. **阶段 4 — 命令台**: `redis_console.pas` + `.lfm`，命令执行/历史/补全/当前库指示。
5. **阶段 5 — TLS 与 SSH 隧道**: `TRedisTlsSocket`、会话对话框 SSL/SSH 字段门控。
6. **阶段 6 — 主窗体动作门控**: 菜单/动作对 `ngRedis` 的启用/禁用、键操作（DEL/EXPIRE/RENAME）。
7. **阶段 7（后续）— Cluster/Sentinel**: MOVED/ASK 重定向 + 槽位缓存；Sentinel 主节点发现。
8. **阶段 8（后续）— ACL 管理 UI、导出**: 可选增强。

## 10. 不在本次范围内（YAGNI）

- 键的网格内直接编辑/删除（首期只读 + 命令台修改）
- Cluster/Sentinel 的首期实现（留桩，后续里程碑）
- ACL 管理 UI（首期只读认证）
- 导出键为 JSON/RDB（首期禁用导出）
- 把 Redis 强行塞进表/视图/例程编辑器或 SQL provider
- 绑定 libhiredis（已选定纯 Pascal 方案）
