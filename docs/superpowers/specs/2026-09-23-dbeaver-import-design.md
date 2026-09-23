# DBeaver 连接导入 config.toml — 设计文档

**日期**：2026-09-23
**状态**：已通过头脑风暴评审，待实现计划
**模块路径**：`tui/`（已加入 `.gitignore`，不提交）

---

## 1. 背景与目标

用户在本机用 DBeaver 管理多个数据库连接，需要把这些连接快速迁到 heidisql-tui 的
`config.toml`，避免在 TUI 内逐条手敲。本设计新增一个 **CLI 子命令**
`heidisql-tui import-dbeaver`，从 DBeaver workspace 读取连接元数据与（加密存储的）凭据，
解密后按 heidisql-tui 的 `Connection` 模型映射，与现有 `config.toml` 按名合并后写回。

### 关键决策（头脑风暴结论）

| 维度 | 决策 |
|---|---|
| 入口 | CLI 子命令 `import-dbeaver`，`main.go` 在 `flag.Parse` 前用 `os.Args[1]` 守卫分派 |
| 密码处理 | 自动解密 DBeaver `credentials-config.json`（AES-128-CBC，公开硬编码密钥），明文写入 config.toml。与 config.toml 现状（明文存密码）一致 |
| 合并策略 | 按连接名合并：同名覆盖，不同名追加。保留用户手加的连接 |
| 驱动过滤 | 仅导入 postgres + redis，其他驱动（MySQL 等）跳过并在输出里提示跳过条数 |
| 格式范围 | 仅支持 DBeaver 6.1.3+ 的现代 JSON 格式（`data-sources.json` + 加密 `credentials-config.json`）。不支持旧版 XML |
| CLI 框架 | 不引入第三方 CLI 库；`os.Args[1]` 守卫 + `flag` 子集即可 |
| 加密依赖 | 仅用 Go 标准库 `crypto/aes` + `crypto/cipher`，无新增第三方依赖 |

### 非目标（YAGNI）

- 旧版 XML（`.dbeaver-data-sources.xml`，6.1.3 以前）格式
- master password 模式（DBeaver 用户自设主密码加密本地配置）—— 公开硬编码密钥模式覆盖绝大多数默认安装
- 反向导出（config.toml → DBeaver）
- TUI 内交互式导入向导
- 多 workspace 批量导入（一次一个 workspace）
- 连接连通性校验（导入后不自动测试连接）

---

## 2. DBeaver 配置格式（源码确认）

以下字段名与加密方案均已对照 DBeaver 源码（`DataSourceSerializerModern.java`、
`RegistryConstants.java`、`BaseProjectImpl.java`、`DefaultValueEncryptor.java`、
`DataSourceParser.java`）确认。

### 2.1 Workspace 定位

`<workspace>/.dbeaver/` 目录，OS 候选路径（按优先级）：

