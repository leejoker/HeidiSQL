# DBeaver 连接导入 config.toml — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增 CLI 子命令 `heidisql-tui import-dbeaver`，从 DBeaver workspace 读取连接元数据 + 解密 AES-128-CBC 凭据，映射为 heidisql-tui 的 `Connection`，按名合并写入 `config.toml`。

**Architecture:** 三层分离。新包 `internal/dbeaver`（纯逻辑，仅 Go 标准库）负责 workspace 探测、JSON 解析、AES 解密、字段映射，可独立单测。`internal/config` 新增 `Upsert` 方法。`main` 包新增 `import_dbeaver.go` 编排 CLI flag + 合并 + 输出，`main.go` 加 `os.Args` 守卫分派子命令。现有 TUI 路径零改动。

**Tech Stack:** Go 1.27、Go 标准库（`crypto/aes`+`crypto/cipher`+`encoding/json`+`encoding/base64`+`runtime`）、已有 `github.com/BurntSushi/toml`。无新增第三方依赖。

## Global Constraints

- 模块 `heidisql-tui`，Go 1.27.1，工作目录 `tui/`（已加入 `.gitignore`，但 `docs/` 提交）。
- `internal/dbeaver` 包**仅依赖 Go 标准库**，禁止 import bubbletea/toml/config。
- 密码明文写入 `config.toml`（与现状一致，README 已标注 `chmod 600`），不引入新的明文落盘点。
- DBeaver AES 密钥为公开硬编码常量 hex `babb4a9f774ab853c96c2d653dfe544a`（16 字节），来源于 DBeaver 源码 `BaseProjectImpl.LOCAL_KEY_CACHE`。
- 测试为纯逻辑单测（无 Docker、无 `//go:build integration`），与 `internal/config` 现有惯例一致。
- commit message 用英文（遵循 AGENTS.md §15）；代码与文档默认中文注释。
- 现有 TUI 启动路径（`tea.NewProgram`）不得改动行为。
- `tui/` 有独立 git 仓库（父仓库 `.gitignore` 已忽略 `/tui/`）。在 `feature/dbeaver-import` 分支上开发，每个 task 完成后 commit。提交不影响父仓库。

## File Structure

`internal/dbeaver` 按职责拆分为 3 个文件（新包无既定模式，聚焦小文件优于单一大文件）：

| 文件 | 职责 | 创建/修改 |
|---|---|---|
| `tui/internal/dbeaver/decrypt.go` | AES 解密 + PKCS7 + `Credentials` 类型 + `LoadCredentials`（含 3 种格式回退） | 创建 |
| `tui/internal/dbeaver/decrypt_test.go` | 解密往返 + 格式回退单测 + 测试内加密 helper | 创建 |
| `tui/internal/dbeaver/mapping.go` | `DataSource`/`ImportedConn`/`SkippedConn`/`Result` 类型 + `detectDriver` + `parseJDBCURL` + `mapConn` | 创建 |
| `tui/internal/dbeaver/mapping_test.go` | 驱动检测 + JDBC 解析 + 字段映射单测 | 创建 |
| `tui/internal/dbeaver/dbeaver.go` | `FindWorkspace` + `LoadDataSources` + `Import` 编排 | 创建 |
| `tui/internal/dbeaver/dbeaver_test.go` | workspace 探测 + data-sources 解析 + Import 端到端单测 | 创建 |
| `tui/internal/config/config.go` | 新增 `Upsert` 方法 | 修改 |
| `tui/internal/config/config_test.go` | 新增 `TestUpsert` | 修改 |
| `tui/import_dbeaver.go` | `runImportDBeaver`：flag 解析 + 编排 + 输出 + 退出码 | 创建 |
| `tui/import_dbeaver_test.go` | 子命令端到端单测（临时 workspace + config） | 创建 |
| `tui/main.go` | `main()` 开头加 `os.Args[1]=="import-dbeaver"` 守卫 | 修改 |

---

## Task 1: config.Upsert — 按名覆盖或追加

**Files:**
- Modify: `tui/internal/config/config.go`（在 `Remove` 方法后追加 `Upsert`）
- Modify: `tui/internal/config/config_test.go`（追加 `TestUpsert`）

**Interfaces:**
- Consumes: 现有 `normalize(Connection) Connection`（同包内）
- Produces: `func (c *Config) Upsert(conn Connection)` — 后续 Task 5 编排合并时调用

- [ ] **Step 1: 写失败测试**

追加到 `tui/internal/config/config_test.go` 末尾：

