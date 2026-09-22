# TUI 数据库 & Redis 查询工具 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `tui/` 目录实现一个基于 bubbletea 的精简终端工具，支持 PostgreSQL 查询执行与 Redis 命令执行，单连接会话，独立配置文件。

**Architecture:** 三层 Go 包：`internal/config`（toml 配置增删改）、`internal/db`（驱动抽象层 + pgx/go-redis 实现）、`internal/ui`（bubbletea 屏幕 + 组件）。UI 依赖 db 接口，db 依赖 config 结构体。单连接会话，三屏向导式（连接屏 → 主屏）。

**Tech Stack:** Go 1.27、bubbletea + bubbles + lipgloss、pgx/v5、go-redis/v9、BurntSushi/toml、testcontainers-go（测试）。

## Global Constraints

- `tui/` 目录已在 `.gitignore` 中，**所有产物不提交 git**（但 plan/spec 文档在 `docs/` 内，可提交）。
- 静态二进制：`CGO_ENABLED=0 go build`，单文件部署到服务器。
- 支持引擎仅 PostgreSQL + Redis。
- 不做网格内逐格编辑、多连接、SQL 语法高亮、自动重连、错误码翻译表。
- 配置密码明文存储，README 提示 `chmod 600`。
- 退出键统一 `Ctrl+Q`；执行键 `Ctrl+R`。
- db 层所有方法接收 `context.Context`，UI 层默认 30s 查询超时、10s 连接超时。
- 模块名 `heidisql-tui`，二进制名 `heidisql-tui`，产物输出到 `out/heidisql-tui`。
- db 层 import `heidisql-tui/internal/config`（config 是叶子包，无反向依赖）。
- UI 组件包 `internal/ui/components`，UI 主包 `internal/ui` import 组件；组件**不** import `internal/ui`（避免循环）。

## File Structure

| 文件 | 职责 |
|---|---|
| `tui/go.mod` | 模块定义与依赖 |
| `tui/main.go` | 入口：flag、加载 config、启动 tea.Program |
| `tui/internal/config/config.go` | Connection/Config 结构体、Load/Save/Add/Remove |
| `tui/internal/config/config_test.go` | config 单测 |
| `tui/internal/db/db.go` | 接口与类型定义 + Open 工厂 |
| `tui/internal/db/postgres.go` | pgConn 实现 SQLConn |
| `tui/internal/db/redis.go` | redisConn 实现 KVConn |
| `tui/internal/db/postgres_test.go` | PG 集成测试（build tag integration） |
| `tui/internal/db/redis_test.go` | Redis 集成测试（build tag integration） |
| `tui/internal/ui/app.go` | 顶层 model + screen 接口 + 路由 + 消息类型 |
| `tui/internal/ui/screen_connect.go` | 连接屏 + 新增表单 |
| `tui/internal/ui/screen_main.go` | 主屏：组合 browser/editor/results |
| `tui/internal/ui/components/styles.go` | 共享 lipgloss 边框样式 |
| `tui/internal/ui/components/editor.go` | textarea 封装 |
| `tui/internal/ui/components/results.go` | 表格/文本结果渲染 |
| `tui/internal/ui/components/browser.go` | PG 树 + Redis 键列表 |
| `tui/README.md` | 用法说明 |
| `tui/config.example.toml` | 示例配置 |

---

### Task 1: 项目脚手架 + config 包（TDD）

**Files:**
- Create: `tui/go.mod`
- Create: `tui/internal/config/config.go`
- Create: `tui/internal/config/config_test.go`
- Create: `tui/config.example.toml`

**Interfaces:**
- Produces: `config.Connection`、`config.Config`、`config.Load(path) (*Config, error)`、`(*Config) Save(path) error`、`(*Config) Add(Connection)`、`(*Config) Remove(name string) bool`

- [ ] **Step 1: 初始化模块与目录**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
mkdir -p tui/internal/config
cd tui
go mod init heidisql-tui
```
Expected: 生成 `tui/go.mod`，内容含 `module heidisql-tui`。

- [ ] **Step 2: 写失败的 config 测试**

Create `tui/internal/config/config_test.go`:

```go
package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadMissingFileCreatesTemplate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Connections) != 0 {
		t.Fatalf("expected 0 connections, got %d", len(c.Connections))
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("template not created: %v", err)
	}
}

func TestLoadParseAndNormalize(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	content := `[[connections]]
name = "pg"
driver = "postgres"
host = "localhost"
user = "u"
password = "p"
database = "d"

[[connections]]
name = "r"
driver = "redis"
host = "localhost"
password = "p"
`
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	c, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(c.Connections) != 2 {
		t.Fatalf("expected 2, got %d", len(c.Connections))
	}
	if c.Connections[0].Port != 5432 {
		t.Errorf("pg port = %d, want 5432", c.Connections[0].Port)
	}
	if c.Connections[0].SSLMode != "prefer" {
		t.Errorf("pg sslmode = %q, want prefer", c.Connections[0].SSLMode)
	}
	if c.Connections[1].Port != 6379 {
		t.Errorf("redis port = %d, want 6379", c.Connections[1].Port)
	}
}

func TestAddRemoveSaveRoundtrip(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.toml")
	c := &Config{}
	c.Add(Connection{Name: "a", Driver: "redis", Host: "h", Port: 6379})
	c.Add(Connection{Name: "b", Driver: "postgres", Host: "h", Port: 5432})
	if !c.Remove("a") {
		t.Fatal("remove a failed")
	}
	if len(c.Connections) != 1 || c.Connections[0].Name != "b" {
		t.Fatalf("unexpected connections: %+v", c.Connections)
	}
	if err := c.Save(path); err != nil {
		t.Fatal(err)
	}
	c2, err := Load(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(c2.Connections) != 1 || c2.Connections[0].Name != "b" {
		t.Fatalf("roundtrip mismatch: %+v", c2.Connections)
	}
}
```

- [ ] **Step 3: 运行测试验证失败**

Run: `cd tui && go test ./internal/config/`
Expected: FAIL — `Load` 等未定义。

- [ ] **Step 4: 添加 toml 依赖**

Run: `cd tui && go get github.com/BurntSushi/toml`
Expected: go.mod 增加 toml 依赖。

- [ ] **Step 5: 实现 config.go**

Create `tui/internal/config/config.go`:

```go
package config

import (
	"os"
	"path/filepath"

	"github.com/BurntSushi/toml"
)

type Connection struct {
	Name     string `toml:"name"`
	Driver   string `toml:"driver"`
	Host     string `toml:"host"`
	Port     int    `toml:"port"`
	User     string `toml:"user"`
	Password string `toml:"password"`
	Database string `toml:"database"`
	DB       int    `toml:"db"`
	SSLMode  string `toml:"sslmode"`
}

type Config struct {
	Connections []Connection `toml:"connections"`
}

func Load(path string) (*Config, error) {
	c := &Config{}
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			return nil, err
		}
		if err := os.WriteFile(path, []byte("# heidisql-tui connections\n"), 0o600); err != nil {
			return nil, err
		}
		return c, nil
	}
	if _, err := toml.DecodeFile(path, c); err != nil {
		return nil, err
	}
	for i := range c.Connections {
		c.Connections[i] = normalize(c.Connections[i])
	}
	return c, nil
}

func (c *Config) Save(path string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return toml.NewEncoder(f).Encode(c)
}

func (c *Config) Add(conn Connection) {
	c.Connections = append(c.Connections, normalize(conn))
}

func (c *Config) Remove(name string) bool {
	for i, conn := range c.Connections {
		if conn.Name == name {
			c.Connections = append(c.Connections[:i], c.Connections[i+1:]...)
			return true
		}
	}
	return false
}

