# Editor 字段自动补全 — 设计文档

**日期**：2026-09-23
**状态**：已通过头脑风暴评审，待实现计划
**模块路径**：`tui/`（已加入 `.gitignore`，不提交）

---

## 1. 背景与目标

主屏 editor 区域目前是纯文本输入，用户需要手动记住表名、列名。本设计为 editor 增加自动
补全：输入标识符时实时弹出候选列表，↑↓ 选择，Tab 插入，减少打字和拼写错误。

### 关键决策（头脑风暴结论）

| 维度 | 决策 |
|---|---|
| 补全范围 | PG：schema 名 + 表名 + 列名；Redis：命令名（约 20 个常用） |
| 触发方式 | 输入时自动弹出（检测标识符前缀，实时过滤候选） |
| 列数据来源 | 进入主屏后异步预加载所有表列，内存缓存，零延迟补全 |
| 候选显示 | 仅候选名列表（不带类型摘要） |
| Redis key 补全 | 不做（key 太多太长，补全列表无意义） |

### 非目标（YAGNI）

- SQL 关键字补全（SELECT/FROM/WHERE 等）
- SQL 函数名补全
- 语境感知（如 `FROM` 后只补表名、`.` 后只补列名）
- Redis key 名补全
- 补全候选的类型/注释提示
- 多行补全文档弹窗

---

## 2. 数据层

### 2.1 SQLConn 接口新增方法

`internal/db/db.go` 的 `SQLConn` 接口加：

```go
ListColumns(ctx context.Context, schema, table string) ([]ColumnInfo, error)
```

新类型 `ColumnInfo`：

```go
type ColumnInfo struct {
    Name     string
    TypeName string // 如 int4, varchar, text
}
```

### 2.2 PostgreSQL 实现

`internal/db/postgres.go` 加 `ListColumns`：

```sql
SELECT a.attname, format_type(a.atttypid, a.atttypmod)
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE a.attnum > 0 AND NOT a.attisdropped
  AND n.nspname = $1 AND c.relname = $2
ORDER BY a.attnum
```

### 2.3 预加载策略

进入主屏（`newMainModel` → `Init`）后，异步加载补全数据：
- PG：先 `ListSchemas` → 对每个 schema `ListTables` → 对每张表 `ListColumns`，汇总为扁平
  候选列表（去重）：`[]string`，含所有 schema 名、表名、列名。
- Redis：静态命令列表，无需加载。

预加载完成后通过 `tea.Msg` 回到 `Update`，存入 `mainModel.completionWords []string`。
预加载失败不阻断——补全列表为空，editor 正常工作。

### 2.4 Redis 命令列表

硬编码约 20 个常用命令：

```
GET SET DEL EXISTS EXPIRE TTL TYPE
HSET HGET HGETALL HDEL
LPUSH RPUSH LRANGE LLEN
SADD SREM SMEMBERS SISMEMBER
ZADD ZRANGE ZSCORE
```

---

## 3. Editor 组件设计

全部改动在 `internal/ui/components/editor.go`，不新增文件。

### 3.1 新增字段

```go
type Editor struct {
    ta          textarea.Model
    focused     bool
    // 自动补全
    words       []string    // 候选词全集（由 mainModel 注入）
    compActive  bool        // 补全列表是否显示
    compItems   []string    // 当前过滤后的候选
    compCursor  int         // 选中项索引
    compPrefix  string      // 当前匹配前缀
}
```

### 3.2 候选注入

新增方法供 `mainModel` 调用：

```go
func (e *Editor) SetCompletionWords(words []string) {
    e.words = words
}
```

### 3.3 前缀提取

从 textarea 当前文本和光标位置提取正在输入的标识符前缀：

```go
// extractPrefix 提取光标前从上一个非标识符字符到光标的子串。
// 标识符字符：字母、数字、下划线。
func extractPrefix(text string, cursor int) string {
    start := cursor
    for start > 0 {
        c := text[start-1]
        if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' {
            start--
        } else {
            break
        }
    }
    return text[start:cursor]
}
```