| OS | 候选路径 |
|---|---|
| Linux | `~/.local/share/DBeaverData/workspace6/General/.dbeaver/` |
| Linux(snap) | `~/snap/dbeaver-ce/current/.local/share/DBeaverData/workspace6/General/.dbeaver/` |
| Linux(flatpak) | `~/.var/app/io.dbeaver.DBeaverCommunity/data/DBeaverData/workspace6/General/.dbeaver/` |
| macOS | `~/Library/DBeaverData/workspace6/General/.dbeaver/` |
| macOS(HB Cask) | `~/Library/Application Support/DBeaverData/workspace6/General/.dbeaver/` |
| Windows | `%APPDATA%\DBeaverData\workspace6\General\.dbeaver\` |

`--workspace <path>` 显式覆盖，跳过自动探测。

### 2.2 data-sources.json

```json
{
  "connections": {
    "postgres-jdbc-abc12345": {
      "provider": "postgresql",
      "driver": "postgres-jdbc",
      "name": "pg-prod",
      "configuration": {
        "host": "10.0.0.5",
        "port": "5432",
        "database": "appdb",
        "user": "readonly",
        "url": "jdbc:postgresql://10.0.0.5:5432/appdb",
        "configurationType": "MANUAL",
        "properties": { "sslmode": "prefer" }
      },
      "folder": "Work",
      "save-password": true
    },
    "redis-ce-xyz": {
      "provider": "generic",
      "driver": "redis-ce",
      "name": "redis-cache",
      "configuration": {
        "host": "10.0.0.6",
        "port": "6379",
        "database": "0",
        "user": ""
      }
    }
  }
}
```

关键字段（`RegistryConstants`）：

| JSON 字段 | 常量 | 含义 |
|---|---|---|
| `name` | `ATTR_NAME` | 显示名 |
| `provider` | `ATTR_PROVIDER` | 数据源提供者 id（如 `postgresql`） |
| `driver` | `ATTR_DRIVER` | 驱动 id（如 `postgres-jdbc`、`redis-ce`） |
| `configuration.host` | `ATTR_HOST` | 主机 |
| `configuration.port` | `ATTR_PORT` | 端口（**字符串**） |
| `configuration.database` | `ATTR_DATABASE` | 库名 / Redis 的 db 索引 |
| `configuration.user` | `ATTR_USER` | 用户（可能在 credentials 里） |
| `configuration.url` | `ATTR_URL` | JDBC URL（备用解析源） |
| `configuration.properties` | `TAG_PROPERTIES` | 驱动属性（含 pg `sslmode`） |

> `provider`+`driver` 决定驱动归类。确认到的真实值：
> - PostgreSQL：`provider="postgresql"`，`driver="postgres-jdbc"`（及其他含 `postgres` 的变体）
> - Redis：`provider="generic"`，`driver="redis-ce"`（DBeaver Redis 走 generic JDBC 适配器）

### 2.3 credentials-config.json（加密）

- **算法**：AES-128-CBC，PKCS5/PKCS7 padding（`AES/CBC/PKCS5Padding`）
- **密钥**：16 字节硬编码常量 `LOCAL_KEY_CACHE = {-70,-69,74,-97,119,74,-72,83,-55,108,45,101,61,-2,84,74}`
  = hex `babb4a9f774ab853c96c2d653dfe544a`（`BaseProjectImpl.java:95`）
- **文件布局**：前 16 字节 = IV，其余 = 密文（`DefaultValueEncryptor.encryptValue`）
- **解密后 JSON**：

```json
{
  "postgres-jdbc-abc12345": {
    "#connection": { "user": "readonly", "password": "s3cret" }
  }
}
```

`#connection` 子节点键名来自 `DataSourceParser.NODE_CONNECTION`（`DataSourceParser.java:42`）。
`user`/`password` 键来自 `RegistryConstants.ATTR_USER`/`ATTR_PASSWORD`。

### 2.4 格式回退

按顺序尝试，首个成功即用：

1. **整文件 AES-CBC 解密**（DBeaver 21+，主流）。
2. **纯 JSON 直读**（极旧版或 master-password 关闭时明文落盘的退化情况）。
3. **Base64 解码后 JSON 解析**（个别版本用 base64 包裹）。

三种回退均失败则 `LoadCredentials` 返回空 map + nil error（不阻断导入，仅缺密码）。

---

## 3. 项目布局（新增部分）

```
tui/
├── main.go                 # 改：加 os.Args[1]=="import-dbeaver" 守卫
├── import_dbeaver.go       # 新（package main）：子命令入口、flag、合并、输出
├── internal/
│   ├── config/
│   │   ├── config.go       # 改：加 Upsert(conn)
│   │   └── config_test.go  # 改：加 TestUpsert
│   └── dbeaver/            # 新包：纯逻辑，无 UI/无第三方依赖
│       ├── dbeaver.go      # FindWorkspace / LoadDataSources / LoadCredentials / Import / 解密
│       └── dbeaver_test.go # 纯逻辑单测（含测试内加密的 credentials fixture）
```

### 模块边界