func normalize(c Connection) Connection {
	if c.Port == 0 {
		switch c.Driver {
		case "postgres":
			c.Port = 5432
		case "redis":
			c.Port = 6379
		}
	}
	if c.Driver == "postgres" && c.SSLMode == "" {
		c.SSLMode = "prefer"
	}
	return c
}
```

- [ ] **Step 6: 运行测试验证通过**

Run: `cd tui && go test ./internal/config/`
Expected: PASS（3 个测试）。

- [ ] **Step 7: 写示例配置**

Create `tui/config.example.toml`:

```toml
# heidisql-tui 配置示例
# 实际路径：~/.config/heidisql-tui/config.toml
# 服务器上请 chmod 600 此文件（密码明文）

[[connections]]
name = "pg-prod"
driver = "postgres"
host = "10.0.0.5"
port = 5432
user = "readonly"
password = "change-me"
database = "appdb"
sslmode = "prefer"

[[connections]]
name = "redis-cache"
driver = "redis"
host = "10.0.0.6"
port = 6379
password = "change-me"
db = 0
```

- [ ] **Step 8: 提交（仅文档进 git，tui/ 被忽略）**

```bash
cd /data/projects_local/pascal/HeidiSQL
git add docs/superpowers/plans/2026-09-22-tui-database-redis-tool.md
git -c user.name=boe -c user.email=boe@local commit -m "docs: TUI 工具实现计划"
```
> `tui/` 已在 `.gitignore`，无需 add。

---

### Task 2: db 类型与接口 + Open 工厂

**Files:**
- Create: `tui/internal/db/db.go`

**Interfaces:**
- Consumes: `config.Connection`（from Task 1）
- Produces: `db.Connection`、`db.SQLConn`、`db.KVConn`、`db.TableInfo`、`db.KeyInfo`、`db.SQLResult`、`db.KVResult`、`db.Open(config.Connection) (Connection, error)`

- [ ] **Step 1: 实现 db.go（类型与接口）**

Create `tui/internal/db/db.go`:

```go
package db

import (
	"context"
	"fmt"
	"time"

	"heidisql-tui/internal/config"
)

const connectTimeout = 10 * time.Second

type Connection interface {
	Close() error
	Ping(ctx context.Context) error
}

type SQLConn interface {
	Connection
	ListSchemas(ctx context.Context) ([]string, error)
	ListTables(ctx context.Context, schema string) ([]TableInfo, error)
	Exec(ctx context.Context, sql string) (*SQLResult, error)
}

type KVConn interface {
	Connection
	ScanKeys(ctx context.Context, cursor uint64, pattern string, count int64) (next uint64, keys []string, err error)
	KeyInfo(ctx context.Context, key string) (*KeyInfo, error)
	Exec(ctx context.Context, args ...string) (*KVResult, error)
}

type TableInfo struct {
	Schema string
	Name   string
	Kind   string // "table" | "view"
}

type KeyInfo struct {
	Type string
	Size int64
	TTL  int64 // -1 永久, -2 不存在
}

type SQLResult struct {
	Columns  []string
	Rows     [][]string
	Affected int64
}

type KVResult struct {
	Type string   // "string"|"array"|"integer"|"nil"|"error"
	Str  string
	Int  int64
	Arr  []string
}

func Open(cfg config.Connection) (Connection, error) {
	switch cfg.Driver {
	case "postgres":
		return openPostgres(cfg)
	case "redis":
		return openRedis(cfg)
	default:
		return nil, fmt.Errorf("unsupported driver: %s", cfg.Driver)
	}
}
```

- [ ] **Step 2: 编译验证**

Run: `cd tui && go build ./internal/db/`
Expected: 失败，`openPostgres`/`openRedis` 未定义（预期，下两任务实现）。仅确认语法无误：
```bash
cd tui && go vet ./internal/db/ 2>&1 | grep -v "openPostgres\|openRedis" || true
```

> db.go 本身无可独立测试的纯逻辑（接口定义）。其行为由 Task 3/4 的集成测试覆盖。

---

### Task 3: PostgreSQL 驱动实现 + 集成测试

**Files:**
- Create: `tui/internal/db/postgres.go`
- Create: `tui/internal/db/postgres_test.go`

**Interfaces:**
- Consumes: `config.Connection`、Task 2 的接口定义
- Produces: `openPostgres`、`pgConn` 实现 `db.SQLConn`

- [ ] **Step 1: 添加 pgx 依赖**

Run: `cd tui && go get github.com/jackc/pgx/v5`
Expected: go.mod 增加 pgx。

- [ ] **Step 2: 写失败的集成测试**

Create `tui/internal/db/postgres_test.go`:

```go
//go:build integration

package db

import (
	"context"
	"testing"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/postgres"
	"heidisql-tui/internal/config"
)

func TestPostgresListAndExec(t *testing.T) {
	ctx := context.Background()
	pgC, err := postgres.Run(ctx, "docker.io/postgres:16-alpine",
		postgres.WithDatabase("test"),
		postgres.WithUsername("test"),
		postgres.WithPassword("test"),
	)
	if err != nil {
		t.Skipf("postgres container unavailable: %v", err)
	}
	t.Cleanup(func() { _ = pgC.Terminate(ctx) })

	host, err := pgC.Host(ctx)
	if err != nil {
		t.Fatal(err)
	}
	port, err := pgC.MappedPort(ctx, "5432")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Connection{
		Driver: "postgres", Host: host, Port: port.Int(),
		User: "test", Password: "test", Database: "test", SSLMode: "disable",
	}
	conn, err := Open(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	sqlc := conn.(SQLConn)

	if _, err := sqlc.Exec(ctx, "CREATE TABLE t (id serial PRIMARY KEY, name text)"); err != nil {
		t.Fatal(err)
	}
	if _, err := sqlc.Exec(ctx, "INSERT INTO t (name) VALUES ('alice'), ('bob')"); err != nil {
		t.Fatal(err)
	}

	schemas, err := sqlc.ListSchemas(ctx)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, s := range schemas {
		if s == "public" {
			found = true
		}
	}
	if !found {
		t.Fatalf("public schema not found: %v", schemas)
	}

	tables, err := sqlc.ListTables(ctx, "public")
	if err != nil {
		t.Fatal(err)
	}
	if len(tables) != 1 || tables[0].Name != "t" {
		t.Fatalf("unexpected tables: %+v", tables)
	}

	res, err := sqlc.Exec(ctx, "SELECT id, name FROM t ORDER BY id")
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Columns) != 2 || res.Columns[0] != "id" {
		t.Fatalf("columns: %v", res.Columns)
	}
	if len(res.Rows) != 2 || res.Rows[0][1] != "alice" {
		t.Fatalf("rows: %v", res.Rows)
	}
}
```

- [ ] **Step 3: 运行测试验证失败**

Run: `cd tui && go test -tags=integration ./internal/db/ -run TestPostgres`
Expected: 编译失败（`openPostgres` 未实现）。

- [ ] **Step 4: 添加 testcontainers 依赖**

Run: `cd tui && go get github.com/testcontainers/testcontainers-go/modules/postgres`
Expected: 依赖加入。

- [ ] **Step 5: 实现 postgres.go**

Create `tui/internal/db/postgres.go`:

```go
package db

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"heidisql-tui/internal/config"
)

type pgConn struct {
	conn *pgx.Conn
}

func openPostgres(cfg config.Connection) (Connection, error) {
	sslmode := cfg.SSLMode
	if sslmode == "" {
		sslmode = "prefer"
	}
	dsn := fmt.Sprintf("host=%s port=%d user=%s password=%s dbname=%s sslmode=%s",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.Database, sslmode)
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, err
	}
	if err := conn.Ping(ctx); err != nil {
		_ = conn.Close(context.Background())
		return nil, err
	}
	return &pgConn{conn: conn}, nil
}