```go
func TestUpsert(t *testing.T) {
	c := &Config{}
	c.Upsert(Connection{Name: "a", Driver: "redis", Host: "h", Port: 6379})
	c.Upsert(Connection{Name: "b", Driver: "postgres", Host: "h"})
	if len(c.Connections) != 2 {
		t.Fatalf("expected 2, got %d", len(c.Connections))
	}
	// 覆盖同名
	c.Upsert(Connection{Name: "a", Driver: "redis", Host: "h2", Port: 6380})
	if len(c.Connections) != 2 {
		t.Fatalf("expected 2 after overwrite, got %d", len(c.Connections))
	}
	find := func(name string) *Connection {
		for i := range c.Connections {
			if c.Connections[i].Name == name {
				return &c.Connections[i]
			}
		}
		return nil
	}
	a := find("a")
	if a == nil || a.Host != "h2" || a.Port != 6380 {
		t.Fatalf("overwrite failed: %+v", a)
	}
	// normalize 生效：b 未给 port/sslmode → 5432 / prefer
	b := find("b")
	if b == nil || b.Port != 5432 || b.SSLMode != "prefer" {
		t.Fatalf("normalize failed: %+v", b)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd tui && go test ./internal/config/ -run TestUpsert -v`
Expected: FAIL，编译错误 `c.Upsert undefined`

- [ ] **Step 3: 实现 Upsert**

在 `tui/internal/config/config.go` 的 `Remove` 方法后追加：

```go
// Upsert 按 Name 覆盖同名连接，无同名则追加。调用 normalize 补默认值。
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

- [ ] **Step 4: 跑测试确认通过**

Run: `cd tui && go test ./internal/config/ -v`
Expected: PASS（含原有 3 个测试 + 新 TestUpsert）

- [ ] **Step 5: Commit**

Run: `cd tui && go test ./internal/config/ -v && go build ./...`（确认 PASS）
```bash
cd tui && git add internal/config/config.go internal/config/config_test.go
git commit -m "feat(config): add Upsert method for name-based merge"
```

---

## Task 2: dbeaver 解密层 — AES-128-CBC + 凭据加载

**Files:**
- Create: `tui/internal/dbeaver/decrypt.go`
- Create: `tui/internal/dbeaver/decrypt_test.go`

**Interfaces:**
- Consumes: 无（纯 stdlib）
- Produces:
  - `type Credentials struct { User, Password string }`
  - `func LoadCredentials(ws string) (map[string]Credentials, error)` — Task 4 的 `Import` 调用

- [ ] **Step 1: 写失败测试**

创建 `tui/internal/dbeaver/decrypt_test.go`：

```go
package dbeaver

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// encryptCreds 用已知密钥+随机 IV 加密一段凭据 JSON，返回 iv+密文（模拟 DBeaver credentials-config.json）。
func encryptCreds(t *testing.T, raw map[string]any) []byte {
	t.Helper()
	block, err := aes.NewCipher(localKey)
	if err != nil {
		t.Fatal(err)
	}
	plain, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	bs := block.BlockSize()
	pad := bs - len(plain)%bs
	padded := append(plain, bytes.Repeat([]byte{byte(pad)}, pad)...)
	iv := make([]byte, bs)
	if _, err := rand.Read(iv); err != nil {
		t.Fatal(err)
	}
	mode := cipher.NewCBCEncrypter(block, iv)
	ct := make([]byte, len(padded))
	mode.CryptBlocks(ct, padded)
	return append(iv, ct...)
}

func TestDecryptRoundTrip(t *testing.T) {
	raw := map[string]any{
		"pg-abc": map[string]any{
			"#connection": map[string]any{"user": "readonly", "password": "s3cret"},
		},
	}
	creds, err := decryptCredentials(encryptCreds(t, raw))
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if creds["pg-abc"].User != "readonly" || creds["pg-abc"].Password != "s3cret" {
		t.Fatalf("unexpected: %+v", creds)
	}
}

func TestLoadCredentialsEncrypted(t *testing.T) {
	dir := t.TempDir()
	raw := map[string]any{
		"pg-abc": map[string]any{
			"#connection": map[string]any{"user": "readonly", "password": "s3cret"},
		},
	}
	if err := os.WriteFile(filepath.Join(dir, "credentials-config.json"), encryptCreds(t, raw), 0o600); err != nil {
		t.Fatal(err)
	}
	creds, err := LoadCredentials(dir)
	if err != nil {
		t.Fatal(err)
	}
	if creds["pg-abc"].Password != "s3cret" {
		t.Fatalf("unexpected: %+v", creds)
	}
}

