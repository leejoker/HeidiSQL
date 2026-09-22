# TUI 数据库 & Redis 查询工具 — 设计文档

**日期**：2026-09-22
**状态**：已通过头脑风暴评审，待实现计划
**模块路径**：`tui/`（已加入 `.gitignore`，不提交）

---

## 1. 背景与目标

服务器上没有可视化数据库/Redis 查询工具。本设计在 HeidiSQL Pascal 仓库内新建一个
`tui/` 目录，用 Go + [bubbletea](https://github.com/charmbracelet/bubbletea) 实现一个
精简的终端工具，提供 PostgreSQL 与 Redis 的连接、查询、命令执行能力。

### 关键决策（头脑风暴结论）

| 维度 | 决策 |
|---|---|
| 复用方式 | 纯 Go 原生驱动（`pgx`、`go-redis`）。复用 HeidiSQL 的连接模型概念，**不复用 Pascal 源码**，不做 FFI/动态链接库 |
| 支持引擎 | PostgreSQL + Redis（MVP） |
| 能力范围 | 查询 + 执行 SQL/命令。**不做**网格内逐格编辑 |
| 连接配置 | 独立 `config.toml`，不复用 HeidiSQL 会话 |
| 会话模型 | 单连接会话（一次连一个库） |
| 屏幕结构 | 三屏向导式：连接选择屏 → 主屏 |
| 提交策略 | `tui/` 目录加入 `.gitignore`，本地开发，不进仓库 |

### 非目标（YAGNI）

- MSSQL / MySQL / SQLite / Interbase（驱动层留了接口，后续可加）
- 网格内逐格编辑值并回写
- 多连接并行（tab/pane）
- SQL 语法高亮
- 自动重连、错误码翻译表、查询日志文件
- 配置文件加密

---

## 2. 项目布局

```
tui/
├── go.mod                  # module heidisql-tui, go 1.27
├── main.go                 # 入口：读 flag、加载 config、启动 tea.Program
├── config.example.toml     # 示例配置
├── README.md
├── internal/
│   ├── config/             # 配置加载与增删改（写回 toml）
│   │   └── config.go
│   ├── db/                 # 连接抽象层（纯逻辑，无 UI 依赖）
│   │   ├── db.go           # Connection / SQLConn / KVConn 接口 + Result 类型
│   │   ├── postgres.go     # pgx 实现
│   │   └── redis.go        # go-redis 实现
│   └── ui/
│       ├── app.go          # 顶层 model：屏幕路由 + 全局快捷键
│       ├── screen_connect.go   # 屏 1：连接选择/管理
│       ├── screen_main.go      # 屏 2：浏览器 + 编辑器 + 结果
│       └── components/      # 可复用气泡组件封装
│           ├── browser.go   # 左侧树/列表
│           ├── editor.go    # textarea 封装
│           └── results.go   # 表格 + viewport 滚动
```

### 模块边界

- `internal/db` 是纯逻辑层，**不 import** bubbletea/lipgloss，可单测。
- `internal/ui` 只依赖 `db` 的接口和 `Result` 结构，不直接碰驱动。
- `config` 与 `db`、`ui` 解耦：`main.go` 把 `*config.Config` 注入 `ui`，把单条
  `Connection` 配置注入 `db` 工厂。
- 屏幕之间不共享可变状态，靠 `app.go` 的 `mode` 字段路由；切屏 = 替换当前子 model，
  旧屏释放其 `db.Connection`。

---

## 3. 配置与连接模型

### 配置文件

路径：`~/.config/heidisql-tui/config.toml`（可用 `--config <path>` 覆盖）。

```toml
[[connections]]
name = "pg-prod"
driver = "postgres"          # "postgres" | "redis"
host = "10.0.0.5"
port = 5432
user = "readonly"
password = "..."             # 明文存储，README 标注服务器文件权限风险
database = "appdb"           # PG 用；Redis 忽略
# 可选：
# sslmode = "prefer"        # PG 专用，默认 prefer

[[connections]]
name = "redis-cache"
driver = "redis"
host = "10.0.0.6"
port = 6379
password = "..."
db = 0                       # Redis 专用，默认 0
```

### 结构体（`internal/config`）

```go
type Connection struct {
    Name     string `toml:"name"`
    Driver   string `toml:"driver"`   // "postgres" | "redis"
    Host     string `toml:"host"`
    Port     int    `toml:"port"`
    User     string `toml:"user"`
    Password string `toml:"password"`
    Database string `toml:"database"` // PG
    DB       int    `toml:"db"`        // Redis
    SSLMode  string `toml:"sslmode"`   // PG 可选
}

type Config struct {
    Connections []Connection `toml:"connections"`
}
```

### 加载与增删改

- `Load(path)` → 解析 toml；文件不存在则创建空模板（含示例注释），进入连接屏空状态。
- TUI 内**不做**配置文件表单编辑界面。连接屏提供：
  - 列表浏览 + `Enter` 连接
  - `n` 新增：内联输入框收集 name/driver/host/port/user/password，确认后 `Add()` 追加并
    写回 toml
  - `d` 删除选中连接：确认后 `Remove()` 并写回 toml
  - 编辑（`e`）**MVP 不实现**，改走手改 toml + 重启
- 写回用 `BurntSushi/toml` 编码整个 `Config`（注释会被丢弃——README 说明编辑配置请直接改 toml）。
- 工厂 `db.Open(cfg config.Connection) (Connection, error)` 按 `Driver` 分派。

### 安全说明

密码明文存储。README 提示服务器上 `chmod 600` 该配置文件。MVP 不做加密。

---

## 4. 数据访问层（`internal/db`）

UI 只依赖接口，不碰具体驱动。

### 核心类型

```go
type Connection interface {
    Close() error
    Ping(ctx context.Context) error
}

// SQLConn — PG 这类关系型。Redis 不实现。
type SQLConn interface {
    Connection
    ListSchemas(ctx context.Context) ([]string, error)
    ListTables(ctx context.Context, schema string) ([]TableInfo, error)
    Exec(ctx context.Context, sql string) (*SQLResult, error)
}

// KVConn — Redis 这类 KV。PG 不实现。
type KVConn interface {
    Connection
    ScanKeys(ctx context.Context, cursor uint64, pattern string, count int64) (next uint64, keys []string, err error)
    KeyInfo(ctx context.Context, key string) (*KeyInfo, error)
    Exec(ctx context.Context, args ...string) (*KVResult, error)
}

type TableInfo struct{ Schema, Name, Kind string }   // Kind: "table"|"view"
type KeyInfo   struct{ Type string; Size int64; TTL int64 }  // TTL: -1=永久 -2=不存在

type SQLResult struct {
    Columns []string
    Rows    [][]string   // 每行每列字符串表示，二进制/时间统一格式化
    Affected int64       // 非 SELECT 时有效，Rows 为空
}

type KVResult struct {
    Type    string      // "string"|"array"|"integer"|"nil"|"error"
    Str     string      // Type=string/error
    Int     int64       // Type=integer
    Arr     []string    // Type=array
}
```

### PostgreSQL 实现（`postgres.go`）

- 驱动：`github.com/jackc/pgx/v5`，直接用 `pgx.Conn`，**不走** `database/sql`。
- `ListSchemas`：`SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' ORDER BY 1`
- `ListTables`：`SELECT schemaname, tablename, 'table' FROM pg_tables WHERE schemaname=$1
  UNION ALL SELECT schemaname, viewname, 'view' FROM pg_views WHERE schemaname=$1 ORDER BY 2`
- `Exec`：以 `SELECT`/`WITH` 开头（忽略前导空白）走查询路径，`Query` 逐行取值转字符串；
  否则 `Exec` 取 `RowsAffected()`。单条执行，不支持多语句/事务（MVP）。
- 所有值（`timestamptz`、`bytea`、`numeric` 等）一律格式化为字符串。UI 不做类型感知高亮。

### Redis 实现（`redis.go`）

- 驱动：`github.com/redis/go-redis/v9` 的 `Client`，用 `Do`/`Process` 支持任意命令。
- `ScanKeys`：`client.Scan(ctx, cursor, pattern, count).Iterator()` 封装，避免 `KEYS *` 阻塞。
- `KeyInfo`：`TYPE` + `MEMORY USAGE`（>=4.0 可用，否则 Size=-1）+ `TTL`。
- `Exec`：空格分词命令转发给 `client.Do`，结果归一化到 `KVResult`。

### 连接生命周期

- `db.Open(cfg)` 建连 + `Ping`，失败返回 error。
- 单连接会话下 `app.go` 持有当前 `Connection`，切出主屏/退出时 `Close`。
- 所有方法接收 `context.Context`，UI 层默认 30s 超时。

### 错误模型

- 驱动错误原样上抛（`pgconn.PgError`、`redis.Error`），UI 显示 message 文本。
- 无自定义 error 包装层。

---

## 5. UI — 屏 1：连接屏

### 布局

```
┌─ HeidiSQL TUI ─────────────────────────────── 1/1 ┐
│                                                    │
│   > pg-prod        postgres  10.0.0.5:5432         │
│     redis-cache    redis     10.0.0.6:6379         │
│     pg-local       postgres  127.0.0.1:5432        │
│                                                    │
├────────────────────────────────────────────────────┤
│  ↑↓ 移动  Enter 连接  n 新增  d 删除  Ctrl+Q 退出  │
└────────────────────────────────────────────────────┘
```

### Model

```go
type connectModel struct {
    list      list.Model
    config    *config.Config
    cfgPath   string
    adding    bool
    addForm   *addFormModel
    err       string
    quitting  bool
}
```

### 交互

- `↑/↓` 移动光标，`Enter` 选中：
  - `db.Open(cfg)` 异步发起（`tea.Cmd` 返回 `connectedMsg{conn}` 或 `errMsg`），进行中显示 "connecting..."。
  - 成功 → 切换到 `screenMain`；失败 → 底部红字错误摘要。
- `n` 新增：`adding=true`，焦点转入 `addForm`。`Tab` 下一字段，`Enter` 确认 → `Add()` + 写回 toml + 刷新列表；`Esc` 取消。driver 字段左右切换 `postgres`/`redis`。
- `d` 删除：底部 `确认删除 <name>? y/n`，`y` 确认 → `Remove()` + 写回 toml；`n`/`Esc` 取消。
- `Ctrl+Q` 退出程序。
- 编辑（`e`）MVP 不实现。

### 空状态与错误

- 配置为空：列表区显示 "No connections configured. Press `n` to add one, or edit <cfgPath>."
- 连接失败：底部红字驱动错误摘要，不阻塞列表。

---

## 6. UI — 屏 2：主屏

### 布局

```
┌─ HeidiSQL TUI — pg-prod ──────────────────────────────────┐
│ Browser            │ Editor (textarea)                     │
│                    │                                       │
│ ▼ public           │ SELECT * FROM users WHERE id = $1;   │
│   > users    [T]   │                                       │
│     orders   [T]   │                                       │
│     user_log [V]   │                                       │
│                    ├───────────────────────────────────────┤
│                    │ Results                               │
│                    │ ┌─id─┬─name──┬─email────────┐         │
│                    │ │ 1  │ alice │ a@x.com      │         │
│                    │ │ 2  │ bob   │ b@x.com      │         │
│                    │ └────┴───────┴──────────────┘         │
├────────────────────┴───────────────────────────────────────┤
│ Rows: 2  0.8s  │ Ctrl+R 执行  Tab 切焦  Esc 返回  Ctrl+Q 退出 │
└────────────────────────────────────────────────────────────┘
```

### 焦点模型

`Tab`/`Shift+Tab` 在 Browser → Editor → Results 间循环，当前焦点区高亮边框。

### Model

```go
type focusArea int
const ( focusBrowser focusArea = iota; focusEditor; focusResults )

type mainModel struct {
    conn     db.Connection
    sqlConn  db.SQLConn   // PG 时非 nil
    kvConn   db.KVConn    // Redis 时非 nil
    driver   string
    connName string
    browser  browserModel
    editor   editorModel
    results  resultsModel
    focus    focusArea
    status   string
    err      string
    width, height int
}
```

### 区域 A — Browser（`browser.go`）

**PG 模式（树）**：
- 顶层 schema 列表（`ListSchemas`），展开显示表/视图（`ListTables`），结果缓存。
- 选中表 `Enter` → Editor 插入 `SELECT * FROM <schema>.<table> LIMIT 100;`，切焦到 Editor，不自动执行。

**Redis 模式（列表）**：
- 顶部 pattern 输入框（默认 `*`），回车触发 `ScanKeys`（count=200）。
- 选中键 `Enter` → 按类型插入命令：string→`GET`，hash→`HGETALL`，list→`LRANGE 0 -1`，set→`SMEMBERS`，zset→`ZRANGE 0 -1 WITHSCORES`，切焦到 Editor。
- `r` 刷新当前 pattern 扫描。
- 不做键值网格内编辑。

### 区域 B — Editor（`editor.go`）

- `bubbles/textarea`，纯文本，无语法高亮。
- `Ctrl+R` 执行当前全部内容（避免 `Ctrl+Enter` 终端兼容问题）。
- 异步 `tea.Cmd`：PG 调 `sqlConn.Exec`，Redis 调 `kvConn.Exec(splitArgs(text)...)`，返回 `resultMsg` 或 `errMsg`。
- 执行中状态栏显示 "running..."。

### 区域 C — Results（`results.go`）

- SELECT：`bubbles/table`，列宽自适应屏宽（超长截断 `...`）。`↑/↓` 滚动行，`←/→` 横向滚动列，`PgUp/PgDn` 翻页。表头始终可见。
- 非 SELECT：状态栏 `Rows affected: N`，结果区显示文本。
- Redis `Exec`：按 `KVResult.Type` 渲染——string 文本，integer 数字，array 逐行，nil `(nil)`，error 红字。
- 大结果集（>1000 行）只渲染前 1000 行，状态栏标注 `showing 1-1000 of N`。不分页加载。

### 区域 D — 状态栏

- 左：`Rows: 2  0.8s` / `Rows affected: 5` / `running...` / 错误摘要。
- 右：当前焦点区操作提示（随焦点变化）。

### 全局快捷键

- `Tab`/`Shift+Tab`：焦点区轮转。
- `Ctrl+R`：执行。
- `Esc`：清空 Editor / Editor 空时返回连接屏。
- `Ctrl+Q`：退出程序（所有屏统一）。

---

## 7. 错误处理

| 场景 | 处理 |
|---|---|
| 配置文件解析失败 | `main.go` 报错退出，打印 toml 语法错误位置 |
| 配置文件缺失 | `config.Load` 创建空模板，进入连接屏空状态 |
| 连接失败 | 连接屏底部红字驱动错误 message |
| 查询超时 | `ctx` 30s，结果区 "查询超时 (30s)" |
| 查询出错 | 结果区红字驱动 message + PG `SQLSTATE` 前缀 |
| 结果集过大 | 渲染前 1000 行，状态栏标注，不报错 |
| 连接断开 | 驱动错误显示；不自动重连，手动返回连接屏重选 |

不做：自定义错误包装层、错误码翻译表、自动重连、错误日志文件。

---

## 8. 测试策略

`internal/db` 纯逻辑无 UI，单测重点；`internal/ui` 薄，靠手测。

### `internal/config`

- `Load` 解析正常 toml、空文件、缺字段、非法 driver。
- `Add`/`Remove` + `Save` 往返一致。
- 不测 toml 库本身。

### `internal/db`（集成测试）

- 用 **testcontainers-go**（`postgres` / `redis` module）起一次性容器。
- 覆盖：`ListSchemas`/`ListTables`、`Exec` SELECT 列名与行、`Exec` INSERT `Affected`、
  Redis `ScanKeys` 分页、`KeyInfo` 各类型、`Exec` 各 RESP 类型。
- build tag `//go:build integration` 隔离，`go test ./...` 默认只跑 config，`go test -tags=integration` 跑 db。

### `internal/ui`

- 不写组件渲染快照（终端宽度依赖，脆且价值低）。
- 手测清单放 `tui/` 下，覆盖连接、查询、Redis 命令、大结果集、错误显示。

---

## 9. 构建与依赖

### 依赖（全纯 Go，无 CGO）

- `github.com/charmbracelet/bubbletea` + `bubbles` + `lipgloss`
- `github.com/jackc/pgx/v5`
- `github.com/redis/go-redis/v9`
- `github.com/BurntSushi/toml`
- `github.com/testcontainers/testcontainers-go`（仅测试）

### 构建

- `cd tui && CGO_ENABLED=0 go build -o ../out/heidisql-tui ./`
- 产物 `out/heidisql-tui`（`out/` 已被 `.gitignore` 忽略），单文件 scp 到服务器即用。
- 交叉编译：`GOOS=linux GOARCH=amd64` 默认目标即服务器。

### 命名

- 模块名 `heidisql-tui`，二进制名 `heidisql-tui`。
- README 首段注明：独立 Go TUI，复用 HeidiSQL 概念不共享代码，仅覆盖 PG+Redis 子集。

---

## 10. 交付边界

本设计完成后下一步为 **writing-plans** 阶段，产出分步实现计划。实现范围严格限定于
上述 MVP；后续扩展（更多引擎、网格编辑、多连接）不在本次计划内。