func (p *pgConn) Close() error { return p.conn.Close(context.Background()) }

func (p *pgConn) Ping(ctx context.Context) error { return p.conn.Ping(ctx) }

func (p *pgConn) ListSchemas(ctx context.Context) ([]string, error) {
	rows, err := p.conn.Query(ctx,
		"SELECT nspname FROM pg_namespace WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema' ORDER BY 1")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var s string
		if err := rows.Scan(&s); err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}

func (p *pgConn) ListTables(ctx context.Context, schema string) ([]TableInfo, error) {
	q := `SELECT schemaname, tablename, 'table' FROM pg_tables WHERE schemaname=$1
	      UNION ALL
	      SELECT schemaname, viewname, 'view' FROM pg_views WHERE schemaname=$1
	      ORDER BY 2`
	rows, err := p.conn.Query(ctx, q, schema)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []TableInfo
	for rows.Next() {
		var ti TableInfo
		if err := rows.Scan(&ti.Schema, &ti.Name, &ti.Kind); err != nil {
			return nil, err
		}
		out = append(out, ti)
	}
	return out, rows.Err()
}

func (p *pgConn) Exec(ctx context.Context, sql string) (*SQLResult, error) {
	upper := strings.ToUpper(strings.TrimSpace(sql))
	if strings.HasPrefix(upper, "SELECT") || strings.HasPrefix(upper, "WITH") {
		return p.query(ctx, sql)
	}
	cmd, err := p.conn.Exec(ctx, sql)
	if err != nil {
		return nil, pgErr(err)
	}
	return &SQLResult{Affected: cmd.RowsAffected()}, nil
}

func (p *pgConn) query(ctx context.Context, sql string) (*SQLResult, error) {
	rows, err := p.conn.Query(ctx, sql)
	if err != nil {
		return nil, pgErr(err)
	}
	defer rows.Close()
	fields := rows.FieldDescriptions()
	cols := make([]string, len(fields))
	for i, f := range fields {
		cols[i] = f.Name
	}
	var out [][]string
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return nil, err
		}
		row := make([]string, len(vals))
		for i, v := range vals {
			row[i] = pgValToString(v)
		}
		out = append(out, row)
	}
	if err := rows.Err(); err != nil {
		return nil, pgErr(err)
	}
	return &SQLResult{Columns: cols, Rows: out}, nil
}

func pgValToString(v any) string {
	switch x := v.(type) {
	case nil:
		return "NULL"
	case []byte:
		return string(x)
	case string:
		return x
	default:
		return fmt.Sprintf("%v", v)
	}
}

// pgErr 把 pgconn.PgError 格式化为 "SQLSTATE: message"，其它错误原样返回。
func pgErr(err error) error {
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) {
		return fmt.Errorf("%s: %s", pgErr.Code, pgErr.Message)
	}
	return err
}
```

- [ ] **Step 6: 运行集成测试验证通过**

Run: `cd tui && go test -tags=integration ./internal/db/ -run TestPostgres -v`
Expected: PASS（需 Docker 可用；若 Docker 不可用则 t.Skip）。

- [ ] **Step 7: 普通编译验证（不含 integration tag）**

Run: `cd tui && go build ./internal/db/`
Expected: 成功（redis.go 尚未存在，但 db 包暂不引用 openRedis 之外的 redis 符号——注意：db.go 的 Open 引用了 openRedis，会编译失败）。

> 说明：Task 2 的 `Open` 引用了 `openRedis`，故需 Task 4 完成后 `go build ./internal/db/` 才通过。本步骤仅验证 postgres.go 自身无语法错误：`cd tui && go vet ./internal/db/postgres.go 2>/dev/null || true`。

---

### Task 4: Redis 驱动实现 + 集成测试

**Files:**
- Create: `tui/internal/db/redis.go`
- Create: `tui/internal/db/redis_test.go`

**Interfaces:**
- Consumes: `config.Connection`、Task 2 接口
- Produces: `openRedis`、`redisConn` 实现 `db.KVConn`

- [ ] **Step 1: 添加 go-redis 依赖**

Run: `cd tui && go get github.com/redis/go-redis/v9`
Expected: 依赖加入。

- [ ] **Step 2: 写失败的集成测试**

Create `tui/internal/db/redis_test.go`:

```go
//go:build integration

package db

import (
	"context"
	"testing"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/modules/redis"
	"heidisql-tui/internal/config"
)

func TestRedisScanKeyInfoExec(t *testing.T) {
	ctx := context.Background()
	rC, err := redis.Run(ctx, "docker.io/redis:7-alpine")
	if err != nil {
		t.Skipf("redis container unavailable: %v", err)
	}
	t.Cleanup(func() { _ = rC.Terminate(ctx) })

	host, err := rC.Host(ctx)
	if err != nil {
		t.Fatal(err)
	}
	port, err := rC.MappedPort(ctx, "6379")
	if err != nil {
		t.Fatal(err)
	}
	cfg := config.Connection{
		Driver: "redis", Host: host, Port: port.Int(), DB: 0,
	}
	conn, err := Open(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	kvc := conn.(KVConn)

	if _, err := kvc.Exec(ctx, "SET", "greeting", "hello"); err != nil {
		t.Fatal(err)
	}
	if _, err := kvc.Exec(ctx, "HSET", "h", "f1", "v1", "f2", "v2"); err != nil {
		t.Fatal(err)
	}

	next, keys, err := kvc.ScanKeys(ctx, 0, "*", 100)
	if err != nil {
		t.Fatal(err)
	}
	_ = next
	if len(keys) != 2 {
		t.Fatalf("expected 2 keys, got %v", keys)
	}

	ki, err := kvc.KeyInfo(ctx, "greeting")
	if err != nil {
		t.Fatal(err)
	}
	if ki.Type != "string" {
		t.Fatalf("type=%s want string", ki.Type)
	}
	if ki.TTL != -1 {
		t.Fatalf("ttl=%d want -1", ki.TTL)
	}

	res, err := kvc.Exec(ctx, "GET", "greeting")
	if err != nil {
		t.Fatal(err)
	}
	if res.Type != "string" || res.Str != "hello" {
		t.Fatalf("GET result: %+v", res)
	}

	res2, err := kvc.Exec(ctx, "HGETALL", "h")
	if err != nil {
		t.Fatal(err)
	}
	if res2.Type != "array" || len(res2.Arr) != 4 {
		t.Fatalf("HGETALL result: %+v", res2)
	}

	res3, err := kvc.Exec(ctx, "GET", "missing")
	if err != nil {
		t.Fatal(err)
	}
	if res3.Type != "nil" {
		t.Fatalf("missing key: %+v", res3)
	}
}
```

- [ ] **Step 3: 运行测试验证失败**

Run: `cd tui && go test -tags=integration ./internal/db/ -run TestRedis`
Expected: 编译失败（`openRedis` 未实现）。

- [ ] **Step 4: 添加 testcontainers redis 模块依赖**

Run: `cd tui && go get github.com/testcontainers/testcontainers-go/modules/redis`
Expected: 依赖加入。

- [ ] **Step 5: 实现 redis.go**

Create `tui/internal/db/redis.go`:

```go
package db

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"

	"heidisql-tui/internal/config"
)

type redisConn struct {
	client *redis.Client
}

func openRedis(cfg config.Connection) (Connection, error) {
	client := redis.NewClient(&redis.Options{
		Addr:     fmt.Sprintf("%s:%d", cfg.Host, cfg.Port),
		Password: cfg.Password,
		DB:       cfg.DB,
	})
	ctx, cancel := context.WithTimeout(context.Background(), connectTimeout)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, err
	}
	return &redisConn{client: client}, nil
}