- `internal/dbeaver` 纯逻辑，仅依赖 Go 标准库（`crypto/aes`、`crypto/cipher`、`encoding/json`、`encoding/base64`、`os`/`path/filepath`）。不 import bubbletea/config，可独立单测。
- `import_dbeaver.go`（package main）依赖 `internal/dbeaver` + `internal/config`，负责 IO 编排与人类可读输出。
- 现有 TUI 路径（`tea.NewProgram`）零改动。

---

## 4. internal/dbeaver 包设计

### 4.1 类型

```go
package dbeaver

// DataSource — data-sources.json 中单条连接的解析结构（只取关心的字段）。
type DataSource struct {
    Provider      string
    Driver        string
    Name          string
    Configuration map[string]any // host/port/database/user/url/properties 等
}

// Credentials — credentials-config.json 中单条凭据解密后的结构。
type Credentials struct {
    User     string
    Password string
}

// ImportedConn — 一条已映射到 heidisql-tui 模型的导入结果。
type ImportedConn struct {
    Name     string
    Driver   string // "postgres" | "redis"
    Host     string
    Port     int
    User     string
    Password string
    Database string // pg
    DB       int    // redis
    SSLMode  string // pg
}

// SkippedConn — 被跳过的连接（不支持的驱动）。
type SkippedConn struct {
    Name     string
    Provider string
    Driver   string
    Reason   string
}

// Result — Import 的返回。
type Result struct {
    Imported []ImportedConn
    Skipped  []SkippedConn
}
```

### 4.2 公开函数

```go
// FindWorkspace 返回 DBeaver .dbeaver 目录路径。
// explicit 非空则直接用；否则按 OS 候选路径探测，首个存在者胜出。
func FindWorkspace(explicit string) (string, error)

// LoadDataSources 解析 <ws>/data-sources.json，返回 connections map（按 connId 索引）。
func LoadDataSources(ws string) (map[string]DataSource, error)

// LoadCredentials 解密 <ws>/credentials-config.json。
// 按顺序尝试：整文件 AES-CBC → 纯 JSON → base64+JSON。全部失败返回空 map + nil。
func LoadCredentials(ws string) (map[string]Credentials, error)

// Import 读取并映射整个 workspace，返回导入结果与跳过列表。不触碰 config.toml。
func Import(ws string) (*Result, error)
```

### 4.3 解密实现要点

```go
var localKey = []byte{0xba, 0xbb, 0x4a, 0x9f, 0x77, 0x4a, 0xb8, 0x53,
    0xc9, 0x6c, 0x2d, 0x65, 0x3d, 0xfe, 0x54, 0x4a}

func decryptCredentials(data []byte) (map[string]Credentials, error) {
    if len(data) < 16 {
        return nil, errTooShort
    }
    iv := data[:16]
    ciphertext := data[16:]
    block, err := aes.NewCipher(localKey)
    if err != nil { return nil, err }
    mode := cipher.NewCBCDecrypter(block, iv)
    plain := make([]byte, len(ciphertext))
    mode.CryptBlocks(plain, ciphertext)
    plain, err = pkcs7Unpad(plain)
    if err != nil { return nil, err }
    // JSON 解析为 map[connId]struct{ #connection: {user,password} }
    ...
}
```

PKCS7 去填充手写（Go CBC 不自动 unpad）：
- 取末字节 `n`（1–16），校验末 `n` 字节全等于 `n`，截断。

### 4.4 驱动检测与字段映射

`detectDriver(provider, driver string) (string, bool)` —— 两者拼接转小写后子串匹配：

| 命中子串 | 返回 driver | 支持 |
|---|---|---|
| `postgres` | `"postgres"` | ✓ |
| `redis` | `"redis"` | ✓ |
| 其他 | — | ✗ 跳过 |

字段映射（`mapConn(ds DataSource, cr Credentials) ImportedConn`）：