### 3.4 补全触发与过滤

每次 editor 收到按键消息后（字符输入、删除等），重新提取前缀并过滤候选：

```go
func (e *Editor) refreshCompletion() {
    if len(e.words) == 0 {
        e.compActive = false
        return
    }
    text := e.ta.Value()
    cursor := e.ta.Index() // 光标字节偏移
    prefix := extractPrefix(text, cursor)
    if len(prefix) < 1 {
        e.compActive = false
        return
    }
    lower := strings.ToLower(prefix)
    var matched []string
    for _, w := range e.words {
        if strings.HasPrefix(strings.ToLower(w), lower) {
            matched = append(matched, w)
        }
    }
    if len(matched) == 0 {
        e.compActive = false
        return
    }
    e.compActive = true
    e.compItems = matched
    // 保留之前的 cursor 位置如果还在范围内，否则归零
    if e.compCursor >= len(matched) {
        e.compCursor = 0
    }
    e.compPrefix = prefix
}
```

### 3.5 按键拦截

`Update` 中，补全激活时拦截导航键：

```go
func (e *Editor) Update(msg tea.Msg) (*Editor, tea.Cmd) {
    if k, ok := msg.(tea.KeyMsg); ok && e.compActive {
        switch k.String() {
        case "down":
            e.compCursor = (e.compCursor + 1) % len(e.compItems)
            return e, nil
        case "up":
            e.compCursor = (e.compCursor - 1 + len(e.compItems)) % len(e.compItems)
            return e, nil
        case "tab":
            e.insertCompletion()
            return e, nil
        case "esc":
            e.compActive = false
            return e, nil
        }
    }
    // 正常按键交给 textarea
    var cmd tea.Cmd
    e.ta, cmd = e.ta.Update(msg)
    // 字符输入或删除后刷新补全
    e.refreshCompletion()
    return e, cmd
}
```

### 3.6 插入补全

```go
func (e *Editor) insertCompletion() {
    if !e.compActive || e.compCursor >= len(e.compItems) {
        return
    }
    chosen := e.compItems[e.compCursor]
    text := e.ta.Value()
    cursor := e.ta.Index()
    // 计算前缀起止
    prefixLen := len(e.compPrefix)
    newText := text[:cursor-prefixLen] + chosen + text[cursor:]
    e.ta.SetValue(newText)
    // 设置光标到插入内容末尾
    newCursor := cursor - prefixLen + len(chosen)
    e.ta.SetCursor(newCursor)
    e.compActive = false
}
```

### 3.7 View 渲染

补全列表渲染在 textarea 边框内底部，覆盖最后几行（不改变 textarea 自身布局）。
列表最多显示 5 项，高亮当前选中项：

```go
func (e *Editor) View(width, height int) string {
    e.ta.SetWidth(width - 4)
    e.ta.SetHeight(height - 4)
    content := fitHeight(e.ta.View(), height-2)

    // 补全列表覆盖层
    if e.compActive && len(e.compItems) > 0 {
        maxShow := 5
        if len(e.compItems) < maxShow {
            maxShow = len(e.compItems)
        }
        var lines []string
        for i := 0; i < maxShow; i++ {
            item := e.compItems[i]
            if i == e.compCursor {
                lines = append(lines, lipgloss.NewStyle().
                    Background(lipgloss.Color("6")).
                    Render(item))
            } else {
                lines = append(lines, lipgloss.NewStyle().
                    Foreground(lipgloss.Color("7")).
                    Render(item))
            }
        }
        compStr := strings.Join(lines, "\n")
        // 在 content 末尾追加补全列表
        content = content + "\n" + compStr
    }

    return BorderStyle().Width(width - 2).Height(height - 2).Render(content)
}
```

---

## 4. 主屏集成