func (r *redisConn) Close() error { return r.client.Close() }

func (r *redisConn) Ping(ctx context.Context) error { return r.client.Ping(ctx).Err() }

func (r *redisConn) ScanKeys(ctx context.Context, cursor uint64, pattern string, count int64) (uint64, []string, error) {
	cmd := r.client.Scan(ctx, cursor, pattern, count)
	keys, next := cmd.Val()
	if err := cmd.Err(); err != nil {
		return 0, nil, err
	}
	return next, keys, nil
}

func (r *redisConn) KeyInfo(ctx context.Context, key string) (*KeyInfo, error) {
	t, err := r.client.Type(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	if t == "none" {
		return &KeyInfo{Type: "none", TTL: -2}, nil
	}
	ttl, err := r.client.TTL(ctx, key).Result()
	if err != nil {
		return nil, err
	}
	ttlInt := int64(ttl.Seconds())
	if ttl < 0 {
		ttlInt = -1
	}
	size := int64(-1)
	if mu, err := r.client.MemoryUsage(ctx, key).Result(); err == nil {
		size = mu
	}
	return &KeyInfo{Type: t, Size: size, TTL: ttlInt}, nil
}

func (r *redisConn) Exec(ctx context.Context, args ...string) (*KVResult, error) {
	if len(args) == 0 {
		return nil, fmt.Errorf("empty command")
	}
	anyArgs := make([]any, len(args))
	for i, a := range args {
		anyArgs[i] = a
	}
	val, err := r.client.Do(ctx, anyArgs...).Result()
	if err != nil {
		if err == redis.Nil {
			return &KVResult{Type: "nil"}, nil
		}
		return &KVResult{Type: "error", Str: err.Error()}, nil
	}
	return toKVResult(val), nil
}

func toKVResult(v any) *KVResult {
	switch x := v.(type) {
	case nil:
		return &KVResult{Type: "nil"}
	case string:
		return &KVResult{Type: "string", Str: x}
	case int64:
		return &KVResult{Type: "integer", Int: x}
	case []byte:
		return &KVResult{Type: "string", Str: string(x)}
	case []interface{}:
		arr := make([]string, len(x))
		for i, e := range x {
			arr[i] = fmt.Sprintf("%v", e)
		}
		return &KVResult{Type: "array", Arr: arr}
	default:
		return &KVResult{Type: "string", Str: fmt.Sprintf("%v", v)}
	}
}

// 避免 time 未使用告警（TTL 使用了 time.Duration）
var _ = time.Second
```

- [ ] **Step 6: 运行集成测试验证通过**

Run: `cd tui && go test -tags=integration ./internal/db/ -run TestRedis -v`
Expected: PASS（需 Docker）。

- [ ] **Step 7: 全包编译验证**

Run: `cd tui && go build ./internal/db/`
Expected: 成功（openPostgres + openRedis 均已实现）。

---

### Task 5: UI 脚手架 + 连接屏 + 主屏桩

**Files:**
- Create: `tui/internal/ui/app.go`
- Create: `tui/internal/ui/screen_connect.go`
- Create: `tui/internal/ui/screen_main.go`（桩，Task 9 填充）
- Create: `tui/internal/ui/components/styles.go`

**Interfaces:**
- Consumes: `config`、`db`（from Task 1-4）
- Produces: `ui.NewApp(*config.Config, string) tea.Model`、`screen` 接口、消息类型 `errMsg`/`connectedMsg`

- [ ] **Step 1: 添加 bubbletea/bubbles/lipgloss 依赖**

Run: `cd tui && go get github.com/charmbracelet/bubbletea github.com/charmbracelet/bubbles github.com/charmbracelet/lipgloss`
Expected: 依赖加入。

- [ ] **Step 2: 实现 app.go**

Create `tui/internal/ui/app.go`:

```go
package ui

import (
	tea "github.com/charmbracelet/bubbletea"

	"heidisql-tui/internal/config"
	"heidisql-tui/internal/db"
)

type appModel struct {
	cfg     *config.Config
	cfgPath string
	screen  screen
	width   int
	height  int
}

type screen interface {
	Init() tea.Cmd
	Update(tea.Msg, *appModel) (screen, tea.Cmd)
	View() string
}

type errMsg struct{ err error }
type connectedMsg struct {
	conn   db.Connection
	driver string
	name   string
}

func NewApp(cfg *config.Config, cfgPath string) tea.Model {
	m := &appModel{cfg: cfg, cfgPath: cfgPath}
	m.screen = newConnectModel(cfg, cfgPath)
	return m
}

func (m *appModel) Init() tea.Cmd { return m.screen.Init() }

func (m *appModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if w, ok := msg.(tea.WindowSizeMsg); ok {
		m.width, m.height = w.Width, w.Height
	}
	var cmd tea.Cmd
	m.screen, cmd = m.screen.Update(msg, m)
	return m, cmd
}

func (m *appModel) View() string { return m.screen.View() }
```

- [ ] **Step 3: 实现 screen_connect.go**

Create `tui/internal/ui/screen_connect.go`:

```go
package ui

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"heidisql-tui/internal/config"
	"heidisql-tui/internal/db"
)

type connItem struct {
	cfg config.Connection
}

func (i connItem) FilterValue() string { return i.cfg.Name }
func (i connItem) Title() string       { return i.cfg.Name }
func (i connItem) Description() string {
	return fmt.Sprintf("%s  %s:%d", i.cfg.Driver, i.cfg.Host, i.cfg.Port)
}

type connectModel struct {
	list    list.Model
	cfg     *config.Config
	cfgPath string
	err     string
	adding  bool
	form    *addForm
}

func newConnectModel(cfg *config.Config, cfgPath string) *connectModel {
	l := list.New(toItems(cfg.Connections), list.NewDefaultDelegate(), 80, 20)
	l.Title = "HeidiSQL TUI — Select Connection"
	l.SetShowStatusBar(false)
	l.SetFilteringEnabled(false)
	return &connectModel{cfg: cfg, cfgPath: cfgPath, list: l}
}

func toItems(conns []config.Connection) []list.Item {
	items := make([]list.Item, 0, len(conns))
	for i := range conns {
		items = append(items, connItem{cfg: conns[i]})
	}
	return items
}

func (m *connectModel) Init() tea.Cmd { return nil }

func (m *connectModel) Update(msg tea.Msg, app *appModel) (screen, tea.Cmd) {
	if m.adding {
		return m.form.formUpdate(msg, app)
	}
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.list.SetSize(msg.Width, msg.Height-2)
	case errMsg:
		m.err = msg.err.Error()
	case connectedMsg:
		return newMainModel(msg.conn, msg.driver, msg.name, app.width, app.height), nil
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+q":
			return m, tea.Quit
		case "enter":
			it, ok := m.list.SelectedItem().(connItem)
			if !ok {
				return m, nil
			}
			return m, connectCmd(it.cfg)
		case "n":
			m.form = newAddForm(m.cfg, m, app)
			m.adding = true
			return m, nil
		case "d":
			it, ok := m.list.SelectedItem().(connItem)
			if ok {
				m.cfg.Remove(it.cfg.Name)
				_ = m.cfg.Save(m.cfgPath)
				m.list.SetItems(toItems(m.cfg.Connections))
			}
			return m, nil
		}
	}
	var cmd tea.Cmd
	m.list, cmd = m.list.Update(msg)
	return m, cmd
}

func connectCmd(cfg config.Connection) tea.Cmd {
	return func() tea.Msg {
		conn, err := db.Open(cfg)
		if err != nil {
			return errMsg{err}
		}
		return connectedMsg{conn: conn, driver: cfg.Driver, name: cfg.Name}
	}
}

