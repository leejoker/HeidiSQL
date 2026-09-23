# 定时轮询查询 — 设计文档

**日期**：2026-09-23
**状态**：已通过头脑风暴评审，待实现计划
**模块路径**：`tui/`（已加入 `.gitignore`，不提交）

---

## 1. 背景与目标

主屏 editor 区域有时需要持续监控某个查询的结果变化（如观察日志表、监控指标、Redis key
值）。目前只能反复手动按 F5。本设计新增一个定时轮询功能：用户在编辑器写好查询后，
按 `Ctrl+P` 启动轮询，TUI 按设定间隔自动反复执行编辑器当前文本，结果覆盖刷新到 results
区域。可随时手动启停、运行中调整间隔。

### 关键决策（头脑风暴结论）

| 维度 | 决策 |
|---|---|
| 触发方式 | 快捷键直接控制，无弹窗 |
| 轮询内容 | 编辑器当前文本（每轮取最新值，用户改了下一轮自动跟上） |
| 间隔调整 | 固定步长 ±1s，范围 1–60s，运行中可调 |
| 结果处理 | 覆盖刷新（与手动 F5 效果一致，复用现有 execResultMsg 流程） |
| 默认间隔 | 3 秒 |

### 非目标（YAGNI）

- 轮询历史记录（多轮结果对比、追加列表）
- 轮询结果差异高亮（只看最新一轮）
- 多查询并行轮询
- 轮询配置持久化（每次进主屏重新设）
- 轮询成功/失败计数统计

---

## 2. 交互设计

### 快捷键

| 键 | 动作 | 备注 |
|---|---|---|
| `Ctrl+P` | 启动/停止轮询（toggle） | 启动时以编辑器当前文本为查询；停止后不再执行 |
| `Ctrl+.` | 间隔 +1s | 范围 1–60s；运行中可调，立即生效 |
| `Ctrl+,` | 间隔 -1s | 范围 1–60s；运行中可调，立即生效 |

### 状态栏

轮询运行时，状态栏左侧（queryPart 前）追加黄色 `[轮询中 Ns]` 标记。停止后消失。
间隔调整时该标记实时更新（如 `[轮询中 5s]`）。

### 生命周期

- 进入主屏：`polling=false`，`pollInterval=3s`
- 启动轮询：取编辑器文本，开始定时执行
- 运行中：每轮到点 → 执行 `execCmd(editor.Text())` → 结果走现有 `execResultMsg` → 覆盖 results
- 运行中改间隔：停旧 ticker，用新间隔重启
- 停止轮询：`ticker.Stop()` + `cancel()`
- 退出主屏（Ctrl+Q）：如正在轮询，先清理 ticker 和 cancel

---

## 3. 实现设计

全部改动在 `tui/internal/ui/screen_main.go`，约 50 行新增代码。不新增文件。

### 3.1 mainModel 新增字段

```go
type mainModel struct {
    // ... 现有字段 ...
    polling      bool              // 是否正在轮询
    pollInterval time.Duration     // 当前间隔，默认 3s
    pollCancel   context.CancelFunc // 停止轮询时调用
}
```

`newMainModel` 中初始化：`pollInterval: 3 * time.Second`。

### 3.2 新 msg 类型

```go
type pollTickMsg struct{}
```

### 3.3 启停逻辑

```go
// startPoll 启动轮询，返回首个 tick cmd。
func (m *mainModel) startPoll() tea.Cmd {
    m.polling = true
    ctx, cancel := context.WithCancel(context.Background())
    m.pollCancel = cancel
    return tea.Tick(m.pollInterval, func(time.Time) tea.Msg {
        return pollTickMsg{}
    })
}

// stopPoll 停止轮询。
func (m *mainModel) stopPoll() {
    m.polling = false
    if m.pollCancel != nil {
        m.pollCancel()
        m.pollCancel = nil
    }
}
```

### 3.4 Update 中处理 pollTickMsg

