# Redis 编辑能力补充设计 — HeidiSQL (Lazarus/Free Pascal port)

- 日期: 2026-09-21
- 状态: 已批准（设计阶段），待实现
- 前置设计: `docs/superpowers/specs/2026-09-20-redis-support-design.md`（Redis 只读浏览，已完成）
- 适用代码库: `/data/projects_local/pascal/HeidiSQL`（HeidiSQL 的 Lazarus/FPC 移植版）

## 1. 背景与目标

### 1.1 现状

前序设计（2026-09-20）实现了 Redis 的**只读浏览**：连接（TCP/ACL/RESP2-3）、键树（SCAN + `:` 前缀分组）、各类型数据网格渲染（string/hash/list/set/zset，懒加载 + JSON 格式化 + 图片预览）、SQL 查询页执行 Redis 命令。

但**编辑能力完全缺失或损坏**：

1. **网格编辑完全禁用** — `TRedisQuery.IsEditable` 返回 False（`GetTableKeys` 返回空 → `CheckEditable` 失败 → `MSG_NOGRIDEDITING`）
2. **文本编辑器只读** — `FAllowEdit=False`（因 `IsEditable=False`）；即使开启，`SaveModifications` 生成 SQL UPDATE（对 Redis 无效）
3. **键删除（Drop）损坏** — `TDBConnection.Drop` 发送 `DROP TABLE \`key\`` 给 Redis（无效命令）
4. **无 TTL/EXPIRE/PERSIST/RENAME 操作** — 前序设计 §5.4 规划但未实现
5. **无新建键 UI** — 无法通过 UI 创建新键
6. **`tabEditor` 对 Redis 键可见** — 显示无意义的表编辑器（列/索引/外键）

### 1.2 本次目标

补充完善 Redis 编辑能力，覆盖：

- 修复键删除（Drop → `DEL`）
- 网格内编辑各类型值（string/hash/list/set/zset）
- 键级操作（DEL/RENAME/EXPIRE/PERSIST/查看 TTL/复制键名）
- 新建键 UI（右键菜单弹对话框）
- 数据网格信息栏（TYPE/SIZE/TTL/MEMORY USAGE）
- 隐藏 Redis 无关标签（`tabEditor`）

### 1.3 范围决策

用户在头脑风暴阶段确定：

- **编辑范围**: 全功能编辑（修复 Drop + 网格编辑 + 键操作 + 新建键）
- **值编辑模型**: 网格内编辑 + 文本编辑器（大值）
- **键操作入口**: 右键上下文菜单
- **TTL 展示**: 信息栏 + 右键设 TTL
- **标签清理**: Redis 时隐藏 `tabEditor` 等无关标签
- **新建键**: 右键菜单弹对话框

## 2. 架构与组件总览

### 2.1 修改的文件

| 文件 | 改动 |
|---|---|
| `dbconnection.pas` | ① `TDBQuery`：将 `CheckEditable`/`SaveModifications`/`DeleteRow`/`InsertRow`/`EnsureFullRow`/`GetKeyColumns` 改为 `virtual`（向后兼容，无现有子类重写它们）<br>② `TRedisConnection`：重写 `Drop`（发 `DEL` 而非 `DROP TABLE`）<br>③ `TRedisQuery`：重写上述编辑方法，映射到 Redis 命令 |
| `main.pas` | ① Redis 键右键菜单：删除/重命名/设TTL/取消TTL/查看TTL/复制键名/新建键<br>② `tabEditor` 对 Redis 隐藏<br>③ 数据网格上方加信息栏面板（TYPE/SIZE/TTL/MEMORY USAGE）<br>④ `AnyGridCreateEditor` 中对 Redis 键列不创建编辑器 |
| `redis_newkey.lfm` + `redis_newkey.pas` | 新建：`TfrmRedisNewKey : TExtForm` — 新建键对话框（键名+类型+初始值） |
| `const.inc` | 新增 `ICONINDEX_REDIS_*` 图标常量（如已有则复用） |

### 2.2 不新增的文件

- **不创建 `redis_console.pas`** — SQL 查询页已能执行 Redis 命令（空格分词），本次不加专用命令台
- **不创建 `redis_values.pas`** — 数据网格已能渲染各类型值，本次在其基础上加编辑能力

### 2.3 数据流