func (m *connectModel) View() string {
	if m.adding {
		return m.form.View()
	}
	var b strings.Builder
	b.WriteString(m.list.View())
	if m.err != "" {
		b.WriteString("\n" + lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Render(m.err))
	}
	b.WriteString("\n↑↓ move  enter connect  n add  d delete  ctrl+q quit")
	return b.String()
}

// ---- 新增连接表单 ----

type addForm struct {
	cfg     *config.Config
	fields  []formField
	focus   int
	driver  int // 0=postgres, 1=redis
	app     *appModel
	owner   *connectModel
}

type formField struct {
	label string
	input textinput.Model
}

func newAddForm(cfg *config.Config, owner *connectModel, app *appModel) *addForm {
	f := &addForm{cfg: cfg, driver: 0, owner: owner, app: app}
	f.rebuild()
	return f
}

func (f *addForm) rebuild() {
	common := []struct{ label, key string }{
		{"name", "name"},
		{"host", "host"},
		{"port", "port"},
		{"user", "user"},
		{"password", "password"},
	}
	prev := map[string]string{}
	for _, fld := range f.fields {
		prev[fld.label] = fld.input.Value()
	}
	fields := []formField{{label: "driver"}}
	for _, c := range common {
		ti := textinput.New()
		ti.Prompt = ""
		if v, ok := prev[c.label]; ok {
			ti.SetValue(v)
		}
		if c.key == "password" {
			ti.EchoMode = textinput.EchoPassword
		}
		fields = append(fields, formField{label: c.label, input: ti})
	}
	extra := formField{label: "database"}
	if f.driver == 1 {
		extra.label = "db"
	}
	ti := textinput.New()
	ti.Prompt = ""
	if v, ok := prev[extra.label]; ok {
		ti.SetValue(v)
	}
	fields = append(fields, extra)
	// driver 字段不是 textinput，构造占位
	fields[0].input = textinput.New()
	f.fields = fields
	if f.focus >= len(f.fields) {
		f.focus = 0
	}
	for i := range f.fields {
		if i == 0 {
			continue
		}
		if i == f.focus {
			f.fields[i].input.Focus()
		} else {
			f.fields[i].input.Blur()
		}
	}
}

func (f *addForm) formUpdate(msg tea.Msg, app *appModel) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "esc":
			f.owner.adding = false
			return f.owner, nil
		case "tab":
			f.focus = (f.focus + 1) % len(f.fields)
			f.rebuild()
			return f.owner, nil
		case "shift+tab":
			f.focus = (f.focus - 1 + len(f.fields)) % len(f.fields)
			f.rebuild()
			return f.owner, nil
		case "left", "right":
			if f.focus == 0 {
				if msg.String() == "left" {
					f.driver = 0
				} else {
					f.driver = 1
				}
				f.rebuild()
				return f.owner, nil
			}
		case "enter":
			c := f.toConnection()
			f.cfg.Add(c)
			_ = f.cfg.Save(f.owner.cfgPath)
			f.owner.adding = false
			f.owner.list.SetItems(toItems(f.cfg.Connections))
			return f.owner, nil
		}
	}
	if f.focus != 0 {
		var cmd tea.Cmd
		f.fields[f.focus].input, cmd = f.fields[f.focus].input.Update(msg)
	}
	return f.owner, nil
}

func (f *addForm) toConnection() config.Connection {
	get := func(label string) string {
		for _, fld := range f.fields {
			if fld.label == label {
				return fld.input.Value()
			}
		}
		return ""
	}
	c := config.Connection{
		Name:     get("name"),
		Driver:   []string{"postgres", "redis"}[f.driver],
		Host:     get("host"),
		User:     get("user"),
		Password: get("password"),
	}
	if p := get("port"); p != "" {
		fmt.Sscanf(p, "%d", &c.Port)
	}
	if f.driver == 0 {
		c.Database = get("database")
	} else {
		if d := get("db"); d != "" {
			fmt.Sscanf(d, "%d", &c.DB)
		}
	}
	return c
}

func (f *addForm) View() string {
	var b strings.Builder
	b.WriteString("Add Connection (tab next  enter save  esc cancel)\n\n")
	for i, fld := range f.fields {
		marker := "  "
		if i == f.focus {
			marker = "> "
		}
		if i == 0 {
			drv := []string{"postgres", "redis"}[f.driver]
			b.WriteString(fmt.Sprintf("%sdriver: %s  (←/→ toggle)\n", marker, drv))
			continue
		}
		b.WriteString(fmt.Sprintf("%s%-10s %s\n", marker, fld.label+":", fld.input.View()))
	}
	return b.String()
}
```

- [ ] **Step 4: 实现主屏桩 screen_main.go**

Create `tui/internal/ui/screen_main.go`:

```go
package ui

import (
	"fmt"

	tea "github.com/charmbracelet/bubbletea"

	"heidisql-tui/internal/db"
)

type mainModel struct {
	conn   db.Connection
	driver string
	name   string
}

func newMainModel(conn db.Connection, driver, name string, width, height int) *mainModel {
	return &mainModel{conn: conn, driver: driver, name: name}
}

func (m *mainModel) Init() tea.Cmd { return nil }

func (m *mainModel) Update(msg tea.Msg, app *appModel) (screen, tea.Cmd) {
	if k, ok := msg.(tea.KeyMsg); ok {
		switch k.String() {
		case "ctrl+q", "esc":
			_ = m.conn.Close()
			return newConnectModel(app.cfg, app.cfgPath), nil
		}
	}
	return m, nil
}

func (m *mainModel) View() string {
	return fmt.Sprintf("Connected: %s (%s)\nMain screen — under construction.\n(ctrl+q back)", m.name, m.driver)
}
```

- [ ] **Step 5: 实现 components/styles.go**

Create `tui/internal/ui/components/styles.go`:

```go
package components

import "github.com/charmbracelet/lipgloss"

func BorderStyle() lipgloss.Style {
	return lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		BorderForeground(lipgloss.Color("39")).
		Padding(0, 1)
}
```

- [ ] **Step 6: 编译验证**

Run: `cd tui && go build ./internal/ui/...`
Expected: 成功。

- [ ] **Step 7: 手测连接屏**

写一个临时 main 然后跑（Task 10 才正式写 main，此处用 `go run` 临时入口）：
```bash
cd tui && cat > /tmp/tui_smoke.go <<'EOF'
package main
import ("os";"tea";"heidisql-tui/internal/config";"heidisql-tui/internal/ui")
...
EOF
```
> 简化：Task 10 会写正式 main.go。此处仅 `go vet ./internal/ui/` 验证。

Run: `cd tui && go vet ./internal/ui/`
Expected: 无错误。

---

### Task 6: Editor 组件

**Files:**
- Create: `tui/internal/ui/components/editor.go`

**Interfaces:**
- Produces: `components.NewEditor() *Editor`、`(*Editor) Focus/Blur/SetText/Text/Clear/Update/View`

- [ ] **Step 1: 实现 editor.go**

Create `tui/internal/ui/components/editor.go`:

```go
package components

import (
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/bubbles/textarea"
)

type Editor struct {
	ta      textarea.Model
	focused bool
}

func NewEditor() *Editor {
	ta := textarea.New()
	ta.Placeholder = "SELECT * FROM ... ;   or   GET key"
	ta.ShowLineNumbers = false
	ta.SetHeight(6)
	ta.CharLimit = 0
	return &Editor{ta: ta}
}

func (e *Editor) Focus() { e.focused = true; e.ta.Focus() }
func (e *Editor) Blur()  { e.focused = false; e.ta.Blur() }

func (e *Editor) SetText(s string) { e.ta.SetValue(s) }
func (e *Editor) Text() string     { return e.ta.Value() }
func (e *Editor) Clear()           { e.ta.SetValue("") }