func TestLoadCredentialsPlainJSON(t *testing.T) {
	dir := t.TempDir()
	raw := `{"pg-abc":{"#connection":{"user":"u","password":"p"}}}`
	if err := os.WriteFile(filepath.Join(dir, "credentials-config.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	creds, err := LoadCredentials(dir)
	if err != nil {
		t.Fatal(err)
	}
	if creds["pg-abc"].User != "u" || creds["pg-abc"].Password != "p" {
		t.Fatalf("unexpected: %+v", creds)
	}
}

func TestLoadCredentialsBase64(t *testing.T) {
	dir := t.TempDir()
	raw := `{"pg-abc":{"#connection":{"user":"u","password":"p"}}}`
	b64 := base64.StdEncoding.EncodeToString([]byte(raw))
	if err := os.WriteFile(filepath.Join(dir, "credentials-config.json"), []byte(b64), 0o600); err != nil {
		t.Fatal(err)
	}
	creds, err := LoadCredentials(dir)
	if err != nil {
		t.Fatal(err)
	}
	if creds["pg-abc"].User != "u" {
		t.Fatalf("unexpected: %+v", creds)
	}
}

func TestLoadCredentialsMissing(t *testing.T) {
	creds, err := LoadCredentials(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(creds) != 0 {
		t.Fatalf("expected empty, got %d", len(creds))
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd tui && go test ./internal/dbeaver/ -v`
Expected: FAIL，编译错误（包不存在 / `decryptCredentials` / `LoadCredentials` / `localKey` 未定义）

- [ ] **Step 3: 实现 decrypt.go**

创建 `tui/internal/dbeaver/decrypt.go`：

```go
package dbeaver

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
)

// localKey 是 DBeaver 源码 BaseProjectImpl.LOCAL_KEY_CACHE 中的公开硬编码 AES 密钥。
// 来源：org.jkiss.dbeaver.model.impl.app.BaseProjectImpl（hex babb4a9f774ab853c96c2d653dfe544a）。
var localKey = []byte{
	0xba, 0xbb, 0x4a, 0x9f, 0x77, 0x4a, 0xb8, 0x53,
	0xc9, 0x6c, 0x2d, 0x65, 0x3d, 0xfe, 0x54, 0x4a,
}

// Credentials — credentials-config.json 中单条凭据解密后的结构。
type Credentials struct {
	User     string
	Password string
}

var errInvalidPadding = errors.New("dbeaver: invalid PKCS7 padding")

// pkcs7Unpad 去除 PKCS7 填充。
func pkcs7Unpad(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, errInvalidPadding
	}
	n := int(data[len(data)-1])
	if n < 1 || n > 16 || n > len(data) {
		return nil, errInvalidPadding
	}
	for i := len(data) - n; i < len(data); i++ {
		if int(data[i]) != n {
			return nil, errInvalidPadding
		}
	}
	return data[:len(data)-n], nil
}

// parseCredentialsJSON 把解密后的 JSON 解析为 map[connId]Credentials。
// 结构：{ connId: { "#connection": { "user": "...", "password": "..." } } }
func parseCredentialsJSON(data []byte) (map[string]Credentials, error) {
	var raw map[string]struct {
		Connection struct {
			User     string `json:"user"`
			Password string `json:"password"`
		} `json:"#connection"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return nil, err
	}
	result := make(map[string]Credentials, len(raw))
	for id, c := range raw {
		result[id] = Credentials{User: c.Connection.User, Password: c.Connection.Password}
	}
	return result, nil
}

// decryptCredentials 解密整文件 AES-128-CBC（前 16 字节 IV，其余密文）。
func decryptCredentials(data []byte) (map[string]Credentials, error) {
	if len(data) < 16 {
		return nil, errors.New("dbeaver: credentials file too short")
	}
	iv := data[:16]
	ciphertext := data[16:]
	block, err := aes.NewCipher(localKey)
	if err != nil {
		return nil, err
	}
	if len(ciphertext) == 0 || len(ciphertext)%block.BlockSize() != 0 {
		return nil, errors.New("dbeaver: ciphertext not block-aligned")
	}
	mode := cipher.NewCBCDecrypter(block, iv)
	plain := make([]byte, len(ciphertext))
	mode.CryptBlocks(plain, ciphertext)
	plain, err = pkcs7Unpad(plain)
	if err != nil {
		return nil, err
	}
	return parseCredentialsJSON(plain)
}

// LoadCredentials 读取并解密 <ws>/credentials-config.json。
// 按顺序尝试：整文件 AES-CBC → 纯 JSON → base64+JSON。全部失败返回空 map + nil（不阻断导入）。
func LoadCredentials(ws string) (map[string]Credentials, error) {
	p := filepath.Join(ws, "credentials-config.json")
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]Credentials{}, nil
		}
		return nil, err
	}
	if creds, err := decryptCredentials(data); err == nil {
		return creds, nil
	}
	if creds, err := parseCredentialsJSON(data); err == nil {
		return creds, nil
	}
	if decoded, err := base64.StdEncoding.DecodeString(string(data)); err == nil {
		if creds, err := parseCredentialsJSON(decoded); err == nil {
			return creds, nil
		}
	}
	return map[string]Credentials{}, nil
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd tui && go test ./internal/dbeaver/ -v`
Expected: PASS（5 个测试全过）

- [ ] **Step 5: Commit**

Run: `cd tui && go test ./internal/dbeaver/ -v && go build ./...`（确认 PASS）
```bash
cd tui && git add internal/dbeaver/decrypt.go internal/dbeaver/decrypt_test.go
git commit -m "feat(dbeaver): add AES-128-CBC credential decryption with format fallbacks"
```

---

## Task 3: dbeaver 映射层 — 驱动检测 + 字段映射

**Files:**
- Create: `tui/internal/dbeaver/mapping.go`
- Create: `tui/internal/dbeaver/mapping_test.go`

**Interfaces:**
- Consumes: `Credentials`（Task 2 定义，同包）
- Produces:
  - `type DataSource struct { Provider, Driver, Name string; Configuration map[string]any }`
  - `type ImportedConn struct { Name, Driver, Host string; Port int; User, Password, Database string; DB int; SSLMode string }`
  - `type SkippedConn struct { Name, Provider, Driver, Reason string }`
  - `type Result struct { Imported []ImportedConn; Skipped []SkippedConn }`
  - `func detectDriver(provider, driver string) (string, bool)`
  - `func mapConn(ds DataSource, cr Credentials) ImportedConn`
  - Task 4 的 `Import` 调用上述

- [ ] **Step 1: 写失败测试**

创建 `tui/internal/dbeaver/mapping_test.go`：

```go
package dbeaver

import (
	"testing"
)

func TestDetectDriver(t *testing.T) {
	cases := []struct {
		provider, driver, want string
		ok                      bool
	}{
		{"postgresql", "postgres-jdbc", "postgres", true},
		{"pg", "postgres", "postgres", true},
		{"generic", "redis-ce", "redis", true},
		{"redis", "redis", "redis", true},
		{"mysql", "mysql8", "", false},
		{"", "", "", false},
	}
	for _, c := range cases {
		got, ok := detectDriver(c.provider, c.driver)
		if got != c.want || ok != c.ok {
			t.Errorf("detectDriver(%q,%q) = %q,%v; want %q,%v", c.provider, c.driver, got, ok, c.want, c.ok)
		}
	}
}

func TestParseJDBCURL(t *testing.T) {
	host, port, db := parseJDBCURL("jdbc:postgresql://10.0.0.5:5432/appdb?sslmode=require")
	if host != "10.0.0.5" || port != 5432 || db != "appdb" {
		t.Fatalf("got %s %d %s", host, port, db)
	}
	// 无端口
	host, port, db = parseJDBCURL("jdbc:postgresql://h/db")
	if host != "h" || port != 0 || db != "db" {
		t.Fatalf("got %s %d %s", host, port, db)
	}
	// 无 database
	host, port, db = parseJDBCURL("jdbc:postgresql://h:5432")
	if host != "h" || port != 5432 || db != "" {
		t.Fatalf("got %s %d %s", host, port, db)
	}
}

func TestMapConnPostgres(t *testing.T) {
	ds := DataSource{
		Provider: "postgresql",
		Driver:   "postgres-jdbc",
		Name:     "pg-prod",
		Configuration: map[string]any{
			"host":       "10.0.0.5",
			"port":       "5432",
			"database":   "appdb",
			"properties": map[string]any{"sslmode": "require"},
		},
	}
	c := mapConn(ds, Credentials{User: "readonly", Password: "s3cret"})
	if c.Driver != "postgres" || c.Host != "10.0.0.5" || c.Port != 5432 ||
		c.User != "readonly" || c.Password != "s3cret" || c.Database != "appdb" ||
		c.SSLMode != "require" {
		t.Fatalf("unexpected: %+v", c)
	}
}

func TestMapConnPostgresNoSSLMode(t *testing.T) {
	ds := DataSource{
		Provider: "postgresql",
		Driver:   "postgres-jdbc",
		Name:     "pg",
		Configuration: map[string]any{"host": "h", "port": "5432", "database": "d"},
	}
	c := mapConn(ds, Credentials{Password: "p"})
	// SSLMode 留空，交给 config.normalize 补 prefer
	if c.SSLMode != "" {
		t.Fatalf("expected empty sslmode, got %q", c.SSLMode)
	}
}

func TestMapConnRedis(t *testing.T) {
	ds := DataSource{
		Provider: "generic",
		Driver:   "redis-ce",
		Name:     "redis-cache",
		Configuration: map[string]any{
			"host":     "10.0.0.6",
			"port":     "6379",
			"database": "2",
		},
	}
	c := mapConn(ds, Credentials{Password: "pw"})
	if c.Driver != "redis" || c.Host != "10.0.0.6" || c.Port != 6379 ||
		c.DB != 2 || c.Password != "pw" || c.Database != "" {
		t.Fatalf("unexpected: %+v", c)
	}
}

func TestMapConnJDBCFallback(t *testing.T) {
	ds := DataSource{
		Provider:      "postgresql",
		Driver:        "postgres-jdbc",
		Name:          "pg-url",
		Configuration: map[string]any{"url": "jdbc:postgresql://h:5432/db"},
	}
	c := mapConn(ds, Credentials{})
	if c.Host != "h" || c.Port != 5432 || c.Database != "db" {
		t.Fatalf("jdbc fallback failed: %+v", c)
	}
}

func TestMapConnUserFallback(t *testing.T) {
	ds := DataSource{
		Provider: "postgresql",
		Driver:   "postgres-jdbc",
		Name:     "pg",
		Configuration: map[string]any{
			"host": "h", "port": "5432", "user": "cfguser",
		},
	}
	// credentials 无 user → 回退 configuration.user
	c := mapConn(ds, Credentials{Password: "p"})
	if c.User != "cfguser" {
		t.Fatalf("user fallback failed: %+v", c)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd tui && go test ./internal/dbeaver/ -v`
Expected: FAIL，编译错误（`DataSource`/`mapConn`/`detectDriver`/`parseJDBCURL` 未定义）

- [ ] **Step 3: 实现 mapping.go**

创建 `tui/internal/dbeaver/mapping.go`：

```go
package dbeaver

import (
	"fmt"
	"strings"
)

// DataSource — data-sources.json 中单条连接的解析结构（只取关心的字段）。
type DataSource struct {
	Provider      string
	Driver        string
	Name          string
	Configuration map[string]any
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

// detectDriver 按 provider+driver 子串判断是否为 heidisql-tui 支持的驱动。
func detectDriver(provider, driver string) (string, bool) {
	s := strings.ToLower(provider + " " + driver)
	switch {
	case strings.Contains(s, "postgres"):
		return "postgres", true
	case strings.Contains(s, "redis"):
		return "redis", true
	default:
		return "", false
	}
}

// parseJDBCURL 从 jdbc:postgresql://host:port/db 形式的 URL 解析 host/port/database。
func parseJDBCURL(url string) (host string, port int, database string) {
	s := strings.TrimPrefix(url, "jdbc:")
	idx := strings.Index(s, "://")
	if idx < 0 {
		return "", 0, ""
	}
	rest := s[idx+3:]
	if q := strings.Index(rest, "?"); q >= 0 {
		rest = rest[:q]
	}
	var authority string
	if slash := strings.Index(rest, "/"); slash >= 0 {
		authority = rest[:slash]
		database = rest[slash+1:]
	} else {
		authority = rest
	}
	if colon := strings.LastIndex(authority, ":"); colon >= 0 {
		host = authority[:colon]
		fmt.Sscanf(authority[colon+1:], "%d", &port)
	} else {
		host = authority
	}
	return host, port, database
}

// mapConn 把 DBeaver DataSource + Credentials 映射到 ImportedConn。
// port/sslmode 为空时不补默认值，留给 config.normalize。
func mapConn(ds DataSource, cr Credentials) ImportedConn {
	cfg := ds.Configuration
	get := func(key string) string {
		if v, ok := cfg[key]; ok {
			return fmt.Sprint(v)
		}
		return ""
	}
	drv, _ := detectDriver(ds.Provider, ds.Driver)

	host := get("host")
	port := 0
	if p := get("port"); p != "" {
		fmt.Sscanf(p, "%d", &port)
	}
	user := cr.User
	if user == "" {
		user = get("user")
	}
	database := get("database")

	// host 为空时从 JDBC url 回退
	if host == "" {
		if url := get("url"); url != "" {
			h, p, d := parseJDBCURL(url)
			host = h
			if port == 0 {
				port = p
			}
			if database == "" {
				database = d
			}
		}
	}

	c := ImportedConn{
		Name:     ds.Name,
		Driver:   drv,
		Host:     host,
		Port:     port,
		User:     user,
		Password: cr.Password,
	}
	if drv == "redis" {
		c.DB = 0
		if database != "" {
			fmt.Sscanf(database, "%d", &c.DB)
		}
	} else {
		c.Database = database
		if props, ok := cfg["properties"].(map[string]any); ok {
			if sm, ok := props["sslmode"].(string); ok {
				c.SSLMode = sm
			}
		}
	}
	return c
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd tui && go test ./internal/dbeaver/ -v`
Expected: PASS（Task 2 + Task 3 全部测试）

- [ ] **Step 5: Commit**

Run: `cd tui && go test ./internal/dbeaver/ -v && go build ./...`（确认 PASS）
```bash
cd tui && git add internal/dbeaver/mapping.go internal/dbeaver/mapping_test.go
git commit -m "feat(dbeaver): add driver detection and connection field mapping"
```

---

## Task 4: dbeaver 编排层 — workspace 探测 + data-sources 解析 + Import

**Files:**
- Create: `tui/internal/dbeaver/dbeaver.go`
- Create: `tui/internal/dbeaver/dbeaver_test.go`

**Interfaces:**
- Consumes: `LoadCredentials`（Task 2）、`detectDriver`/`mapConn`/`DataSource`/`Result`（Task 3）
- Produces:
  - `func FindWorkspace(explicit string) (string, error)`
  - `func LoadDataSources(ws string) (map[string]DataSource, error)`
  - `func Import(ws string) (*Result, error)` — Task 5 调用

- [ ] **Step 1: 写失败测试**

创建 `tui/internal/dbeaver/dbeaver_test.go`：

```go
package dbeaver

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadDataSourcesMissing(t *testing.T) {
	ds, err := LoadDataSources(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(ds) != 0 {
		t.Fatalf("expected empty, got %d", len(ds))
	}
}

func TestLoadDataSourcesParse(t *testing.T) {
	dir := t.TempDir()
	raw := `{"connections":{
		"pg-abc":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg","configuration":{"host":"h","port":"5432","database":"d"}},
		"redis-xyz":{"provider":"generic","driver":"redis-ce","name":"rc","configuration":{"host":"h","port":"6379","database":"0"}}
	}}`
	if err := os.WriteFile(filepath.Join(dir, "data-sources.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	ds, err := LoadDataSources(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(ds) != 2 || ds["pg-abc"].Name != "pg" || ds["redis-xyz"].Name != "rc" {
		t.Fatalf("unexpected: %+v", ds)
	}
}

func TestImportEndToEnd(t *testing.T) {
	dir := t.TempDir()
	raw := `{"connections":{
		"pg-abc":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg-prod","configuration":{"host":"10.0.0.5","port":"5432","database":"appdb"}},
		"redis-xyz":{"provider":"generic","driver":"redis-ce","name":"redis-cache","configuration":{"host":"10.0.0.6","port":"6379","database":"2"}},
		"mysql-1":{"provider":"mysql","driver":"mysql8","name":"my","configuration":{"host":"h","port":"3306"}}
	}}`
	if err := os.WriteFile(filepath.Join(dir, "data-sources.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	credRaw := map[string]any{
		"pg-abc":    map[string]any{"#connection": map[string]any{"user": "readonly", "password": "s3cret"}},
		"redis-xyz": map[string]any{"#connection": map[string]any{"user": "", "password": "rwpw"}},
	}
	if err := os.WriteFile(filepath.Join(dir, "credentials-config.json"), encryptCreds(t, credRaw), 0o600); err != nil {
		t.Fatal(err)
	}

	res, err := Import(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Imported) != 2 {
		t.Fatalf("expected 2 imported, got %d: %+v", len(res.Imported), res.Imported)
	}
	if len(res.Skipped) != 1 || res.Skipped[0].Name != "my" {
		t.Fatalf("expected mysql skipped, got %+v", res.Skipped)
	}
	var pg *ImportedConn
	for i := range res.Imported {
		if res.Imported[i].Name == "pg-prod" {
			pg = &res.Imported[i]
		}
	}
	if pg == nil || pg.Password != "s3cret" || pg.Database != "appdb" || pg.Port != 5432 {
		t.Fatalf("pg mapping wrong: %+v", pg)
	}
}

func TestImportNameFallbackToID(t *testing.T) {
	dir := t.TempDir()
	raw := `{"connections":{
		"pg-abc":{"provider":"postgresql","driver":"postgres-jdbc","configuration":{"host":"h","port":"5432","database":"d"}}
	}}`
	if err := os.WriteFile(filepath.Join(dir, "data-sources.json"), []byte(raw), 0o600); err != nil {
		t.Fatal(err)
	}
	res, err := Import(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Imported) != 1 || res.Imported[0].Name != "pg-abc" {
		t.Fatalf("name fallback to id failed: %+v", res.Imported)
	}
}

func TestFindWorkspaceExplicit(t *testing.T) {
	dir := t.TempDir()
	got, err := FindWorkspace(dir)
	if err != nil {
		t.Fatalf("explicit: %v", err)
	}
	if got != dir {
		t.Fatalf("got %s want %s", got, dir)
	}
}

func TestFindWorkspaceExplicitMissing(t *testing.T) {
	_, err := FindWorkspace("/nonexistent/path/xyz")
	if err == nil {
		t.Fatal("expected error for missing explicit path")
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd tui && go test ./internal/dbeaver/ -v`
Expected: FAIL，编译错误（`LoadDataSources`/`Import`/`FindWorkspace` 未定义）

- [ ] **Step 3: 实现 dbeaver.go**

创建 `tui/internal/dbeaver/dbeaver.go`：

```go
package dbeaver

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// FindWorkspace 返回 DBeaver .dbeaver 目录路径。
// explicit 非空则直接用（需存在）；否则按 OS 候选路径探测，首个存在者胜出。
func FindWorkspace(explicit string) (string, error) {
	if explicit != "" {
		if _, err := os.Stat(explicit); err != nil {
			return "", fmt.Errorf("dbeaver workspace not found: %s", explicit)
		}
		return explicit, nil
	}
	for _, p := range workspaceCandidates() {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	return "", fmt.Errorf("dbeaver workspace not found, tried:\n%s", strings.Join(workspaceCandidates(), "\n"))
}

func workspaceCandidates() []string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	var cands []string
	switch runtime.GOOS {
	case "darwin":
		cands = []string{
			filepath.Join(home, "Library", "DBeaverData", "workspace6", "General", ".dbeaver"),
			filepath.Join(home, "Library", "Application Support", "DBeaverData", "workspace6", "General", ".dbeaver"),
		}
	case "windows":
		appdata := os.Getenv("APPDATA")
		if appdata == "" {
			appdata = filepath.Join(home, "AppData", "Roaming")
		}
		cands = []string{
			filepath.Join(appdata, "DBeaverData", "workspace6", "General", ".dbeaver"),
		}
	default: // linux 等
		cands = []string{
			filepath.Join(home, ".local", "share", "DBeaverData", "workspace6", "General", ".dbeaver"),
			filepath.Join(home, "snap", "dbeaver-ce", "current", ".local", "share", "DBeaverData", "workspace6", "General", ".dbeaver"),
			filepath.Join(home, ".var", "app", "io.dbeaver.DBeaverCommunity", "data", "DBeaverData", "workspace6", "General", ".dbeaver"),
		}
	}
	return cands
}

// LoadDataSources 解析 <ws>/data-sources.json，返回 connections map（按 connId 索引）。
// 文件不存在返回空 map + nil。
func LoadDataSources(ws string) (map[string]DataSource, error) {
	p := filepath.Join(ws, "data-sources.json")
	data, err := os.ReadFile(p)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]DataSource{}, nil
		}
		return nil, err
	}
	var doc struct {
		Connections map[string]struct {
			Provider      string         `json:"provider"`
			Driver        string         `json:"driver"`
			Name          string         `json:"name"`
			Configuration map[string]any `json:"configuration"`
		} `json:"connections"`
	}
	if err := json.Unmarshal(data, &doc); err != nil {
		return nil, err
	}
	result := make(map[string]DataSource, len(doc.Connections))
	for id, c := range doc.Connections {
		result[id] = DataSource{
			Provider:      c.Provider,
			Driver:        c.Driver,
			Name:          c.Name,
			Configuration: c.Configuration,
		}
	}
	return result, nil
}

// Import 读取并映射整个 workspace，返回导入结果与跳过列表。不触碰 config.toml。
func Import(ws string) (*Result, error) {
	ds, err := LoadDataSources(ws)
	if err != nil {
		return nil, err
	}
	cr, _ := LoadCredentials(ws) // 错误已吞（返回空 map），不阻断导入
	res := &Result{}
	for id, d := range ds {
		if _, ok := detectDriver(d.Provider, d.Driver); !ok {
			res.Skipped = append(res.Skipped, SkippedConn{
				Name:     d.Name,
				Provider: d.Provider,
				Driver:   d.Driver,
				Reason:   "unsupported driver",
			})
			continue
		}
		conn := mapConn(d, cr[id])
		if conn.Name == "" {
			conn.Name = id
		}
		res.Imported = append(res.Imported, conn)
	}
	return res, nil
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd tui && go test ./internal/dbeaver/ -v`
Expected: PASS（Task 2+3+4 全部测试）

- [ ] **Step 5: Commit**

Run: `cd tui && go test ./internal/dbeaver/ -v && go build ./...`（确认 PASS）
```bash
cd tui && git add internal/dbeaver/dbeaver.go internal/dbeaver/dbeaver_test.go
git commit -m "feat(dbeaver): add workspace detection, data-sources parsing, Import orchestration"
```

---

## Task 5: CLI 子命令 — main.go 守卫 + import_dbeaver.go 编排

**Files:**
- Create: `tui/import_dbeaver.go`
- Create: `tui/import_dbeaver_test.go`
- Modify: `tui/main.go`（`main()` 开头加守卫）

**Interfaces:**
- Consumes: `config.Load`/`config.Save`/`config.Upsert`（Task 1）、`dbeaver.FindWorkspace`/`dbeaver.Import`（Task 4）、`defaultConfigPath()`（main.go 现有）
- Produces: `func runImportDBeaver(args []string) int` — main.go 守卫调用

- [ ] **Step 1: 写失败测试**

创建 `tui/import_dbeaver_test.go`：

```go
package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeTestWorkspace 在 dir 下构造一个最小 DBeaver workspace。
func writeTestWorkspace(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	ds := `{"connections":{
		"pg-1":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg-prod","configuration":{"host":"h","port":"5432","database":"d"}}
	}}`
	if err := os.WriteFile(filepath.Join(dir, "data-sources.json"), []byte(ds), 0o600); err != nil {
		t.Fatal(err)
	}
	cred := `{"pg-1":{"#connection":{"user":"u","password":"p"}}}`
	if err := os.WriteFile(filepath.Join(dir, "credentials-config.json"), []byte(cred), 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestRunImportDBeaver(t *testing.T) {
	dir := t.TempDir()
	ws := filepath.Join(dir, "ws")
	writeTestWorkspace(t, ws)
	cfgPath := filepath.Join(dir, "config.toml")

	code := runImportDBeaver([]string{"-workspace", ws, "-config", cfgPath})
	if code != 0 {
		t.Fatalf("exit code %d", code)
	}
	data, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `name = "pg-prod"`) {
		t.Fatalf("config not written / missing pg-prod: %s", data)
	}
	if !strings.Contains(string(data), `password = "p"`) {
		t.Fatalf("password not written: %s", data)
	}
}

func TestRunImportDBeaverDryRun(t *testing.T) {
	dir := t.TempDir()
	ws := filepath.Join(dir, "ws")
	writeTestWorkspace(t, ws)
	cfgPath := filepath.Join(dir, "config.toml")
	original := "# pre-existing\n"
	if err := os.WriteFile(cfgPath, []byte(original), 0o600); err != nil {
		t.Fatal(err)
	}

	code := runImportDBeaver([]string{"-workspace", ws, "-config", cfgPath, "-dry-run"})
	if code != 0 {
		t.Fatalf("exit code %d", code)
	}
	data, _ := os.ReadFile(cfgPath)
	if string(data) != original {
		t.Fatalf("dry-run modified config: %s", data)
	}
}

func TestRunImportDBeaverBadFlag(t *testing.T) {
	code := runImportDBeaver([]string{"-nope"})
	if code != 2 {
		t.Fatalf("expected exit 2 for bad flag, got %d", code)
	}
}

func TestRunImportDBeaverMissingWorkspace(t *testing.T) {
	code := runImportDBeaver([]string{"-workspace", "/nonexistent/xyz", "-config", filepath.Join(t.TempDir(), "c.toml")})
	if code != 1 {
		t.Fatalf("expected exit 1 for missing workspace, got %d", code)
	}
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd tui && go test ./ -run TestRunImportDBeaver -v`
Expected: FAIL，编译错误（`runImportDBeaver` 未定义）

- [ ] **Step 3: 实现 import_dbeaver.go**

创建 `tui/import_dbeaver.go`：

```go
package main

import (
	"flag"
	"fmt"
	"os"

	"heidisql-tui/internal/config"
	"heidisql-tui/internal/dbeaver"
)

// runImportDBeaver 执行 import-dbeaver 子命令，返回进程退出码。
func runImportDBeaver(args []string) int {
	fs := flag.NewFlagSet("import-dbeaver", flag.ContinueOnError)
	cfgPath := fs.String("config", defaultConfigPath(), "config file path")
	ws := fs.String("workspace", "", "DBeaver workspace .dbeaver dir (auto-detect if empty)")
	dryRun := fs.Bool("dry-run", false, "print what would be imported without writing")
	if err := fs.Parse(args); err != nil {
		return 2
	}

	workspace, err := dbeaver.FindWorkspace(*ws)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	result, err := dbeaver.Import(workspace)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	cfg, err := config.Load(*cfgPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}

	for _, ic := range result.Imported {
		cfg.Upsert(config.Connection{
			Name:     ic.Name,
			Driver:   ic.Driver,
			Host:     ic.Host,
			Port:     ic.Port,
			User:     ic.User,
			Password: ic.Password,
			Database: ic.Database,
			DB:       ic.DB,
			SSLMode:  ic.SSLMode,
		})
	}

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
	if err := cfg.Save(*cfgPath); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Printf("Written to %s\n", *cfgPath)
	return 0
}
```

- [ ] **Step 4: 加 main.go 守卫**

修改 `tui/main.go`，在 `func main() {` 之后、`var cfgPath string` 之前插入守卫。

原文（第 15-18 行）：
```go
func main() {
	var cfgPath string
	flag.StringVar(&cfgPath, "config", defaultConfigPath(), "config file path")
	flag.Parse()
```

改为：
```go
func main() {
	if len(os.Args) > 1 && os.Args[1] == "import-dbeaver" {
		os.Exit(runImportDBeaver(os.Args[2:]))
	}
	var cfgPath string
	flag.StringVar(&cfgPath, "config", defaultConfigPath(), "config file path")
	flag.Parse()
```

（`os` 已在 main.go 的 import 中，无需新增。）

- [ ] **Step 5: 跑测试确认通过**

Run: `cd tui && go test ./ -run TestRunImportDBeaver -v`
Expected: PASS（4 个子命令测试全过）

- [ ] **Step 6: 跑全量测试 + 构建**

Run: `cd tui && go test ./... && go build ./...`
Expected: 全部 PASS，构建无错误

- [ ] **Step 7: Commit**

Run: `cd tui && go test ./... && go build ./...`（确认 PASS）
```bash
cd tui && git add import_dbeaver.go import_dbeaver_test.go main.go
git commit -m "feat(cli): add import-dbeaver subcommand for DBeaver connection import"
```

---

## 完成验证

全部任务完成后，手动冒烟测试（可选，需真实 DBeaver workspace）：

```bash
cd tui && go build -o /tmp/heidisql-tui .
/tmp/heidisql-tui import-dbeaver --dry-run
/tmp/heidisql-tui import-dbeaver
```

预期输出含 `Imported: N`、各连接 `+ name driver host:port`，`config.toml` 出现导入的连接条目。