```
用户双击 hash value 单元格 → 网格 TInplaceEditorLink 弹文本编辑器
  → 用户改值 → 点 Apply → EndEdit → grid 文本更新
  → 网格触发保存 → DataGridResult.SaveModifications
  → TRedisQuery.SaveModifications (重写)
    → 识别 FKeyType='hash'，该行 value 列被修改
    → FConn.Client.Execute(['HSET', FKey, field, newValue])
    → 更新本地 FReply 数据 → 网格显示新值
```

## 3. `TRedisQuery` 编辑方法重写（核心）

### 3.1 `TDBQuery` 基类改动

将以下方法声明加 `virtual`（无现有子类重写它们，向后兼容）：

```pascal
procedure CheckEditable; virtual;
function GetKeyColumns: TTableColumnList; virtual;
function SaveModifications: Boolean; virtual;
procedure DeleteRow; virtual;
function InsertRow: Int64; virtual;
function EnsureFullRow(Refresh: Boolean): Boolean; virtual;
```

### 3.2 `TRedisConnection.Drop` 重写

```pascal
procedure TRedisConnection.Drop(Obj: TDBObject);
begin
  Query('DEL ' + Obj.Name);
end;
```

### 3.3 `TRedisQuery.CheckEditable` 重写

按 `FKeyType` 判断可编辑性：

- `string`：可编辑 value（单值），不可增删行
- `hash`/`list`/`set`/`zset`：可编辑、可增删行
- `none`/`stream`：不可编辑（抛 `MSG_NOGRIDEDITING`）

### 3.4 `TRedisQuery.GetKeyColumns` 重写

返回合成键列，使网格修改追踪能识别行标识：

| FKeyType | 键列 | 可编辑列 |
|---|---|---|
| hash | `field` | `value` |
| list | `index` | `value`（index 不可编辑） |
| zset | `member` | `score`（member 不可编辑） |
| set | `member` | （无，仅增删） |
| string | `key`（Redis 键名，不可编辑） | `value` |

### 3.5 `SaveModifications` 重写 — 命令映射

遍历 `FUpdateData`，对每个修改的行/单元格发 Redis 命令：

**已修改行（非插入）**：

| FKeyType | value 列改 | 键列改 |
|---|---|---|
| string | `SET key newval` | （禁用） |
| hash | `HSET key field newval` | `HDEL key oldfield` + `HSET key newfield val` |
| list | `LSET key index newval` | （禁用，index 不可编辑） |
| zset | `ZADD key newscore member` | `ZREM key oldmember` + `ZADD key score newmember` |
| set | （无 value 列） | `SREM key oldmember` + `SADD key newmember` |

**插入行**：

| FKeyType | 命令 |
|---|---|
| hash | `HSET key field value` |
| list | `RPUSH key value`（追加到末尾） |
| set | `SADD key member` |
| zset | `ZADD key score member` |
| string | （禁用插入） |

**删除行**（`DeleteRow` 重写）：

| FKeyType | 命令 |
|---|---|
| hash | `HDEL key field` |
| list | `LSET key index __TOMBSTONE__` + `LREM key 1 __TOMBSTONE__`（避免重复值误删） |
| set | `SREM key member` |
| zset | `ZREM key member` |
| string | （禁用删除，属键级操作） |

### 3.6 `EnsureFullRow` 重写

基类用 SQL `SELECT ... WHERE` 重新拉取行。Redis 重写为：保存后直接用 `FCurrentUpdateRow` 中的新值更新 `FReply.Items[recNo]`（无需二次请求）；若 `Refresh=True`（外部触发刷新），则用 `GetFullValue` 重新拉取完整值。

### 3.7 保存后本地数据同步

`SaveModifications` 成功后，直接更新 `FReply.Items[recNo]` 的 `Str` 值，避免整个网格重新 `Execute`（减少 Redis 往返）。仅当键列被修改（如 hash field 重命名）时才需刷新整个 key。

## 4. 键级操作与新建键

### 4.1 右键上下文菜单项

在 DB 树弹出菜单（`popupDBtree`）中为 Redis 键节点新增菜单项，仅当 `NetTypeGroup = ngRedis` 且选中键节点（`lntTable`）时可见：