func (e *Editor) Update(msg tea.Msg) (*Editor, tea.Cmd) {
	var cmd tea.Cmd
	e.ta, cmd = e.ta.Update(msg)
	return e, cmd
}

func (e *Editor) View(width, height int) string {
	e.ta.SetWidth(width - 4)
	e.ta.SetHeight(height - 2)
	return BorderStyle().Width(width).Height(height).Render(e.ta.View())
}
```

- [ ] **Step 2: 编译验证**

Run: `cd tui && go build ./internal/ui/components/`
Expected: 成功。

---

### Task 7: Results 组件

**Files:**
- Create: `tui/internal/ui/components/results.go`

**Interfaces:**
- Consumes: `db.SQLResult`、`db.KVResult`（from Task 2）
- Produces: `components.NewResults() *Results`、`SetSQL`、`SetKV`、`SetError`、`Update`、`View`

- [ ] **Step 1: 实现 results.go**

Create `tui/internal/ui/components/results.go`:

```go
package components

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/bubbles/table"
	tea "github.com/charmbracelet/bubbletea"

	"heidisql-tui/internal/db"
)

const maxResultRows = 1000

type Results struct {
	t     table.Model
	text  string
	mode  string // "table" | "text"
}

func NewResults() *Results {
	t := table.New(table.WithColumns([]table.Column{{Title: "", Width: 20}}))
	return &Results{t: t, mode: "text", text: "(no results)"}
}

func (r *Results) Focus() {}
func (r *Results) Blur()  {}

func (r *Results) SetSQL(res *db.SQLResult) {
	if len(res.Columns) == 0 {
		r.mode = "text"
		r.text = fmt.Sprintf("Rows affected: %d", res.Affected)
		return
	}
	r.mode = "table"
	cols := make([]table.Column, len(res.Columns))
	for i, c := range res.Columns {
		w := len(c) + 2
		if w < 8 {
			w = 8
		}
		if w > 30 {
			w = 30
		}
		cols[i] = table.Column{Title: c, Width: w}
	}
	rows := make([]table.Row, 0, len(res.Rows))
	for i, row := range res.Rows {
		if i >= maxResultRows {
			break
		}
		rows = append(rows, table.Row(row))
	}
	r.t.SetColumns(cols)
	r.t.SetRows(rows)
	if len(res.Rows) > maxResultRows {
		r.text = fmt.Sprintf("showing 1-%d of %d", maxResultRows, len(res.Rows))
	} else {
		r.text = fmt.Sprintf("%d rows", len(res.Rows))
	}
}

func (r *Results) SetKV(res *db.KVResult) {
	r.mode = "text"
	switch res.Type {
	case "string":
		r.text = res.Str
	case "integer":
		r.text = fmt.Sprintf("(integer) %d", res.Int)
	case "nil":
		r.text = "(nil)"
	case "error":
		r.text = "ERROR: " + res.Str
	case "array":
		var b strings.Builder
		for i, e := range res.Arr {
			fmt.Fprintf(&b, "%d) %s\n", i+1, e)
		}
		r.text = strings.TrimRight(b.String(), "\n")
	default:
		r.text = "(unknown)"
	}
}

func (r *Results) SetError(err string) {
	r.mode = "text"
	r.text = "ERROR: " + err
}

func (r *Results) Update(msg tea.Msg) (*Results, tea.Cmd) {
	if r.mode != "table" {
		return r, nil
	}
	var cmd tea.Cmd
	r.t, cmd = r.t.Update(msg)
	return r, cmd
}

func (r *Results) View(width, height int) string {
	if r.mode == "table" {
		r.t.SetWidth(width - 4)
		r.t.SetHeight(height - 4)
		body := r.t.View()
		if r.text != "" {
			body += "\n" + r.text
		}
		return BorderStyle().Width(width).Height(height).Render(body)
	}
	return BorderStyle().Width(width).Height(height).Render(r.text)
}
```

- [ ] **Step 2: 编译验证**

Run: `cd tui && go build ./internal/ui/components/`
Expected: 成功。

---

### Task 8: Browser 组件

**Files:**
- Create: `tui/internal/ui/components/browser.go`

**Interfaces:**
- Consumes: `db.SQLConn`/`db.KVConn`、`db.TableInfo`/`db.KeyInfo`（from Task 2-4）
- Produces: `components.NewBrowser(driver string, sqlc db.SQLConn, kvc db.KVConn) *Browser`、`InsertTemplateMsg`、`Update`、`View`

- [ ] **Step 1: 实现 browser.go**

Create `tui/internal/ui/components/browser.go`:

```go
package components

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"heidisql-tui/internal/db"
)

// InsertTemplateMsg 由 browser 发出，screen_main 据此把模板写入 editor。
type InsertTemplateMsg struct{ Text string }

type browserEntry struct {
	depth int
	text  string
	kind  string // "schema"|"table"|"view"|"key"|"pattern"
}

type Browser struct {
	driver  string
	sqlc    db.SQLConn
	kvc     db.KVConn
	entries []browserEntry
	cursor  int
	// PG 树状态
	loaded  map[string]bool
	expanded map[string]bool
	// Redis pattern
	pattern string
	keysLoaded bool
	err     string
}

func NewBrowser(driver string, sqlc db.SQLConn, kvc db.KVConn) *Browser {
	b := &Browser{
		driver: driver, sqlc: sqlc, kvc: kvc,
		loaded: map[string]bool{}, expanded: map[string]bool{},
		pattern: "*",
	}
	if driver == "postgres" {
		b.entries = []browserEntry{{text: "(loading schemas…)", kind: "pattern"}}
	} else {
		b.entries = []browserEntry{{text: "(press r to scan keys)", kind: "pattern"}}
	}
	return b
}

func (b *Browser) Focus() {}
func (b *Browser) Blur()  {}

// 初始加载命令
func (b *Browser) InitCmd() tea.Cmd {
	if b.driver == "postgres" {
		return b.loadSchemasCmd()
	}
	return nil
}

type schemasLoadedMsg struct{ schemas []string; err error }

func (b *Browser) loadSchemasCmd() tea.Cmd {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	return func() tea.Msg {
		defer cancel()
		ss, err := b.sqlc.ListSchemas(ctx)
		return schemasLoadedMsg{schemas: ss, err: err}
	}
}

type tablesLoadedMsg struct{ schema string; tables []db.TableInfo; err error }

func (b *Browser) loadTablesCmd(schema string) tea.Cmd {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	return func() tea.Msg {
		defer cancel()
		ts, err := b.sqlc.ListTables(ctx, schema)
		return tablesLoadedMsg{schema: schema, tables: ts, err: err}
	}
}

type keysLoadedMsg struct{ keys []string; err error }

func (b *Browser) scanKeysCmd() tea.Cmd {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	return func() tea.Msg {
		defer cancel()
		var keys []string
		var cursor uint64 = 0
		for {
			next, batch, err := b.kvc.ScanKeys(ctx, cursor, b.pattern, 200)
			if err != nil {
				return keysLoadedMsg{err: err}
			}
			keys = append(keys, batch...)
			if next == 0 {
				break
			}
		}
		return keysLoadedMsg{keys: keys}
	}
}