| config.toml 字段 | 来源 |
|---|---|
| `name` | `ds.Name`（空则回退 connId） |
| `driver` | `detectDriver` 结果 |
| `host` | `ds.Configuration["host"]`；空则从 `url` JDBC 解析 |
| `port` | `Configuration["port"]` 字符串转 int；空则 `normalize()` 补默认（pg 5432 / redis 6379） |
| `user` | `cr.User` 优先，空回退 `Configuration["user"]` |
| `password` | `cr.Password`（解密后明文） |
| `database`(pg) | `Configuration["database"]`；空则从 JDBC url path 解析 |
| `db`(redis) | `Configuration["database"]` 字符串转 int，默认 0 |
| `sslmode`(pg) | `Configuration["properties"].(map)["sslmode"]`；空则留给 `normalize()` 补 `prefer` |

JDBC url 解析（`parseJDBCURL(url string) (host string, port int, database string)`）：
- 形如 `jdbc:postgresql://host:port/db?...`，正则或字符串切分取 `://` 后到 `/` 或 `?` 之前。
- 仅当 `configuration.host` 为空时启用，作为回退。

### 4.5 Import 编排

```
func Import(ws):
    ds := LoadDataSources(ws)
    cr := LoadCredentials(ws)
    for connId, d := range ds:
        driver, ok := detectDriver(d.Provider, d.Driver)
        if !ok:
            skipped = append(skipped, {d.Name, d.Provider, d.Driver, "unsupported driver"})
            continue
        imported = append(imported, mapConn(d, cr[connId]))
    return &Result{Imported, Skipped}
```

---

## 5. config 包改动

新增 `Upsert`（按名覆盖或追加），复用现有 `normalize`：

```go
// Upsert 按 Name 覆盖同名连接，无同名则追加。
func (c *Config) Upsert(conn Connection) {
    conn = normalize(conn)
    for i := range c.Connections {
        if c.Connections[i].Name == conn.Name {
            c.Connections[i] = conn
            return
        }
    }
    c.Connections = append(c.Connections, conn)
}
```

不动现有 `Add`/`Remove`/`Load`/`Save`。

---

## 6. CLI 子命令（main.go + import_dbeaver.go）

### 6.1 main.go 守卫

```go
func main() {
    if len(os.Args) > 1 && os.Args[1] == "import-dbeaver" {
        os.Exit(runImportDBeaver(os.Args[2:]))
    }
    // 原有 TUI 启动逻辑不变
    var cfgPath string
    flag.StringVar(&cfgPath, "config", defaultConfigPath(), "config file path")
    flag.Parse()
    ...
}
```

### 6.2 import_dbeaver.go

```go
func runImportDBeaver(args []string) int {
    fs := flag.NewFlagSet("import-dbeaver", flag.ContinueOnError)
    cfgPath := fs.String("config", defaultConfigPath(), "config file path")
    ws := fs.String("workspace", "", "DBeaver workspace .dbeaver dir (auto-detect if empty)")
    dryRun := fs.Bool("dry-run", false, "print what would be imported without writing")
    if err := fs.Parse(args); err != nil { return 2 }

    workspace, err := dbeaver.FindWorkspace(*ws)
    if err != nil { fmt.Fprintln(os.Stderr, err); return 1 }

    result, err := dbeaver.Import(workspace)
    if err != nil { fmt.Fprintln(os.Stderr, err); return 1 }

    cfg, err := config.Load(*cfgPath)
    if err != nil { fmt.Fprintln(os.Stderr, err); return 1 }

    for _, ic := range result.Imported {
        cfg.Upsert(config.Connection{...ic...})
    }

    // 输出摘要到 stdout
    fmt.Printf("DBeaver workspace: %s\n", workspace)
    fmt.Printf("Imported: %d\n", len(result.Imported))
    for _, c := range result.Imported {
        fmt.Printf("  + %-20s %s %s:%d\n", c.Name, c.Driver, c.Host, c.Port)
    }
    if n := len(result.Skipped); n > 0 {
        fmt.Printf("Skipped: %d (unsupported driver)\n", n)
        for _, s := range result.Skipped {
            fmt.Printf("  - %-20s provider=%s driver=%s\n", s.Name, s.Provider, s.Driver)
        }
    }

    if *dryRun {
        fmt.Println("(dry-run, no changes written)")
        return 0
    }
    if err := cfg.Save(*cfgPath); err != nil { fmt.Fprintln(os.Stderr, err); return 1 }
    fmt.Printf("Written to %s\n", *cfgPath)
    return 0
}
```