| 菜单项 | Redis 命令 | 交互 |
|---|---|---|
| 删除键 | `DEL key` | 复用现有 `actDropObjects`（Drop 重写后自动生效），确认对话框 |
| 重命名键 | `RENAME key newkey` | `InputQuery` 输入新名；保存前 `EXISTS newkey` 检查覆盖；成功后更新树节点名 |
| 设置 TTL | `EXPIRE key seconds` | `InputQuery` 输入秒数（支持 `-1` → 实际发 `PERSIST`） |
| 取消 TTL | `PERSIST key` | 无输入，直接执行 |
| 查看 TTL | `TTL key` | `MessageDialog` 显示剩余秒数（-1=永不过期，-2=键不存在） |
| 复制键名 | — | 复制 `Obj.Name` 到剪贴板 |
| 新建键 | 按 type 发命令 | 弹 `TfrmRedisNewKey` 对话框 |

### 4.2 实现方式

新增 `TAction` 组件（`actRedisRename`、`actRedisExpire`、`actRedisPersist`、`actRedisTTL`、`actRedisNewKey`），在 `ValidateControls` 中按 `ngRedis` + 节点类型启用/禁用。菜单项在 `popupDBtree` 的 `OnPopup` 中动态显示/隐藏。

### 4.3 `TfrmRedisNewKey` 对话框

`TfrmRedisNewKey : TExtForm`（`redis_newkey.pas` + `.lfm`），布局：

```
┌─ 新建 Redis Key ──────────────────┐
│ Key 名称: [____________________]  │
│ 类型:    [string ▼]               │
│                                    │
│ 初始值:                            │
│ ┌────────────────────────────────┐│
│ │                                ││
│ │  (根据类型提示不同)             ││
│ │                                ││
│ └────────────────────────────────┘│
│                                    │
│              [取消]  [确定]        │
└────────────────────────────────────┘
```

**初始值按类型处理**：

- `string`：纯文本 → `SET key value`
- `hash`：每行 `field value`（空格分隔）→ 逐个 `HSET`
- `list`：每行一个元素 → 逐个 `RPUSH`
- `set`：每行一个 member → 逐个 `SADD`
- `zset`：每行 `member score` → 逐个 `ZADD`

确定后创建键，刷新键树父节点，选中新键。

### 4.4 键树刷新策略

- **删除/重命名**后：更新/移除对应树节点（不重新 SCAN 全量）
- **新建**后：在父节点添加新键节点
- **EXPIRE/PERSIST**后：更新信息栏 TTL 显示

## 5. UI 变更 — 信息栏、标签清理、网格编辑 UX

### 5.1 数据网格上方信息栏

在 `tabData` 中 `DataGrid` 上方新增 `TPanel`（`pnlRedisInfo`），含 `TLabel` 显示：

```
TYPE: hash | SIZE: 42 | TTL: 3600s | MEMORY: 1.2K
```

- 选中键时触发查询（`TYPE`/`TTL`/`HLEN`或`LLEN`或`SCARD`/`ZCARD`/`STRLEN`/`MEMORY USAGE`）
- 批量发 4 条快速命令（顺序执行，均为 O(1) 或 O(log N)）
- `MEMORY USAGE` 不可用（Redis < 4.0）时显示 `N/A`
- TTL = -1 显示 `永不过期`，-2 显示 `键不存在`

### 5.2 隐藏 Redis 无关标签

在 `DBtreeFocusChanged` 的标签可见性逻辑中：

```pascal
// 现有：
tabEditor.TabVisible := (FActiveDbObj <> nil) and (FActiveDbObj.NodeType in [lntTable..lntEvent, lntColumn]);
// 改为：
tabEditor.TabVisible := (FActiveDbObj <> nil)
  and (FActiveDbObj.NodeType in [lntTable..lntEvent, lntColumn])
  and (FActiveDbObj.Connection.Parameters.NetTypeGroup <> ngRedis);
```

Redis 键只显示 `tabData`（数据网格），不显示 `tabEditor`（表编辑器）。

### 5.3 网格列可编辑性控制

更新 `TRedisQuery.ColIsKeyPart` 返回 True 对键列，使网格知道哪些列是行标识：

| FKeyType | ColIsKeyPart=True 的列 | 效果 |
|---|---|---|
| hash | `field`(col 0) | 不可编辑 field，可编辑 value |
| list | `index`(col 0) | 不可编辑 index，可编辑 value |
| zset | `member`(col 0) | 不可编辑 member，可编辑 score |
| set | `member`(col 0) | 不可编辑（仅增删行） |
| string | `key`(col 0) | 不可编辑 key 名，可编辑 value(col 1) |

在 `AnyGridCreateEditor` 中加一行门控：