func (b *Browser) Update(msg tea.Msg) (*Browser, tea.Cmd) {
	switch msg := msg.(type) {
	case schemasLoadedMsg:
		if msg.err != nil {
			b.entries = []browserEntry{{text: "error: " + msg.err.Error(), kind: "pattern"}}
			return b, nil
		}
		b.entries = b.entries[:0]
		for _, s := range msg.schemas {
			b.entries = append(b.entries, browserEntry{depth: 0, text: s, kind: "schema"})
		}
	case tablesLoadedMsg:
		if msg.err != nil {
			b.err = msg.err.Error()
			return b, nil
		}
		b.loaded[msg.schema] = true
		b.rebuildWithTables(msg.schema, msg.tables)
	case keysLoadedMsg:
		if msg.err != nil {
			b.entries = []browserEntry{{text: "error: " + msg.err.Error(), kind: "pattern"}}
			return b, nil
		}
		b.keysLoaded = true
		b.entries = b.entries[:0]
		for _, k := range msg.keys {
			b.entries = append(b.entries, browserEntry{depth: 0, text: k, kind: "key"})
		}
		if len(b.entries) == 0 {
			b.entries = []browserEntry{{text: "(no keys)", kind: "pattern"}}
		}
	case tea.KeyMsg:
		switch msg.String() {
		case "up", "k":
			if b.cursor > 0 {
				b.cursor--
			}
		case "down", "j":
			if b.cursor < len(b.entries)-1 {
				b.cursor++
			}
		case "enter":
			return b.handleEnter()
		case "r":
			if b.driver == "redis" {
				return b, b.scanKeysCmd()
			}
		}
	}
	return b, nil
}

func (b *Browser) handleEnter() (*Browser, tea.Cmd) {
	if b.cursor >= len(b.entries) {
		return b, nil
	}
	e := b.entries[b.cursor]
	switch b.driver {
	case "postgres":
		if e.kind == "schema" {
			if b.expanded[e.text] {
				b.expanded[e.text] = false
				b.collapseSchema(e.text)
			} else if b.loaded[e.text] {
				b.expanded[e.text] = true
				// tables already in entries; nothing to reload
			} else {
				return b, b.loadTablesCmd(e.text)
			}
		} else if e.kind == "table" || e.kind == "view" {
			return b, func() tea.Msg {
				return InsertTemplateMsg{Text: fmt.Sprintf("SELECT * FROM %s LIMIT 100;", e.text)}
			}
		}
	case "redis":
		if e.kind == "key" {
			return b, b.keyTemplateCmd(e.text)
		}
	}
	return b, nil
}

func (b *Browser) keyTemplateCmd(key string) tea.Cmd {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	return func() tea.Msg {
		defer cancel()
		ki, err := b.kvc.KeyInfo(ctx, key)
		if err != nil {
			return InsertTemplateMsg{Text: "GET " + key}
		}
		var cmd string
		switch ki.Type {
		case "string":
			cmd = "GET " + key
		case "hash":
			cmd = "HGETALL " + key
		case "list":
			cmd = "LRANGE " + key + " 0 -1"
		case "set":
			cmd = "SMEMBERS " + key
		case "zset":
			cmd = "ZRANGE " + key + " 0 -1 WITHSCORES"
		default:
			cmd = "GET " + key
		}
		return InsertTemplateMsg{Text: cmd}
	}
}

func (b *Browser) rebuildWithTables(schema string, tables []db.TableInfo) {
	var out []browserEntry
	for _, e := range b.entries {
		out = append(out, e)
		if e.kind == "schema" && e.text == schema {
			b.expanded[schema] = true
			for _, t := range tables {
				out = append(out, browserEntry{depth: 1, text: t.Name, kind: t.Kind})
			}
		}
	}
	b.entries = out
}

func (b *Browser) collapseSchema(schema string) {
	var out []browserEntry
	skip := false
	for _, e := range b.entries {
		if e.kind == "schema" && e.text == schema {
			out = append(out, e)
			skip = true
			continue
		}
		if skip && e.depth > 0 {
			continue
		}
		skip = false
		out = append(out, e)
	}
	b.entries = out
}

func (b *Browser) View(width, height int) string {
	var b2 strings.Builder
	if b.driver == "redis" {
		b2.WriteString(fmt.Sprintf("pattern: %s  (r refresh)\n", b.pattern))
	}
	for i, e := range b.entries {
		marker := "  "
		if i == b.cursor {
			marker = "> "
		}
		indent := strings.Repeat("  ", e.depth)
		icon := ""
		switch e.kind {
		case "schema":
			if b.expanded[e.text] {
				icon = "▼ "
			} else {
				icon = "▶ "
			}
		case "table":
			icon = "[T] "
		case "view":
			icon = "[V] "
		case "key":
			icon = "  "
		}
		b2.WriteString(fmt.Sprintf("%s%s%s%s\n", marker, indent, icon, e.text))
	}
	return BorderStyle().Width(width).Height(height).Render(strings.TrimRight(b2.String(), "\n"))
}
```

- [ ] **Step 2: 编译验证**

Run: `cd tui && go build ./internal/ui/components/`
Expected: 成功。

---

### Task 9: 主屏完整实现

**Files:**
- Modify: `tui/internal/ui/screen_main.go`（替换 Task 5 桩）

**Interfaces:**
- Consumes: `components.Browser/Editor/Results`、`db.SQLConn/KVConn`、消息类型 `errMsg`/`connectedMsg`（from Task 5-8）
- Produces: 完整 `mainModel`

- [ ] **Step 1: 重写 screen_main.go**

Replace `tui/internal/ui/screen_main.go` with:

```go
package ui

import (
	"context"
	"fmt"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"heidisql-tui/internal/db"
	"heidisql-tui/internal/ui/components"
)

type focusArea int

const (
	focusBrowser focusArea = iota
	focusEditor
	focusResults
)

type mainModel struct {
	conn    db.Connection
	sqlc    db.SQLConn
	kvc     db.KVConn
	driver  string
	name    string
	browser *components.Browser
	editor  *components.Editor
	results *components.Results
	focus   focusArea
	width   int
	height  int
	status  string
}

func newMainModel(conn db.Connection, driver, name string, width, height int) *mainModel {
	var sqlc db.SQLConn
	var kvc db.KVConn
	if sc, ok := conn.(db.SQLConn); ok {
		sqlc = sc
	}
	if kc, ok := conn.(db.KVConn); ok {
		kvc = kc
	}
	m := &mainModel{
		conn: conn, sqlc: sqlc, kvc: kvc, driver: driver, name: name,
		browser: components.NewBrowser(driver, sqlc, kvc),
		editor:  components.NewEditor(),
		results: components.NewResults(),
		focus:   focusBrowser,
		width:   width, height: height,
	}
	m.editor.Focus()
	return m
}

func (m *mainModel) Init() tea.Cmd {
	return m.browser.InitCmd()
}

type execResultMsg struct {
	sqlRes *db.SQLResult
	kvRes  *db.KVResult
	err    error
	dur    time.Duration
}

func (m *mainModel) execCmd(text string) tea.Cmd {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	start := time.Now()
	return func() tea.Msg {
		defer cancel()
		if m.sqlc != nil {
			res, err := m.sqlc.Exec(ctx, text)
			return execResultMsg{sqlRes: res, err: err, dur: time.Since(start)}
		}
		args := splitArgs(text)
		res, err := m.kvc.Exec(ctx, args...)
		return execResultMsg{kvRes: res, err: err, dur: time.Since(start)}
	}
}