### 6.3 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功（含 dry-run） |
| 1 | 运行错误（workspace 未找到 / 解析失败 / 写失败） |
| 2 | flag 解析错误 |

---

## 7. 错误处理

| 场景 | 处理 |
|---|---|
| workspace 未找到 | `FindWorkspace` 返回错误，列出探测过的候选路径 |
| data-sources.json 缺失 | `LoadDataSources` 返回空 map + nil（视为无连接，导入 0 条，退出 0） |
| data-sources.json 解析失败 | 返回错误，退出 1 |
| credentials 文件缺失 | `LoadCredentials` 返回空 map + nil，连接导入但无密码 |
| 解密失败（非加密文件/损坏） | 回退纯 JSON → base64；全失败则空 map + nil |
| port/database 非数字 | 跳过该字段，留给 `normalize()` 补默认；不报错 |
| config.toml 加载失败 | 报错退出 1 |
| config.toml 写失败 | 报错退出 1 |

---

## 8. 测试策略

### 8.1 internal/dbeaver（纯逻辑单测）

fixture 在测试内动态构造（不落盘真实 fixture 文件）：

- **解密往返**：测试内用已知密钥+随机 IV 加密一段 JSON，写临时文件，调用 `LoadCredentials`，断言解出正确的 user/password。验证 AES 实现 + PKCS7 unpad 正确。
- **格式回退**：同一份明文 JSON 分别以「纯文本」「base64」写入，断言两种回退都能解出。
- **驱动检测**：`postgres-jdbc`/`postgresql` → postgres；`redis-ce`/`redis` → redis；`mysql8` → 跳过。
- **字段映射**：构造含 host/port/database/user/password 的 DataSource + Credentials，断言映射到 `ImportedConn` 各字段正确；port 字符串→int。
- **JDBC url 回退**：`configuration.host` 为空、`url=jdbc:postgresql://h:5432/db` 时，断言解析出 host/port/database。
- **跳过统计**：混入一条 mysql，断言 `Result.Skipped` 含 1 条、`Imported` 不含它。
- **Import 端到端**：临时目录写 `data-sources.json` + 加密 `credentials-config.json`，调用 `Import`，断言完整 Result。
- **FindWorkspace**：`--workspace` 显式路径优先；空时探测候选（用临时目录模拟存在）。

用 `//go:build integration`？**否**——dbeaver 包无外部依赖（不起容器），全部走默认 `go test`，与 `internal/config` 一致。

### 8.2 internal/config（追加）

- `TestUpsert`：空 config 插入两条；对同名再 Upsert 断言覆盖而非追加；Upsert 后 `normalize` 生效（port 默认 / sslmode 默认）。

### 8.3 import_dbeaver.go（轻量）

- 主入口逻辑薄，靠 dbeaver/config 单测覆盖核心。
- 可选：用临时目录构造完整 workspace + 空 config.toml，跑 `runImportDBeaver` 断言退出码 0 + 文件写入。

---

## 9. 安全说明

- DBeaver 的 AES 密钥是**公开硬编码**于 DBeaver 源码的常量（`BaseProjectImpl.LOCAL_KEY_CACHE`），非秘密。本工具复用该密钥解密本机用户自己的凭据，不构成密钥泄露。
- 解密后的明文密码写入 `config.toml`（明文存储，README 已标注 `chmod 600`）。与现状一致，不引入新的明文落盘点。
- `--dry-run` 可在不写盘前提下预览导入内容。
- 不做：master password 模式、传输加密、密码二次加密存储。

---

## 10. 交付边界

本设计完成后下一步为 **writing-plans** 阶段，产出分步实现计划。实现范围严格限定于
上述 MVP：CLI 子命令 + dbeaver 解析/解密包 + config.Upsert + 单测。后续扩展
（TUI 内导入向导、旧版 XML、多 workspace、连通性校验）不在本次计划内。