```pascal
if (Conn.Parameters.NetTypeGroup = ngRedis) and Results.ColIsKeyPart(ResultCol) then
  Exit;  // 键列不创建编辑器
```

### 5.4 文本编辑器保存路径

`CheckEditable` 重写后 `IsEditable=True` → `FAllowEdit=True` → 文本编辑器可编辑。保存流程复用网格的 `SaveModifications` 链路：

```
文本编辑器 Apply → 网格 DoEndEdit → 标记单元格修改 → SaveModifications → TRedisQuery 重写 → Redis 命令
```

**大值懒加载与编辑的冲突处理**：若用户在完整值加载前开始编辑，定时器替换内容前检查 `MemoText.Modified`，已修改则不覆盖（保留用户编辑）。

### 5.5 网格保存触发时机

复用现有网格保存触发点（导航离开、Enter/Tab 确认、手动保存按钮），不新增触发机制。

## 6. 错误处理

### 6.1 编辑操作错误处理

所有 Redis 命令错误（`-ERR`/`-WRONGTYPE`/`-NOSCRIPT` 等）已被 `TRedisClient.Execute` 转为 `ERedisError`，再被 `TRedisConnection.Query` 转为 `EDbError`。`SaveModifications`/`DeleteRow` 重写中捕获 `EDbError`，行为：

| 错误场景 | 处理 |
|---|---|
| `-WRONGTYPE`（键类型已变） | 提示"键类型已变更，请刷新"，拒绝保存，标记需刷新 |
| 键已被删除（`HDEL` 返回 0） | 提示"键或字段不存在，请刷新" |
| `LSET` 索引越界 | 提示"列表已变更，请刷新" |
| `RENAME` 目标已存在 | `RENAME` 会覆盖，保存前 `EXISTS newkey` 检查并确认 |
| `EXPIRE` 键不存在（返回 0） | 提示"键不存在" |
| `EVAL` 被禁用 | 已有回退逻辑（逐个 HGET），编辑路径不依赖 EVAL |

### 6.2 边界情况

| 场景 | 处理 |
|---|---|
| 空键名 | 新建键对话框验证非空 |
| 超大值编辑 | 文本编辑器已有懒加载 + cjson 截断；保存时直接 `SET`/`HSET` 原值，无大小限制 |
| 二进制数据 | 首期仅支持文本编辑；hex 编辑留后续 |
| 并发修改（其他客户端改了键） | 编辑命令失败时提示刷新；不做乐观锁（`WATCH` 过重） |
| set 类型"编辑" | 不支持原地编辑 member，只能删除旧行 + 新增新行 |
| string 类型增删行 | 禁用（`CheckEditable` 中 string 不允许 `InsertRow`/`DeleteRow`） |
| stream 类型 | 首期不支持编辑，仅查看 |

## 7. 测试策略

沿用项目现有策略（可编译 + 手动冒烟 + 独立协议测试），不引入 FPCUnit：

1. **编译验证**：`make build-qt6` 通过，无新警告
2. **协议测试扩展**（`tests/test_redis_proto.lpr`）：已有 RESP 解析测试，新增命令序列化测试（`HSET`/`LSET`/`ZADD` 等参数编码）
3. **编辑方法单元验证**：在 `TRedisQuery` 中用 `TRedisMemorySource` 模拟回复，验证 `SaveModifications` 正确发出命令（不连真实 Redis）
4. **端到端冒烟清单**（手动，需 `redis:7` docker）：
   - 各类型键值编辑（string SET / hash HSET / list LSET / zset ZADD）
   - 各类型增删行（hash HDEL/HSET / list LREM / set SREM/SADD / zset ZREM/ZADD）
   - 键操作（DEL / RENAME / EXPIRE / PERSIST / TTL）
   - 新建键（各类型）
   - 信息栏显示（TYPE/SIZE/TTL/MEMORY）
   - 标签清理（tabEditor 隐藏）
   - 大值编辑（>100KB string/hash field）

## 8. 不在本次范围内（YAGNI）

- Stream 类型编辑（`XADD`/`XDEL`/`XSET`）— 仅查看
- 二进制 hex 编辑 — 后续与 `THexEditorLink` 集成
- Redis 命令台（`redis_console.pas`）— SQL 查询页已可用
- Cluster/Sentinel — 原 design 已标后续
- ACL 管理 UI — 原 design 已标后续
- `WATCH`/`MULTI`/`EXEC` 乐观事务 — 过重