### 4.1 mainModel 新增字段

```go
type mainModel struct {
    // ... 现有字段 ...
    completionWords []string // 预加载的补全候选
}
```

### 4.2 预加载命令

`Init()` 返回 `tea.Batch(m.browser.InitCmd(), m.loadCompletionsCmd())`。

```go
type completionLoadedMsg struct {
    words []string
    err   error
}

func (m *mainModel) loadCompletionsCmd() tea.Cmd {
    if m.driver == "redis" {
        // Redis 用静态命令列表
        return func() tea.Msg {
            return completionLoadedMsg{words: redisCommands}
        }
    }
    // PG：异步加载 schema → table → column
    return func() tea.Msg {
        // ... 遍历 schemas/tables/columns ...
        return completionLoadedMsg{words: words, err: err}
    }
}
```

### 4.3 Update 处理

```go
case completionLoadedMsg:
    if msg.err == nil {
        m.completionWords = msg.words
        m.editor.SetCompletionWords(msg.words)
    }
    return m, nil
```

### 4.4 预加载 SQL 实现细节

PG 预加载在一个 goroutine 内完成全部查询（串行）：

```go
func (m *mainModel) loadCompletionsCmd() tea.Cmd {
    ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    return func() tea.Msg {
        defer cancel()
        var words []string
        schemas, err := m.sqlc.ListSchemas(ctx)
        if err != nil {
            return completionLoadedMsg{err: err}
        }
        seen := map[string]bool{}
        for _, schema := range schemas {
            words = appendUnique(seen, words, schema)
            tables, err := m.sqlc.ListTables(ctx, schema)
            if err != nil {
                continue // 单 schema 失败不阻断
            }
            for _, t := range tables {
                words = appendUnique(seen, words, t.Name)
                cols, err := m.sqlc.ListColumns(ctx, schema, t.Name)
                if err != nil {
                    continue
                }
                for _, c := range cols {
                    words = appendUnique(seen, words, c.Name)
                }
            }
        }
        sort.Strings(words)
        return completionLoadedMsg{words: words}
    }
}
```

---

## 5. 错误处理

| 场景 | 处理 |
|---|---|
| 预加载失败 | 补全列表为空，editor 正常工作，无补全弹窗 |
| 部分表列查询失败 | 跳过该表，继续加载其他表 |
| 前缀无匹配 | 关闭补全列表 |
| 补全列表为空时不拦截按键 | 正常输入 |
| textarea 光标位置 API | 用 `ta.Index()` 获取字节偏移，`ta.SetCursor(pos)` 设置 |

---

## 6. 测试策略

### 6.1 纯逻辑单测（`editor_test.go`，新文件）

- `extractPrefix`：各种边界（空串、光标在中间、无标识符前缀、纯数字前缀）
- `refreshCompletion`：空 words、空前缀、有匹配、无匹配
- `insertCompletion`：插入后文本和光标位置正确

### 6.2 db 层单测

- `ListColumns` 在集成测试中验证（已有 testcontainers 环境）
- 可单独加 `//go:build integration` 测试

### 6.3 手测清单

1. 连接 PG → 输入 `pub` → 弹出 `public`（schema 名）→ Tab 插入
2. 输入 `use` → 弹出 `users`（表名）→ Tab 插入
3. 输入 `id` → 弹出 `id`（列名）→ Tab 插入
4. ↑↓ 切换候选，Tab 确认，Esc 关闭
5. 连接 Redis → 输入 `GE` → 弹出 `GET` → Tab 插入
6. 删除文本时补全列表实时更新

---

## 7. 交付边界

本设计完成后下一步为 **writing-plans** 阶段。实现范围：
- `db.go`：接口 + 类型
- `postgres.go`：`ListColumns` 实现
- `editor.go`：补全逻辑 + 渲染
- `screen_main.go`：预加载 + 集成

后续扩展（关键字补全、语境感知、函数补全）不在本次计划内。