```go
case pollTickMsg:
    if m.polling {
        // 执行当前编辑器文本，结果走现有 execResultMsg 流程
        return m, m.execCmd(m.editor.Text())
    }
    return m, nil
```

注意：`execCmd` 返回的 `tea.Cmd` 执行完产生 `execResultMsg`，`Update` 收到后正常处理
（覆盖 results）。但轮询需要"执行完后再安排下一轮 tick"——因此在 `execResultMsg` 处理
分支末尾，如果 `m.polling` 为 true，额外返回一个 `tea.Tick` cmd 安排下一轮。

```go
// 在 execResultMsg 处理末尾（现有 return m, nil 处）：
if m.polling {
    return m, tea.Tick(m.pollInterval, func(time.Time) tea.Msg {
        return pollTickMsg{}
    })
}
return m, nil
```

这样形成闭环：tick → exec → execResult → 下一个 tick。

### 3.5 间隔调整

```go
case "ctrl+.":
    m.pollInterval += time.Second
    if m.pollInterval > 60*time.Second {
        m.pollInterval = 60 * time.Second
    }
    return m, nil
case "ctrl+,":
    m.pollInterval -= time.Second
    if m.pollInterval < time.Second {
        m.pollInterval = time.Second
    }
    return m, nil
```

> **终端兼容性**：`Ctrl+,` 和 `Ctrl+.` 在多数终端中可靠识别（不同于 `Ctrl+[` 会映射
> 为 ESC）。Bubbletea 解析为 `"ctrl+,"` / `"ctrl+."` 字符串。
>
> 最终快捷键：
> - `Ctrl+.` — 间隔 +1s
> - `Ctrl+,` — 间隔 -1s

### 3.6 Ctrl+P toggle

```go
case "ctrl+p":
    if m.polling {
        m.stopPoll()
    } else {
        return m, m.startPoll()
    }
    return m, nil
```

### 3.7 退出清理

在 `Ctrl+Q` 分支（现有 `return newConnectModel(...)` 前）：

```go
case "ctrl+q":
    if m.polling {
        m.stopPoll()
    }
    _ = m.conn.Close()
    return newConnectModel(app.cfg, app.cfgPath), nil
```

### 3.8 状态栏 View

在 `View()` 中，`queryPart` 前插入轮询标记：

```go
var pollPart string
if m.polling {
    pollPart = lipgloss.NewStyle().Foreground(lipgloss.Color("3")).Render(
        fmt.Sprintf("[轮询中 %ds]", int(m.pollInterval.Seconds())))
}
```

拼接到 `queryPart` 前，间隔用 spacer 分隔。

---

## 4. 错误处理

| 场景 | 处理 |
|---|---|
| 轮询执行出错 | 走现有 `execResultMsg.err` 流程，results 显示红字错误，下一轮 tick 照常触发 |
| 编辑器为空时启动轮询 | 执行空文本 → SQL 层报错或返回空结果，不影响轮询循环 |
| 间隔调整到极值 | 钳位 1–60s |
| 退出时忘记停止 | Ctrl+Q 分支显式 stopPoll，防 ticker 泄漏 |

---

## 5. 测试策略

UI 层无现有单测（靠手测），本功能同理。核心逻辑（间隔钳位、toggle 状态）简单到无需单测。
验证靠手测清单：

1. 写一个 `SELECT`，`Ctrl+P` 启动 → results 每隔 3s 自动刷新
2. 运行中 `Ctrl+.` → 看到间隔变 4s，节奏变慢
3. 运行中 `Ctrl+,` → 间隔变回 3s
4. `Ctrl+P` 停止 → 不再自动执行，`[轮询中]` 标记消失
5. `Ctrl+Q` 退出 → 无 panic、无 goroutine 泄漏

---

## 6. 交付边界

本设计完成后下一步为 **writing-plans** 阶段。实现范围严格限定于上述 MVP：
`screen_main.go` 内约 50 行改动，无新文件、无新依赖。后续扩展（历史记录、差异高亮、
多查询并行）不在本次计划内。