func (m *mainModel) Update(msg tea.Msg, app *appModel) (screen, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
	case components.InsertTemplateMsg:
		m.editor.SetText(msg.Text)
		m.focus = focusEditor
		m.editor.Focus()
		return m, nil
	case execResultMsg:
		if msg.err != nil {
			m.results.SetError(msg.err.Error())
			m.status = "error"
		} else if msg.sqlRes != nil {
			m.results.SetSQL(msg.sqlRes)
			if len(msg.sqlRes.Columns) > 0 {
				m.status = fmt.Sprintf("%d rows  %s", len(msg.sqlRes.Rows), msg.dur.Round(time.Millisecond))
			} else {
				m.status = fmt.Sprintf("Rows affected: %d  %s", msg.sqlRes.Affected, msg.dur.Round(time.Millisecond))
			}
		} else if msg.kvRes != nil {
			m.results.SetKV(msg.kvRes)
			m.status = msg.dur.Round(time.Millisecond).String()
		}
		return m, nil
	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+q":
			_ = m.conn.Close()
			return newConnectModel(app.cfg, app.cfgPath), nil
		case "ctrl+r":
			return m, m.execCmd(m.editor.Text())
		case "tab":
			m.cycleFocus(true)
			return m, nil
		case "shift+tab":
			m.cycleFocus(false)
			return m, nil
		case "esc":
			if m.focus == focusEditor && m.editor.Text() != "" {
				m.editor.Clear()
				return m, nil
			}
		}
	}
	// 按焦点分发
	var cmd tea.Cmd
	switch m.focus {
	case focusBrowser:
		_, cmd = m.browser.Update(msg)
	case focusEditor:
		_, cmd = m.editor.Update(msg)
	case focusResults:
		_, cmd = m.results.Update(msg)
	}
	return m, cmd
}

func (m *mainModel) cycleFocus(forward bool) {
	areas := []focusArea{focusBrowser, focusEditor, focusResults}
	idx := 0
	for i, a := range areas {
		if a == m.focus {
			idx = i
		}
	}
	if forward {
		idx = (idx + 1) % len(areas)
	} else {
		idx = (idx - 1 + len(areas)) % len(areas)
	}
	m.focus = areas[idx]
	m.editor.Blur()
	switch m.focus {
	case focusBrowser:
	case focusEditor:
		m.editor.Focus()
	case focusResults:
	}
}

func (m *mainModel) View() string {
	if m.width == 0 {
		return "loading…"
	}
	// 布局：左 browser | 右(editor 上 / results 下)；底部状态栏
	statusH := 2
	leftW := m.width / 3
	if leftW < 24 {
		leftW = 24
	}
	rightW := m.width - leftW
	editorH := m.height / 2
	resultsH := m.height - editorH - statusH

	left := m.browser.View(leftW, m.height-statusH)
	editor := m.editor.View(rightW, editorH)
	results := m.results.View(rightW, resultsH)

	rightCol := lipgloss.JoinVertical(lipgloss.Left, editor, results)
	top := lipgloss.JoinHorizontal(lipgloss.Top, left, rightCol)

	focusName := []string{"browser", "editor", "results"}[m.focus]
	status := fmt.Sprintf("%s  focus: %s  |  ctrl+r run  tab focus  esc clear/back  ctrl+q quit", m.status, focusName)
	statusBar := lipgloss.NewStyle().Foreground(lipgloss.Color("2")).Render(status)
	return lipgloss.JoinVertical(lipgloss.Left, top, statusBar)
}

// splitArgs 按空白分词，MVP 不处理引号包裹的空格。
func splitArgs(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	return strings.Fields(s)
}
```

- [ ] **Step 2: 编译验证**

Run: `cd tui && go build ./internal/ui/...`
Expected: 成功。

- [ ] **Step 3: 手测主屏（需真实 PG/Redis，或用本地实例）**

准备一个本地 config.toml 指向可用的 PG 或 Redis，运行 Task 10 的 main 后：
- 选中连接 → 进入主屏 → browser 加载 schemas/keys
- 选中表/键 → editor 插入模板
- `Ctrl+R` 执行 → results 显示
- `Tab` 切焦点
- `Ctrl+Q` 返回连接屏

---

### Task 10: 入口 main.go + 构建 + 冒烟

**Files:**
- Create: `tui/main.go`
- Create: `tui/README.md`

**Interfaces:**
- Consumes: `config.Load`、`ui.NewApp`（from Task 1, 5）

- [ ] **Step 1: 实现 main.go**

Create `tui/main.go`:

```go
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	tea "github.com/charmbracelet/bubbletea"

	"heidisql-tui/internal/config"
	"heidisql-tui/internal/ui"
)

func main() {
	var cfgPath string
	flag.StringVar(&cfgPath, "config", defaultConfigPath(), "config file path")
	flag.Parse()

	cfg, err := config.Load(cfgPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config load error: %v\n", err)
		os.Exit(1)
	}

	p := tea.NewProgram(ui.NewApp(cfg, cfgPath), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func defaultConfigPath() string {
	if env := os.Getenv("HEIDISQL_TUI_CONFIG"); env != "" {
		return env
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "config.toml"
	}
	return filepath.Join(home, ".config", "heidisql-tui", "config.toml")
}
```

- [ ] **Step 2: 整体编译**

Run: `cd tui && go build ./...`
Expected: 成功。

- [ ] **Step 3: 静态二进制构建**

Run:
```bash
cd tui && CGO_ENABLED=0 go build -o ../out/heidisql-tui .
ls -la ../out/heidisql-tui
```
Expected: 生成 `out/heidisql-tui` 单文件。

- [ ] **Step 4: 冒烟运行**

Run: `cd /data/projects_local/pascal/HeidiSQL && ./out/heidisql-tui --config tui/config.example.toml`
Expected: 进入连接屏，显示 pg-prod / redis-cache 两项（连接会失败因是示例地址，属正常）。
退出：`Ctrl+Q`。

- [ ] **Step 5: 写 README**

Create `tui/README.md`:

```markdown
# heidisql-tui

精简终端工具，在服务器上查询 PostgreSQL 与执行 Redis 命令。基于 [bubbletea](https://github.com/charmbracelet/bubbletea)。

> 独立 Go 项目，复用 HeidiSQL 概念但不共享代码。仅覆盖 PostgreSQL + Redis 子集。
> 本目录在父仓库 `.gitignore` 中，不提交。

## 安装

    cd tui && CGO_ENABLED=0 go build -o ../out/heidisql-tui .

单静态二进制，scp 到服务器即用。

## 配置

默认 `~/.config/heidisql-tui/config.toml`（可用 `--config <path>` 覆盖）。
示例见 `config.example.toml`。密码明文存储，请 `chmod 600` 配置文件。

## 快捷键

- 连接屏：`↑↓` 移动  `Enter` 连接  `n` 新增  `d` 删除  `Ctrl+Q` 退出
- 主屏：`Tab/Shift+Tab` 切焦点  `Ctrl+R` 执行  `Esc` 清空/返回  `Ctrl+Q` 退出
- Browser：`Enter` 展开 schema / 选中表/键插入模板；Redis 下 `r` 刷新扫描

## 测试

    go test ./internal/config/                       # 纯逻辑单测
    go test -tags=integration ./internal/db/         # 集成测试（需 Docker）
```

- [ ] **Step 6: 最终验证**

Run:
```bash
cd tui && go vet ./...
cd tui && go test ./internal/config/
```
Expected: 全部通过。

---

## Self-Review Notes

- Spec §1-10 全覆盖：config(§3)→Task1；db接口+pg+redis(§4)→Task2-4；连接屏(§5)→Task5；主屏browser/editor/results(§6)→Task6-9；错误处理(§7)→各任务错误路径；测试(§8)→config单测+db集成测试；构建(§9)→Task10。
- 消息类型 `errMsg`/`connectedMsg`/`execResultMsg`/`InsertTemplateMsg`/`schemasLoadedMsg` 等命名一致，跨任务引用无冲突。
- `db.Open` 返回 `Connection`，app.go 用类型断言 `conn.(SQLConn)` / `conn.(KVConn)` 取具体接口（screen_main.go newMainModel 中实现），与设计文档 §4 一致。
- `tui/` 全程不提交 git；仅 `docs/superpowers/plans/` 与 `specs/` 文档提交（Task1 Step 8）。
- 主屏桩（Task 5）→ 完整实现（Task 9）的替换路径已明确，中间状态可编译。
