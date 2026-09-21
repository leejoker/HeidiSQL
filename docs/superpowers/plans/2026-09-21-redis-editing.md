# Redis 编辑能力补充 — 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 HeidiSQL 的 Redis 支持补充完整的编辑能力——修复键删除、网格内值编辑、键级操作（DEL/RENAME/EXPIRE/PERSIST/TTL）、新建键 UI、信息栏、标签清理。

**Architecture:** 重写 `TRedisQuery` 的编辑方法（`CheckEditable`/`GetKeyColumns`/`SaveModifications`/`DeleteRow`/`InsertRow`/`EnsureFullRow`/`ColIsKeyPart`），将网格编辑操作映射到 Redis 命令。重写 `TRedisConnection.Drop` 发 `DEL` 而非 `DROP TABLE`。在 main.pas 加右键菜单和信息栏。

**Tech Stack:** Free Pascal 3.2.2 / Lazarus 4.x（`{$mode delphi}{$H+}`）、LCL（TVirtualStringTree、TPageControl、TPopupMenu、TSynEdit）。

## Global Constraints

- 编译器: `/data/fpc_tools/fpc/bin/x86_64-linux/fpc`，构建工具: `/data/fpc_tools/lazarus/lazbuild --primary-config-path=/data/fpc_tools/config_lazarus`
- 主构建命令: `make build-qt6`（或 `lazbuild --bm=Release --ws=qt6 heidisql.lpi`）
- 每个 `.pas` 文件首行 `{$mode delphi}{$H+}`，表单单元含 `{$R *.lfm}`
- 常量放 `source/const.inc`（`{$I const.inc}`），设置走 `TAppSettingIndex` 枚举（`apphelpers.pas`）
- `TDBConnection` 子类按引擎命名（`TRedisConnection`），Query 子类同理（`TRedisQuery`）
- 新增表单继承 `TExtForm`，控件用 `edit.../combo.../btn.../lbl.../pnl...` 前缀
- 不引入 FPCUnit；测试用独立控制台程序（`tests/test_redis_proto.lpr`）+ 手动冒烟
- 禁止提交 `bin/`、`out/`、`*.ppu`、`*.o`

---

## 文件结构

| 文件 | 职责 | 动作 |
|---|---|---|
| `source/dbconnection.pas` | `TDBQuery` 基类虚化 + `TRedisConnection.Drop` 重写 + `TRedisQuery` 编辑方法重写 | 修改 |
| `source/main.pas` | 标签清理 + 右键菜单 + 信息栏 + 网格编辑门控 | 修改 |
| `source/main.lfm` | 信息栏面板 + 右键菜单项 + 新 Action 声明 | 修改 |
| `source/texteditor.pas` | 懒加载覆盖用户编辑的 bug 修复 | 修改 |
| `source/redis_newkey.pas` + `source/redis_newkey.lfm` | 新建键对话框 | 创建 |
| `source/const.inc` | Redis 图标常量 | 修改 |
| `tests/test_redis_proto.lpr` | 命令序列化测试扩展 | 修改 |

---

## Task 1: `TDBQuery` 编辑方法虚化

将 `TDBQuery` 的 6 个编辑方法加 `virtual`，使 `TRedisQuery` 能重写它们。无现有子类重写这些方法，向后兼容。

**Files:**
- Modify: `source/dbconnection.pas:904-914`（接口声明）

**Interfaces:**
- Produces: `TDBQuery.CheckEditable: virtual; GetKeyColumns: virtual; DeleteRow: virtual; InsertRow: virtual; EnsureFullRow: virtual; SaveModifications: virtual`（后续 Task 3 重写）

- [ ] **Step 1: 虚化接口声明**

在 `source/dbconnection.pas` 第 904 行附近，将：

```pascal
    procedure CheckEditable;
    function IsEditable: Boolean;
    procedure DeleteRow;
    function InsertRow: Int64;
    procedure SetCol(Column: Integer; NewText: String; Null: Boolean; IsFunction: Boolean);
    function EnsureFullRow(Refresh: Boolean): Boolean;
    function HasFullData: Boolean;
    function Modified(Column: Integer): Boolean; overload;
    function Modified: Boolean; overload;
    function Inserted: Boolean;
    function SaveModifications: Boolean;
```

改为：

```pascal
    procedure CheckEditable; virtual;
    function IsEditable: Boolean;
    procedure DeleteRow; virtual;
    function InsertRow: Int64; virtual;
    procedure SetCol(Column: Integer; NewText: String; Null: Boolean; IsFunction: Boolean);
    function EnsureFullRow(Refresh: Boolean): Boolean; virtual;
    function HasFullData: Boolean;
    function Modified(Column: Integer): Boolean; overload;
    function Modified: Boolean; overload;
    function Inserted: Boolean;
    function SaveModifications: Boolean; virtual;
```

同时将 `GetKeyColumns` 声明（在 private 区域，约第 874 行）加 `virtual`：

```pascal
    function GetKeyColumns: TTableColumnList; virtual;
```

- [ ] **Step 2: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功，无新警告

- [ ] **Step 3: Commit**

```bash
git add source/dbconnection.pas
git commit -m "refactor: 虚化 TDBQuery 编辑方法以支持 Redis 重写

将 CheckEditable/GetKeyColumns/DeleteRow/InsertRow/EnsureFullRow/
SaveModifications 声明为 virtual，使 TRedisQuery 能按 Redis 命令模型
重写这些方法。无现有子类重写它们，向后兼容。"
```

---

## Task 2: `TRedisConnection.Drop` 重写 + `TRedisQuery.ColIsKeyPart` 重写

修复键删除发送 `DROP TABLE` 的 bug，并让网格知道哪些列是键列（不可编辑）。

**Files:**
- Modify: `source/dbconnection.pas`（`TRedisConnection` 声明区 + 实现区；`TRedisQuery.ColIsKeyPart` 实现区）

**Interfaces:**
- Consumes: Task 1 的虚化方法
- Produces: `TRedisConnection.Drop` 发 `DEL`；`TRedisQuery.ColIsKeyPart` 按类型返回 True 对键列

- [ ] **Step 1: 在 `TRedisConnection` 声明中加 `Drop` 重写**

在 `source/dbconnection.pas` 第 835 行 `function GetCreateCode` 后，`TRedisConnection` 的 public 区加：

```pascal
    procedure Drop(Obj: TDBObject); override;
```

- [ ] **Step 2: 实现 `TRedisConnection.Drop`**

在 `TRedisConnection` 实现区（`GetCreateCode` 实现之后，约 11863 行），加：

```pascal
procedure TRedisConnection.Drop(Obj: TDBObject);
begin
  // Redis 删除键用 DEL，不是 SQL 的 DROP TABLE
  Query('DEL ' + Obj.Name);
end;
```

- [ ] **Step 3: 重写 `TRedisQuery.ColIsKeyPart`**

将 `TRedisQuery.ColIsKeyPart`（约 12557 行）从：

```pascal
function TRedisQuery.ColIsKeyPart(Column: Integer): Boolean;
begin
  Result := False;
end;
```

改为：

```pascal
function TRedisQuery.ColIsKeyPart(Column: Integer): Boolean;
begin
  // 键列（标识列）不可在网格内编辑
  // string: col 0 = key 名（不可编辑），col 1 = value（可编辑）
  // hash:   col 0 = field（不可编辑），col 1 = value（可编辑）
  // list:   col 0 = index（不可编辑），col 1 = value（可编辑）
  // zset:   col 0 = member（不可编辑），col 1 = score（可编辑）
  // set:    col 0 = member（不可编辑，仅增删行）
  Result := (Column = 0);
end;
```

- [ ] **Step 4: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 5: Commit**

```bash
git add source/dbconnection.pas
git commit -m "fix: 修复 Redis 键删除发送 DROP TABLE 的 bug

重写 TRedisConnection.Drop 发送 DEL 命令而非 DROP TABLE。
重写 TRedisQuery.ColIsKeyPart 标识键列（col 0）为不可编辑列。"
```

---

## Task 3: `TRedisQuery.CheckEditable` + `GetKeyColumns` 重写

让 `IsEditable` 返回 True（使网格和文本编辑器可编辑），并返回合成键列使修改追踪能识别行标识。

**Files:**
- Modify: `source/dbconnection.pas`（`TRedisQuery` 声明区 + 实现区）

**Interfaces:**
- Consumes: Task 1 的虚化方法
- Produces: `TRedisQuery.CheckEditable` 按 `FKeyType` 判断；`GetKeyColumns` 返回合成列

- [ ] **Step 1: 在 `TRedisQuery` 声明中加重写**

在 `TRedisQuery` 的 public 区（约 1034-1058 行），在 `HasResult` 声明后加：

```pascal
    procedure CheckEditable; override;
    function GetKeyColumns: TTableColumnList; override;
```

- [ ] **Step 2: 实现 `TRedisQuery.CheckEditable`**

在 `TRedisQuery` 实现区（`HasResult` 实现之后），加：

```pascal
procedure TRedisQuery.CheckEditable;
begin
  // string: 可编辑 value（单值），不可增删行
  // hash/list/set/zset: 可编辑、可增删行
  // none/stream: 不可编辑
  if (FKeyType = 'none') or (FKeyType = 'stream') or (FKey = '') then
    raise EDbError.Create(_(MSG_NOGRIDEDITING));
end;
```

- [ ] **Step 3: 实现 `TRedisQuery.GetKeyColumns`**

在 `CheckEditable` 实现之后，加：

```pascal
function TRedisQuery.GetKeyColumns: TTableColumnList;
var
  Col: TTableColumn;
  dt: TDBDatatype;
begin
  // 返回合成键列，使网格修改追踪能识别行标识
  PrepareColumnAttributes;
  Result := TTableColumnList.Create(False);

  dt.Index := dbdtVarchar;
  dt.Name := 'text';
  dt.Category := dtcText;
  dt.HasLength := False;
  dt.HasBinary := False;
  dt.HasDefault := False;
  dt.LoadPart := False;

  Col := TTableColumn.Create(FConn);
  case FKeyType of
    'hash':  Col.Name := 'field';
    'list':  Col.Name := 'index';
    'zset':  Col.Name := 'member';
    'set':   Col.Name := 'member';
    'string': Col.Name := 'key';
  else
    Col.Name := 'key';
  end;
  Col.OldName := Col.Name;
  Col.DataType := dt;
  Col.AllowNull := False;
  Result.Add(Col);
end;
```

注意：`PrepareColumnAttributes` 基类会调 `GetTableColumns`（已重写为返回合成列），这里不再重复调用 `GetTableColumns`，而是用 `FColumns`（由 `PrepareColumnAttributes` 填充）。但由于 `PrepareColumnAttributes` 内部查找 `TDBObject`，Redis 键作为 `lntTable` 能找到，列已由 `GetTableColumns` 返回。

- [ ] **Step 4: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 5: Commit**

```bash
git add source/dbconnection.pas
git commit -m "feat: Redis 网格编辑基础 — CheckEditable + GetKeyColumns 重写

CheckEditable 按 FKeyType 判断可编辑性（none/stream 不可编辑）。
GetKeyColumns 返回合成键列使网格修改追踪能识别行标识。"
```

---

## Task 4: `TRedisQuery.SaveModifications` + `DeleteRow` + `InsertRow` + `EnsureFullRow` 重写

这是核心编辑逻辑——将网格修改操作映射到 Redis 命令。

**Files:**
- Modify: `source/dbconnection.pas`（`TRedisQuery` 声明区 + 实现区）

**Interfaces:**
- Consumes: Task 3 的 `CheckEditable`/`GetKeyColumns`
- Produces: 完整的网格编辑能力

- [ ] **Step 1: 在 `TRedisQuery` 声明中加重写**

在 `TRedisQuery` 的 public 区，Task 3 加的声明后，加：

```pascal
    function SaveModifications: Boolean; override;
    procedure DeleteRow; override;
    function InsertRow: Int64; override;
    function EnsureFullRow(Refresh: Boolean): Boolean; override;
```

- [ ] **Step 2: 实现 `SaveModifications`**

在 `TRedisQuery.GetKeyColumns` 实现之后，加：

```pascal
function TRedisQuery.SaveModifications: Boolean;
var
  Row: TGridRow;
  i: Integer;
  Cell: TGridValue;
  fieldVal, newVal, oldMember, newMember: String;
  scoreVal: String;
  RecNoStr: String;
  Tombstone: String;
  procedure DoCmd(const Args: array of string);
  begin
    FConn.Client.Execute(Args).Free;
  end;
begin
  Result := True;
  if not FEditingPrepared then
    raise EDbError.Create(_('Internal error: Cannot post modifications before editing was prepared.'));

  for Row in FUpdateData do begin
    RecNo := Row.RecNo;
    try
      if Row.Inserted then begin
        // 插入行
        case FKeyType of
          'hash': begin
            // col 0 = field, col 1 = value
            if Row[0].NewIsNull or Row[1].NewIsNull then Continue;
            DoCmd(['HSET', FKey, Row[0].NewText, Row[1].NewText]);
            // 更新本地数据
            if (RecNo >= 0) and (RecNo*2+1 < Length(FReply.Items)) then begin
              if FReply.Items[RecNo*2] <> nil then FReply.Items[RecNo*2].Str := Row[0].NewText;
              if FReply.Items[RecNo*2+1] <> nil then FReply.Items[RecNo*2+1].Str := Row[1].NewText;
            end;
          end;
          'list': begin
            if Row[1].NewIsNull then Continue;
            DoCmd(['RPUSH', FKey, Row[1].NewText]);
          end;
          'set': begin
            if Row[0].NewIsNull then Continue;
            DoCmd(['SADD', FKey, Row[0].NewText]);
          end;
          'zset': begin
            if Row[0].NewIsNull then Continue;
            scoreVal := IfThen(Row[1].NewIsNull, '0', Row[1].NewText);
            DoCmd(['ZADD', FKey, scoreVal, Row[0].NewText]);
          end;
        end;
      end else begin
        // 已存在行修改
        for i:=0 to Row.Count-1 do begin
          Cell := Row[i];
          if not Cell.Modified then Continue;
          case FKeyType of
            'string': begin
              // col 1 = value
              if i = 1 then
                DoCmd(['SET', FKey, Cell.NewText]);
            end;
            'hash': begin
              // col 0 = field（改名：HDEL old + HSET new val）, col 1 = value
              fieldVal := Row[0].OldText;
              if i = 0 then begin
                // field 改名
                DoCmd(['HDEL', FKey, fieldVal]);
                DoCmd(['HSET', FKey, Cell.NewText, Row[1].OldText]);
              end else if i = 1 then begin
                DoCmd(['HSET', FKey, fieldVal, Cell.NewText]);
              end;
            end;
            'list': begin
              // col 1 = value（col 0 = index 不可改）
              if i = 1 then begin
                RecNoStr := IntToStr(RecNo);
                DoCmd(['LSET', FKey, RecNoStr, Cell.NewText]);
              end;
            end;
            'zset': begin
              // col 0 = member（改名：ZREM old + ZADD score new）, col 1 = score
              oldMember := Row[0].OldText;
              if i = 0 then begin
                scoreVal := IfThen(Row[1].NewIsNull, '0', Row[1].NewText);
                DoCmd(['ZREM', FKey, oldMember]);
                DoCmd(['ZADD', FKey, scoreVal, Cell.NewText]);
              end else if i = 1 then begin
                DoCmd(['ZADD', FKey, Cell.NewText, oldMember]);
              end;
            end;
          end;
        end;
      end;
      // 重置修改标志
      for i:=0 to Row.Count-1 do begin
        Cell := Row[i];
        Cell.OldText := Cell.NewText;
        Cell.OldIsNull := Cell.NewIsNull;
        Cell.OldIsFunction := False;
        Cell.NewIsFunction := False;
        Cell.Modified := False;
      end;
      Row.Inserted := False;
    except
      on E: ERedisError do begin
        Result := False;
        ErrorDialog(E.Message);
      end;
    end;
  end;
end;
```

- [ ] **Step 3: 实现 `DeleteRow`**

在 `SaveModifications` 实现之后，加：

```pascal
procedure TRedisQuery.DeleteRow;
var
  fieldVal, memberVal, RecNoStr, Tombstone: String;
  IsVirtual: Boolean;
begin
  PrepareEditing;
  IsVirtual := Assigned(FCurrentUpdateRow) and FCurrentUpdateRow.Inserted;
  if not IsVirtual then begin
    try
      case FKeyType of
        'hash': begin
          fieldVal := Col(0);
          FConn.Client.Execute(['HDEL', FKey, fieldVal]).Free;
        end;
        'list': begin
          RecNoStr := IntToStr(RecNo);
          // tombstone 方案避免重复值误删
          Tombstone := '__HEIDISQL_TOMBSTONE_' + IntToStr(GetTickCount64) + '__';
          FConn.Client.Execute(['LSET', FKey, RecNoStr, Tombstone]).Free;
          FConn.Client.Execute(['LREM', FKey, '1', Tombstone]).Free;
        end;
        'set': begin
          memberVal := Col(0);
          FConn.Client.Execute(['SREM', FKey, memberVal]).Free;
        end;
        'zset': begin
          memberVal := Col(0);
          FConn.Client.Execute(['ZREM', FKey, memberVal]).Free;
        end;
        'string':
          raise EDbError.Create(_('Cannot delete row from a string key. Use "Delete key" to remove the entire key.'));
      end;
    except
      on E: ERedisError do
        raise EDbError.Create(E.Message);
    end;
  end;
  if Assigned(FCurrentUpdateRow) then begin
    FUpdateData.Remove(FCurrentUpdateRow);
    FCurrentUpdateRow := nil;
    FRecNo := -1;
  end;
end;
```

- [ ] **Step 4: 实现 `InsertRow`**

在 `DeleteRow` 实现之后，加：

```pascal
function TRedisQuery.InsertRow: Int64;
var
  Row: TGridRow;
  c: TGridValue;
  i: Integer;
  ColAttr: TTableColumn;
begin
  // string 类型不允许插入行
  if FKeyType = 'string' then
    raise EDbError.Create(_('Cannot insert rows into a string key. Use "New Key" to create a new key.'));

  PrepareEditing;
  Row := TGridRow.Create(True);
  for i:=0 to ColumnCount-1 do begin
    c := TGridValue.Create;
    Row.Add(c);
    c.OldText := '';
    c.OldIsFunction := False;
    c.OldIsNull := True;
    c.NewText := '';
    c.NewIsFunction := False;
    c.NewIsNull := True;
    c.Modified := False;
  end;
  Row.Inserted := True;
  Result := High(Cardinal);
  while True do begin
    var InUse := False;
    var OtherRow: TGridRow;
    for OtherRow in FUpdateData do begin
      InUse := OtherRow.RecNo = Result;
      if InUse then break;
    end;
    if not InUse then break;
    Dec(Result);
  end;
  Row.RecNo := Result;
  FUpdateData.Add(Row);
end;
```

注意：FPC `{$mode delphi}` 支持 `for ... in` 循环内变量声明，但内联 `var` 声明需 FPC 3.3+。为兼容 3.2.2，改为在函数顶部声明 `InUse` 和 `OtherRow`。修正版：

```pascal
function TRedisQuery.InsertRow: Int64;
var
  Row, OtherRow: TGridRow;
  c: TGridValue;
  i: Integer;
  InUse: Boolean;
begin
  if FKeyType = 'string' then
    raise EDbError.Create(_('Cannot insert rows into a string key. Use "New Key" to create a new key.'));

  PrepareEditing;
  Row := TGridRow.Create(True);
  for i:=0 to ColumnCount-1 do begin
    c := TGridValue.Create;
    Row.Add(c);
    c.OldText := '';
    c.OldIsFunction := False;
    c.OldIsNull := True;
    c.NewText := '';
    c.NewIsFunction := False;
    c.NewIsNull := True;
    c.Modified := False;
  end;
  Row.Inserted := True;
  Result := High(Cardinal);
  while True do begin
    InUse := False;
    for OtherRow in FUpdateData do begin
      InUse := OtherRow.RecNo = Result;
      if InUse then break;
    end;
    if not InUse then break;
    Dec(Result);
  end;
  Row.RecNo := Result;
  FUpdateData.Add(Row);
end;
```

- [ ] **Step 5: 实现 `EnsureFullRow`**

在 `InsertRow` 实现之后，加：

```pascal
function TRedisQuery.EnsureFullRow(Refresh: Boolean): Boolean;
var
  i: Integer;
  FullText: String;
begin
  // Redis: 保存后直接用 FCurrentUpdateRow 的值更新本地数据，无需二次请求。
  // 仅当 Refresh=True（外部触发刷新）时用 GetFullValue 重新拉取。
  Result := True;
  if not Assigned(FCurrentUpdateRow) then
    Exit;
  if Refresh then begin
    try
      FullText := GetFullValue(RecNo, 1);
      if FullText <> '' then begin
        FCurrentUpdateRow[1].OldText := FullText;
        FCurrentUpdateRow[1].NewText := FullText;
        FCurrentUpdateRow[1].OldIsNull := False;
        FCurrentUpdateRow[1].NewIsNull := False;
        if (RecNo >= 0) and (RecNo*2+1 < Length(FReply.Items)) and (FReply.Items[RecNo*2+1] <> nil) then
          FReply.Items[RecNo*2+1].Str := FullText;
      end;
    except
      on E: ERedisError do
        Result := False;
    end;
  end;
end;
```

- [ ] **Step 6: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 7: Commit**

```bash
git add source/dbconnection.pas
git commit -m "feat: Redis 网格编辑核心 — SaveModifications/DeleteRow/InsertRow/EnsureFullRow

SaveModifications: 按类型映射 Redis 命令（SET/HSET/LSET/ZADD 等）
DeleteRow: HDEL/LREM(tombstone)/SREM/ZREM，string 禁用
InsertRow: RPUSH/SADD/ZADD/HSET，string 禁用
EnsureFullRow: 保存后本地同步，避免二次请求"
```

---

## Task 5: 网格编辑门控 — 键列不创建编辑器

在 `AnyGridCreateEditor` 中对 Redis 键列（`ColIsKeyPart=True`）直接返回，不创建编辑器。

**Files:**
- Modify: `source/main.pas:11358`（`AnyGridCreateEditor` 开头）

**Interfaces:**
- Consumes: Task 2 的 `ColIsKeyPart` 重写

- [ ] **Step 1: 加门控逻辑**

在 `source/main.pas` 第 11358 行 `AllowEdit := Results.IsEditable;` 之后，加：

```pascal
  // Redis: 键列（标识列）不可在网格内编辑，直接返回不创建编辑器
  if (Conn.Parameters.NetTypeGroup = ngRedis) and Results.ColIsKeyPart(ResultCol) then
    Exit;
```

- [ ] **Step 2: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add source/main.pas
git commit -m "feat: Redis 网格键列不创建编辑器

在 AnyGridCreateEditor 中对 Redis 键列（ColIsKeyPart=True）直接返回，
防止用户编辑 field/index/member 等标识列。"
```

---

## Task 6: 标签清理 — Redis 隐藏 `tabEditor`

Redis 键不需要表编辑器（列/索引/外键），隐藏 `tabEditor`。

**Files:**
- Modify: `source/main.pas:10224`（`DBtreeFocusChanged` 中的标签可见性）

- [ ] **Step 1: 修改标签可见性逻辑**

在 `source/main.pas` 第 10224 行，将：

```pascal
    tabEditor.TabVisible := (FActiveDbObj <> nil) and (FActiveDbObj.NodeType in [lntTable..lntEvent, lntColumn]);
```

改为：

```pascal
    tabEditor.TabVisible := (FActiveDbObj <> nil)
      and (FActiveDbObj.NodeType in [lntTable..lntEvent, lntColumn])
      and (FActiveDbObj.Connection.Parameters.NetTypeGroup <> ngRedis);
```

- [ ] **Step 2: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add source/main.pas
git commit -m "feat: Redis 隐藏 tabEditor 表编辑器标签

Redis 键不需要表编辑器（列/索引/外键），隐藏 tabEditor。
Redis 键只显示 tabData（数据网格）。"
```

---

## Task 7: 修复文本编辑器懒加载覆盖用户编辑的 bug

当用户在完整值加载前开始编辑，定时器不应覆盖用户输入。

**Files:**
- Modify: `source/texteditor.pas:496-507`（`TimerLazyLoadTimer`）

- [ ] **Step 1: 加修改检查**

在 `source/texteditor.pas` 第 496 行，将：

```pascal
  if FullText <> '' then begin
    FIsTruncated := wasTruncated;
    MemoText.BeginUpdate;
    try
      MemoText.Text := FullText;
      DoAutoDetectAndFormat;
    finally
      MemoText.EndUpdate;
    end;
    MemoText.CaretXY := Point(1, 1);
    MemoText.ClearSelection;
  end;
```

改为：

```pascal
  if FullText <> '' then begin
    // 若用户已在截断值上开始编辑，不覆盖其修改
    if MemoText.Modified then
      Exit;
    FIsTruncated := wasTruncated;
    MemoText.BeginUpdate;
    try
      MemoText.Text := FullText;
      DoAutoDetectAndFormat;
    finally
      MemoText.EndUpdate;
    end;
    MemoText.CaretXY := Point(1, 1);
    MemoText.ClearSelection;
  end;
```

- [ ] **Step 2: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 3: Commit**

```bash
git add source/texteditor.pas
git commit -m "fix: 修复文本编辑器懒加载覆盖用户编辑的 bug

当用户在完整值加载前开始编辑，定时器检查 MemoText.Modified，
已修改则不覆盖用户输入。"
```

---

## Task 8: 新建键对话框 — `redis_newkey.pas` + `.lfm`

创建 `TfrmRedisNewKey : TExtForm` 对话框，输入键名 + 类型 + 初始值。

**Files:**
- Create: `source/redis_newkey.pas`
- Create: `source/redis_newkey.lfm`

**Interfaces:**
- Produces: `TfrmRedisNewKey` 表单，`GetKeyName`/`GetKeyType`/`GetInitialValue` 方法供 Task 9 调用

- [ ] **Step 1: 创建 `redis_newkey.pas`**

```pascal
unit redis_newkey;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Buttons, ExtCtrls,
  extra_controls, apphelpers, dbconnection, redisclient;

type
  TfrmRedisNewKey = class(TExtForm)
    lblKeyName: TLabel;
    editKeyName: TEdit;
    lblType: TLabel;
    comboType: TComboBox;
    lblValue: TLabel;
    memoValue: TMemo;
    btnOK: TButton;
    btnCancel: TButton;
    procedure FormCreate(Sender: TObject);
    procedure comboTypeChange(Sender: TObject);
    procedure btnOKClick(Sender: TObject);
  private
    FConn: TRedisConnection;
    procedure UpdateValueHint;
  public
    procedure SetConnection(Conn: TRedisConnection);
    function GetKeyName: String;
    function GetKeyType: String;
    function GetInitialValue: String;
  end;

var
  frmRedisNewKey: TfrmRedisNewKey;

implementation

uses
  LCLType;

{$R *.lfm}
{$I const.inc}

procedure TfrmRedisNewKey.FormCreate(Sender: TObject);
begin
  Caption := _('New Redis Key');
  lblKeyName.Caption := _('Key name:');
  lblType.Caption := _('Type:');
  lblValue.Caption := _('Initial value:');
  comboType.Items.Clear;
  comboType.Items.Add('string');
  comboType.Items.Add('hash');
  comboType.Items.Add('list');
  comboType.Items.Add('set');
  comboType.Items.Add('zset');
  comboType.ItemIndex := 0;
  UpdateValueHint;
  btnOK.Caption := _('OK');
  btnOK.Default := True;
  btnOK.ModalResult := mrNone;
  btnCancel.Caption := _('Cancel');
  btnCancel.Cancel := True;
  btnCancel.ModalResult := mrCancel;
end;

procedure TfrmRedisNewKey.SetConnection(Conn: TRedisConnection);
begin
  FConn := Conn;
end;

procedure TfrmRedisNewKey.UpdateValueHint;
begin
  case comboType.Text of
    'string': lblValue.Caption := _('Initial value:') + ' ' + _('(plain text)');
    'hash':   lblValue.Caption := _('Initial value:') + ' ' + _('(one "field value" per line)');
    'list':   lblValue.Caption := _('Initial value:') + ' ' + _('(one element per line)');
    'set':    lblValue.Caption := _('Initial value:') + ' ' + _('(one member per line)');
    'zset':   lblValue.Caption := _('Initial value:') + ' ' + _('(one "member score" per line)');
  end;
end;

procedure TfrmRedisNewKey.comboTypeChange(Sender: TObject);
begin
  UpdateValueHint;
end;

procedure TfrmRedisNewKey.btnOKClick(Sender: TObject);
var
  KeyName: String;
begin
  KeyName := Trim(editKeyName.Text);
  if KeyName = '' then begin
    MessageDialog(_('Key name cannot be empty.'), mtError, [mbOK]);
    editKeyName.SetFocus;
    Exit;
  end;
  ModalResult := mrOK;
end;

function TfrmRedisNewKey.GetKeyName: String;
begin
  Result := Trim(editKeyName.Text);
end;

function TfrmRedisNewKey.GetKeyType: String;
begin
  Result := comboType.Text;
end;

function TfrmRedisNewKey.GetInitialValue: String;
begin
  Result := memoValue.Text;
end;

end.
```

- [ ] **Step 2: 创建 `redis_newkey.lfm`**

```lfm
object frmRedisNewKey: TfrmRedisNewKey
  Left = 400
  Height = 350
  Top = 200
  Width = 450
  BorderStyle = bsDialog
  Caption = 'New Redis Key'
  ClientHeight = 350
  ClientWidth = 450
  Position = poMainFormCenter
  LCLVersion = '2.2.6.0'
  object lblKeyName: TLabel
    Left = 12
    Height = 16
    Top = 12
    Width = 70
    Caption = 'Key name:'
    FocusControl = editKeyName
  end
  object editKeyName: TEdit
    Left = 12
    Height = 28
    Top = 32
    Width = 426
    Anchors = [akTop, akLeft, akRight]
    TabOrder = 0
  end
  object lblType: TLabel
    Left = 12
    Height = 16
    Top = 68
    Width = 35
    Caption = 'Type:'
    FocusControl = comboType
  end
  object comboType: TComboBox
    Left = 12
    Height = 28
    Top = 88
    Width = 426
    Anchors = [akTop, akLeft, akRight]
    ItemIndex = 0
    Items.Strings = (
      'string'
      'hash'
      'list'
      'set'
      'zset'
    )
    Style = csDropDownList
    TabOrder = 1
    OnChange = comboTypeChange
  end
  object lblValue: TLabel
    Left = 12
    Height = 16
    Top = 124
    Width = 70
    Caption = 'Initial value:'
  end
  object memoValue: TMemo
    Left = 12
    Height = 160
    Top = 144
    Width = 426
    Anchors = [akTop, akLeft, akRight, akBottom]
    TabOrder = 2
    WordWrap = False
  end
  object btnOK: TButton
    Left = 268
    Height = 28
    Top = 314
    Width = 80
    Anchors = [akRight, akBottom]
    Caption = 'OK'
    TabOrder = 3
    OnClick = btnOKClick
  end
  object btnCancel: TButton
    Left = 358
    Height = 28
    Top = 314
    Width = 80
    Anchors = [akRight, akBottom]
    Caption = 'Cancel'
    ModalResult = 2
    TabOrder = 4
  end
end
```

- [ ] **Step 3: 在 `heidisql.lpi` 中注册新单元**

在 `heidisql.lpi` 的 `<Unit>` 列表中加一项（参照其他表单单元如 `editvar` 的格式）：

```xml
        <Unit>
          <Filename Value="source/redis_newkey.pas"/>
          <IsPartOfProject Value="True"/>
          <ComponentName Value="frmRedisNewKey"/>
          <HasResources Value="True"/>
          <ResourceBaseClass Value="Form"/>
        </Unit>
```

- [ ] **Step 4: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 5: Commit**

```bash
git add source/redis_newkey.pas source/redis_newkey.lfm heidisql.lpi
git commit -m "feat: 新建 Redis Key 对话框

TfrmRedisNewKey : TExtForm，输入键名 + 类型 + 初始值。
按类型提示不同的初始值格式（string/hash/list/set/zset）。"
```

---

## Task 9: Redis 键右键菜单 — 重命名/设TTL/取消TTL/查看TTL/复制键名/新建键

在 `popupDB` 菜单中加 Redis 专用菜单项，实现各键操作。

**Files:**
- Modify: `source/main.pas`（声明区 + `popupDBPopup` + 新事件处理 + lfm 菜单项）
- Modify: `source/main.lfm`（`popupDB` 菜单项 + Action 声明）

**Interfaces:**
- Consumes: Task 8 的 `TfrmRedisNewKey`

- [ ] **Step 1: 在 `main.pas` 声明区加 Action 和菜单事件**

在 `TMainForm` 的 Action 声明区（约 290 行附近 `actDropObjects` 后），加：

```pascal
    actRedisRename: TAction;
    actRedisExpire: TAction;
    actRedisPersist: TAction;
    actRedisTTL: TAction;
    actRedisNewKey: TAction;
```

在 procedure 声明区加：

```pascal
    procedure actRedisRenameExecute(Sender: TObject);
    procedure actRedisExpireExecute(Sender: TObject);
    procedure actRedisPersistExecute(Sender: TObject);
    procedure actRedisTTLExecute(Sender: TObject);
    procedure actRedisNewKeyExecute(Sender: TObject);
    procedure menuRedisCopyKeyNameClick(Sender: TObject);
```

- [ ] **Step 2: 在 `main.lfm` 的 `popupDB` 中加菜单项**

在 `popupDB` 菜单（约 20321 行）的 `menuDeleteObject` 之后，加：

```lfm
    object menuRedisRename: TMenuItem
      Action = actRedisRename
    end
    object menuRedisExpire: TMenuItem
      Action = actRedisExpire
    end
    object menuRedisPersist: TMenuItem
      Action = actRedisPersist
    end
    object menuRedisTTL: TMenuItem
      Action = actRedisTTL
    end
    object menuRedisCopyKeyName: TMenuItem
      Caption = 'Copy key name'
      OnClick = menuRedisCopyKeyNameClick
    end
    object menuRedisSeparator: TMenuItem
      Caption = '-'
    end
    object menuRedisNewKey: TMenuItem
      Action = actRedisNewKey
    end
```

同时在 lfm 的 ActionList 区（查找 `actDropObjects` 声明位置）加 Action 声明：

```lfm
    object actRedisRename: TAction
      Caption = 'Rename key'
      Hint = 'Rename Redis key'
      OnExecute = actRedisRenameExecute
    end
    object actRedisExpire: TAction
      Caption = 'Set TTL...'
      Hint = 'Set key expiration'
      OnExecute = actRedisExpireExecute
    end
    object actRedisPersist: TAction
      Caption = 'Remove TTL'
      Hint = 'Remove key expiration'
      OnExecute = actRedisPersistExecute
    end
    object actRedisTTL: TAction
      Caption = 'View TTL'
      Hint = 'Show remaining TTL'
      OnExecute = actRedisTTLExecute
    end
    object actRedisNewKey: TAction
      Caption = 'New key...'
      Hint = 'Create new Redis key'
      OnExecute = actRedisNewKeyExecute
    end
```

- [ ] **Step 3: 实现 `popupDBPopup` 中的可见性门控**

在 `source/main.pas` 的 `popupDBPopup`（约 8070 行 `if PopupComponent(Sender) = DBtree then` 块内），在现有 `actDropObjects.Enabled` 之后，加：

```pascal
    // Redis 键操作菜单可见性
    actRedisRename.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis) and IsObject;
    actRedisExpire.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis) and IsObject;
    actRedisPersist.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis) and IsObject;
    actRedisTTL.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis) and IsObject;
    menuRedisCopyKeyName.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis) and IsObject;
    menuRedisNewKey.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis) and (IsDb or Obj.NodeType = lntNone);
    menuRedisSeparator.Visible := (Obj.Connection.Parameters.NetTypeGroup = ngRedis);
```

在 `else` 分支（ListTables 视图）也加隐藏：

```pascal
    actRedisRename.Visible := False;
    actRedisExpire.Visible := False;
    actRedisPersist.Visible := False;
    actRedisTTL.Visible := False;
    menuRedisCopyKeyName.Visible := False;
    menuRedisNewKey.Visible := False;
    menuRedisSeparator.Visible := False;
```

- [ ] **Step 4: 实现各操作的事件处理**

在 `source/main.pas` 实现区（`popupDBPopup` 之后），加：

```pascal
procedure TMainForm.actRedisRenameExecute(Sender: TObject);
var
  Obj: TDBObject;
  NewName, OldName: String;
  ExistsReply: TRedisValue;
  Conn: TRedisConnection;
begin
  Obj := ActiveDBObj;
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis) then Exit;
  OldName := Obj.Name;
  NewName := OldName;
  if not InputQuery(_('Rename key'), _('New key name:'), NewName) then Exit;
  if (NewName = '') or (NewName = OldName) then Exit;
  Conn := Obj.Connection as TRedisConnection;
  // 检查目标键是否已存在
  try
    ExistsReply := Conn.Client.Execute(['EXISTS', NewName]);
    try
      if (ExistsReply <> nil) and (ExistsReply.Kind = rkInteger) and (ExistsReply.Int > 0) then begin
        if MessageDialog(f_('Key "%s" already exists. Overwrite?', [NewName]),
          mtCriticalConfirmation, [mbOK, mbCancel]) <> mrOK then
          Exit;
      end;
    finally
      ExistsReply.Free;
    end;
    Conn.Client.Execute(['RENAME', OldName, NewName]).Free;
    // 更新树节点
    Obj.Name := NewName;
    InvalidateVT(DBtree, VTREE_NOTLOADED, True);
    Log(lcInfo, f_('Renamed key "%s" to "%s"', [OldName, NewName]));
  except
    on E: ERedisError do
      ErrorDialog(E.Message);
  end;
end;

procedure TMainForm.actRedisExpireExecute(Sender: TObject);
var
  Obj: TDBObject;
  SecondsStr: String;
  Seconds: Int64;
  Conn: TRedisConnection;
  Reply: TRedisValue;
begin
  Obj := ActiveDBObj;
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis) then Exit;
  SecondsStr := '3600';
  if not InputQuery(_('Set TTL'), _('Seconds (-1 = never expire):'), SecondsStr) then Exit;
  Seconds := StrToInt64Def(SecondsStr, -1);
  Conn := Obj.Connection as TRedisConnection;
  try
    if Seconds < 0 then begin
      Conn.Client.Execute(['PERSIST', Obj.Name]).Free;
      Log(lcInfo, f_('Removed TTL from key "%s"', [Obj.Name]));
    end else begin
      Reply := Conn.Client.Execute(['EXPIRE', Obj.Name, IntToStr(Seconds)]);
      try
        if (Reply <> nil) and (Reply.Kind = rkInteger) and (Reply.Int = 0) then
          ErrorDialog(f_('Key "%s" does not exist.', [Obj.Name]));
      finally
        Reply.Free;
      end;
      Log(lcInfo, f_('Set TTL %d on key "%s"', [Seconds, Obj.Name]));
    end;
  except
    on E: ERedisError do
      ErrorDialog(E.Message);
  end;
end;

procedure TMainForm.actRedisPersistExecute(Sender: TObject);
var
  Obj: TDBObject;
  Conn: TRedisConnection;
begin
  Obj := ActiveDBObj;
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis) then Exit;
  Conn := Obj.Connection as TRedisConnection;
  try
    Conn.Client.Execute(['PERSIST', Obj.Name]).Free;
    Log(lcInfo, f_('Removed TTL from key "%s"', [Obj.Name]));
  except
    on E: ERedisError do
      ErrorDialog(E.Message);
  end;
end;

procedure TMainForm.actRedisTTLExecute(Sender: TObject);
var
  Obj: TDBObject;
  Conn: TRedisConnection;
  Reply: TRedisValue;
  TtlVal: Int64;
  Msg: String;
begin
  Obj := ActiveDBObj;
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis) then Exit;
  Conn := Obj.Connection as TRedisConnection;
  try
    Reply := Conn.Client.Execute(['TTL', Obj.Name]);
    try
      if (Reply <> nil) and (Reply.Kind = rkInteger) then begin
        TtlVal := Reply.Int;
        case TtlVal of
          -1: Msg := f_('Key "%s" has no expiration.', [Obj.Name]);
          -2: Msg := f_('Key "%s" does not exist.', [Obj.Name]);
        else
          Msg := f_('Key "%s" TTL: %d seconds', [Obj.Name, TtlVal]);
        end;
        MessageDialog(Msg, mtInformation, [mbOK]);
      end;
    finally
      Reply.Free;
    end;
  except
    on E: ERedisError do
      ErrorDialog(E.Message);
  end;
end;

procedure TMainForm.menuRedisCopyKeyNameClick(Sender: TObject);
var
  Obj: TDBObject;
begin
  Obj := ActiveDBObj;
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis) then Exit;
  Clipboard.AsText := Obj.Name;
end;

procedure TMainForm.actRedisNewKeyExecute(Sender: TObject);
var
  Obj: TDBObject;
  Conn: TRedisConnection;
  Frm: TfrmRedisNewKey;
  KeyName, KeyType, InitialValue: String;
  Lines: TStringArray;
  i: Integer;
  SpacePos: Integer;
  Field, Val, Member, Score: String;
begin
  Obj := ActiveDBObj;
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis) then Exit;
  Conn := Obj.Connection as TRedisConnection;
  Frm := TfrmRedisNewKey.Create(Self);
  try
    Frm.SetConnection(Conn);
    if Frm.ShowModal <> mrOK then Exit;
    KeyName := Frm.GetKeyName;
    KeyType := Frm.GetKeyType;
    InitialValue := Frm.GetInitialValue;
    try
      case KeyType of
        'string': begin
          Conn.Client.Execute(['SET', KeyName, InitialValue]).Free;
        end;
        'hash': begin
          Lines := InitialValue.Split([#13#10, #10]);
          for i := 0 to High(Lines) do begin
            if Trim(Lines[i]) = '' then Continue;
            SpacePos := Pos(' ', Lines[i]);
            if SpacePos > 0 then begin
              Field := Trim(Copy(Lines[i], 1, SpacePos - 1));
              Val := Trim(Copy(Lines[i], SpacePos + 1));
            end else begin
              Field := Trim(Lines[i]);
              Val := '';
            end;
            Conn.Client.Execute(['HSET', KeyName, Field, Val]).Free;
          end;
        end;
        'list': begin
          Lines := InitialValue.Split([#13#10, #10]);
          for i := 0 to High(Lines) do begin
            if Trim(Lines[i]) = '' then Continue;
            Conn.Client.Execute(['RPUSH', KeyName, Lines[i]]).Free;
          end;
        end;
        'set': begin
          Lines := InitialValue.Split([#13#10, #10]);
          for i := 0 to High(Lines) do begin
            if Trim(Lines[i]) = '' then Continue;
            Conn.Client.Execute(['SADD', KeyName, Lines[i]]).Free;
          end;
        end;
        'zset': begin
          Lines := InitialValue.Split([#13#10, #10]);
          for i := 0 to High(Lines) do begin
            if Trim(Lines[i]) = '' then Continue;
            SpacePos := Pos(' ', Lines[i]);
            if SpacePos > 0 then begin
              Member := Trim(Copy(Lines[i], 1, SpacePos - 1));
              Score := Trim(Copy(Lines[i], SpacePos + 1));
            end else begin
              Member := Trim(Lines[i]);
              Score := '0';
            end;
            Conn.Client.Execute(['ZADD', KeyName, Score, Member]).Free;
          end;
        end;
      end;
      // 刷新键树
      InvalidateVT(DBtree, VTREE_NOTLOADED, True);
      Log(lcInfo, f_('Created new %s key "%s"', [KeyType, KeyName]));
    except
      on E: ERedisError do
        ErrorDialog(E.Message);
    end;
  finally
    Frm.Free;
  end;
end;
```

- [ ] **Step 5: 在 `main.pas` implementation uses 中加 `redis_newkey`**

在 `source/main.pas` 的 implementation `uses` 子句中加 `redis_newkey`。

- [ ] **Step 6: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 7: Commit**

```bash
git add source/main.pas source/main.lfm
git commit -m "feat: Redis 键右键菜单 — 重命名/设TTL/取消TTL/查看TTL/复制键名/新建键

右键键节点弹菜单：
- 删除键（复用 actDropObjects，Drop 重写后自动发 DEL）
- 重命名键（RENAME，保存前 EXISTS 检查覆盖）
- 设置 TTL（EXPIRE，-1 触发 PERSIST）
- 取消 TTL（PERSIST）
- 查看 TTL（TTL，-1=永不过期，-2=不存在）
- 复制键名（剪贴板）
- 新建键（弹 TfrmRedisNewKey 对话框）"
```

---

## Task 10: 数据网格信息栏 — TYPE/SIZE/TTL/MEMORY USAGE

在数据网格上方加信息栏面板，显示选中键的元信息。

**Files:**
- Modify: `source/main.pas`（声明区 + `DBtreeFocusChanged` / 数据加载逻辑）
- Modify: `source/main.lfm`（`tabData` 中加 `pnlRedisInfo`）

**Interfaces:**
- Consumes: `TRedisConnection.Client`

- [ ] **Step 1: 在 `main.lfm` 的 `tabData` 中加信息栏**

在 `source/main.lfm` 的 `tabData`（约 2155 行）中，在 `pnlDataTop` 之后、`DataGrid` 之前，加：

```lfm
          object pnlRedisInfo: TPanel
            Left = 0
            Height = 20
            Top = 26
            Width = 615
            Align = alTop
            Alignment = taLeftJustify
            BevelOuter = bvNone
            BorderWidth = 2
            TabOrder = 5
            Visible = False
            object lblRedisInfo: TLabel
              Left = 4
              Height = 16
              Top = 2
              Width = 100
              Caption = ''
            end
          end
```

- [ ] **Step 2: 在 `main.pas` 声明区加控件引用**

在 `TMainForm` 的控件声明区（约 510 行附近 `pnlDataTop` 后），加：

```pascal
    pnlRedisInfo: TPanel;
    lblRedisInfo: TLabel;
```

- [ ] **Step 3: 实现信息栏更新方法**

在 `source/main.pas` 实现区，加一个私有方法（先在声明区加 `procedure UpdateRedisInfoBar(Obj: TDBObject);`）：

```pascal
procedure TMainForm.UpdateRedisInfoBar(Obj: TDBObject);
var
  Conn: TRedisConnection;
  TypeReply, TtlReply, SizeReply, MemReply: TRedisValue;
  KeyType, InfoText: String;
  TtlVal: Int64;
  SizeVal: Int64;
  MemVal: Int64;
begin
  if (Obj = nil) or (Obj.Connection.Parameters.NetTypeGroup <> ngRedis)
    or (Obj.NodeType <> lntTable) then begin
    pnlRedisInfo.Visible := False;
    Exit;
  end;
  Conn := Obj.Connection as TRedisConnection;
  pnlRedisInfo.Visible := True;
  InfoText := '';
  try
    // TYPE
    TypeReply := Conn.Client.Execute(['TYPE', Obj.Name]);
    try
      if (TypeReply <> nil) and (TypeReply.Kind in [rkString, rkBulk]) then
        KeyType := TypeReply.Str
      else
        KeyType := 'unknown';
      InfoText := 'TYPE: ' + KeyType;
    finally
      TypeReply.Free;
    end;

    // SIZE (按类型)
    SizeVal := 0;
    if KeyType = 'string' then
      SizeReply := Conn.Client.Execute(['STRLEN', Obj.Name])
    else if KeyType = 'hash' then
      SizeReply := Conn.Client.Execute(['HLEN', Obj.Name])
    else if KeyType = 'list' then
      SizeReply := Conn.Client.Execute(['LLEN', Obj.Name])
    else if KeyType = 'set' then
      SizeReply := Conn.Client.Execute(['SCARD', Obj.Name])
    else if KeyType = 'zset' then
      SizeReply := Conn.Client.Execute(['ZCARD', Obj.Name])
    else
      SizeReply := nil;
    if SizeReply <> nil then begin
      try
        if (SizeReply <> nil) and (SizeReply.Kind = rkInteger) then
          SizeVal := SizeReply.Int;
      finally
        SizeReply.Free;
      end;
    end;
    InfoText := InfoText + ' | SIZE: ' + IntToStr(SizeVal);

    // TTL
    TtlReply := Conn.Client.Execute(['TTL', Obj.Name]);
    try
      if (TtlReply <> nil) and (TtlReply.Kind = rkInteger) then begin
        TtlVal := TtlReply.Int;
        if TtlVal = -1 then
          InfoText := InfoText + ' | TTL: ' + _('never expires')
        else if TtlVal = -2 then
          InfoText := InfoText + ' | TTL: ' + _('key not found')
        else
          InfoText := InfoText + ' | TTL: ' + IntToStr(TtlVal) + 's';
      end;
    finally
      TtlReply.Free;
    end;

    // MEMORY USAGE (Redis 4.0+)
    try
      MemReply := Conn.Client.Execute(['MEMORY', 'USAGE', Obj.Name]);
      try
        if (MemReply <> nil) and (MemReply.Kind = rkInteger) then
          InfoText := InfoText + ' | MEMORY: ' + FormatNumber(MemReply.Int)
        else
          InfoText := InfoText + ' | MEMORY: N/A';
      finally
        MemReply.Free;
      end;
    except
      InfoText := InfoText + ' | MEMORY: N/A';
    end;

    lblRedisInfo.Caption := InfoText;
  except
    on E: ERedisError do
      lblRedisInfo.Caption := _('Error: ') + E.Message;
  end;
end;
```

- [ ] **Step 4: 在键选中时调用信息栏更新**

在 `source/main.pas` 的 `DBtreeFocusChanged` 中，当选中 Redis 键节点时调用。找到设置 `tabData.TabVisible` 的位置（约 10225 行），在其后加：

```pascal
    if (FActiveDbObj.Connection.Parameters.NetTypeGroup = ngRedis)
      and (FActiveDbObj.NodeType = lntTable) then
      UpdateRedisInfoBar(FActiveDbObj)
    else
      pnlRedisInfo.Visible := False;
```

- [ ] **Step 5: 编译验证**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -5`
Expected: 编译成功

- [ ] **Step 6: Commit**

```bash
git add source/main.pas source/main.lfm
git commit -m "feat: Redis 数据网格信息栏 — TYPE/SIZE/TTL/MEMORY USAGE

选中 Redis 键时在数据网格上方显示信息栏：
TYPE | SIZE | TTL | MEMORY USAGE
TTL=-1 显示'永不过期'，-2 显示'键不存在'
MEMORY USAGE 不可用(Redis<4.0)时显示 N/A"
```

---

## Task 11: 协议测试扩展 — 命令序列化测试

在 `tests/test_redis_proto.lpr` 中加命令序列化测试，验证编辑路径发出的命令参数编码正确。

**Files:**
- Modify: `tests/test_redis_proto.lpr`

- [ ] **Step 1: 加命令序列化测试**

在 `tests/test_redis_proto.lpr` 末尾，加：

```pascal
procedure TestCommandSerialization;
var
  Data: TBytes;
  Expected: RawByteString;
begin
  // SET key value
  Data := RedisSerializeCommand(['SET', 'mykey', 'myvalue']);
  Expected := '*3'#13#10'$3'#13#10'SET'#13#10'$5'#13#10'mykey'#13#10'$7'#13#10'myvalue'#13#10;
  Assert(BytesToString(Data) = Expected, 'SET serialization failed');

  // HSET key field value
  Data := RedisSerializeCommand(['HSET', 'myhash', 'f1', 'v1']);
  Expected := '*4'#13#10'$4'#13#10'HSET'#13#10'$6'#13#10'myhash'#13#10'$2'#13#10'f1'#13#10'$2'#13#10'v1'#13#10;
  Assert(BytesToString(Data) = Expected, 'HSET serialization failed');

  // ZADD key score member
  Data := RedisSerializeCommand(['ZADD', 'myzset', '3.14', 'm1']);
  Expected := '*4'#13#10'$4'#13#10'ZADD'#13#10'$6'#13#10'myzset'#13#10'$4'#13#10'3.14'#13#10'$2'#13#10'm1'#13#10;
  Assert(BytesToString(Data) = Expected, 'ZADD serialization failed');

  // UTF-8 键名
  Data := RedisSerializeCommand(['SET', '键', '值']);
  // UTF-8: 键 = 3 bytes, 值 = 3 bytes
  Expected := '*3'#13#10'$3'#13#10'SET'#13#10'$' + IntToStr(Length(UTF8Encode('键'))) + #13#10 + UTF8Encode('键') + #13#10'$' + IntToStr(Length(UTF8Encode('值'))) + #13#10 + UTF8Encode('值') + #13#10;
  Assert(BytesToString(Data) = Expected, 'UTF-8 key serialization failed');

  Writeln('  TestCommandSerialization: OK');
end;
```

在 `main` 中调用 `TestCommandSerialization;`。

注意：`BytesToString` 需要一个辅助函数。如果项目中没有，用 `SetString` 转换：

```pascal
function BytesToString(const Data: TBytes): RawByteString;
begin
  if Length(Data) = 0 then
    Result := ''
  else begin
    SetLength(Result, Length(Data));
    Move(Data[0], Result[1], Length(Data));
  end;
end;
```

- [ ] **Step 2: 运行测试**

Run: `cd /data/projects_local/pascal/HeidiSQL/tests && fpc test_redis_proto.lpr && ./test_redis_proto`
Expected: 所有测试通过，输出 `TestCommandSerialization: OK`

- [ ] **Step 3: Commit**

```bash
git add tests/test_redis_proto.lpr
git commit -m "test: 扩展 Redis 协议测试 — 命令序列化

新增 TestCommandSerialization 验证 SET/HSET/ZADD 命令的 RESP 序列化，
包括 UTF-8 键名编码正确性。"
```

---

## Task 12: 全量编译验证 + 冒烟测试清单

最终全量编译，确保无回归，并记录手动冒烟测试清单。

**Files:**
- Create: `docs/redis-editing-smoke-test.md`

- [ ] **Step 1: 全量编译**

Run: `cd /data/projects_local/pascal/HeidiSQL && make build-qt6 2>&1 | tail -10`
Expected: 编译成功，无新警告

- [ ] **Step 2: 运行协议测试**

Run: `cd /data/projects_local/pascal/HeidiSQL/tests && ./test_redis_proto`
Expected: 所有测试通过

- [ ] **Step 3: 编写冒烟测试清单**

创建 `docs/redis-editing-smoke-test.md`：

```markdown
# Redis 编辑能力冒烟测试清单

需 `redis:7` docker 实例。

## 值编辑
- [ ] string: 双击 value 单元格 → 改值 → Apply → 验证 `GET key` 返回新值
- [ ] hash: 双击 value 单元格 → 改值 → Apply → 验证 `HGET key field` 返回新值
- [ ] hash: 改 field 名 → Apply → 验证旧 field 已删、新 field 存在
- [ ] list: 双击 value → 改值 → Apply → 验证 `LINDEX key idx` 返回新值
- [ ] zset: 改 score → Apply → 验证 `ZSCORE key member` 返回新 score
- [ ] zset: 改 member 名 → Apply → 验证旧 member 已删、新 member 存在

## 增删行
- [ ] hash: Insert 键 → 输入 field+value → Apply → 验证 `HLEN` +1
- [ ] hash: Delete 行 → Apply → 验证 `HLEN` -1
- [ ] list: Insert 行 → 输入 value → Apply → 验证 `LLEN` +1
- [ ] list: Delete 行（含重复值）→ 验证只删目标行（tombstone 方案）
- [ ] set: Insert 行 → 输入 member → Apply → 验证 `SCARD` +1
- [ ] set: Delete 行 → Apply → 验证 `SCARD` -1
- [ ] zset: Insert 行 → 输入 member+score → Apply → 验证 `ZCARD` +1
- [ ] zset: Delete 行 → Apply → 验证 `ZCARD` -1

## 键操作
- [ ] 删除键 → 右键 → 删除 → 确认 → 验证键不存在
- [ ] 重命名键 → 右键 → 重命名 → 输入新名 → 验证旧名不存在、新名存在
- [ ] 重命名键（目标已存在）→ 确认覆盖 → 验证
- [ ] 设置 TTL → 右键 → 设TTL → 输入秒数 → 验证 `TTL` 返回正数
- [ ] 设置 TTL = -1 → 验证触发 PERSIST → `TTL` 返回 -1
- [ ] 取消 TTL → 右键 → 取消TTL → 验证 `TTL` 返回 -1
- [ ] 查看 TTL → 右键 → 查看TTL → 弹窗显示秒数
- [ ] 复制键名 → 右键 → 复制 → 粘贴验证

## 新建键
- [ ] 新建 string 键 → 输入名+类型+值 → 确定 → 验证键存在
- [ ] 新建 hash 键 → 多行 field value → 确定 → 验证 `HLEN` 正确
- [ ] 新建 list 键 → 多行元素 → 确定 → 验证 `LLEN` 正确
- [ ] 新建 set 键 → 多行 member → 确定 → 验证 `SCARD` 正确
- [ ] 新建 zset 键 → 多行 member score → 确定 → 验证 `ZCARD` 正确

## UI
- [ ] 选中 Redis 键 → 信息栏显示 TYPE/SIZE/TTL/MEMORY
- [ ] 选中 Redis 键 → tabEditor 隐藏
- [ ] 选中 Redis 键 → 网格键列不可编辑（双击无反应）
- [ ] 大值编辑（>100KB string）→ 懒加载不覆盖用户编辑

## 错误处理
- [ ] 编辑时键被其他客户端删除 → 提示刷新
- [ ] 键类型已变（WRONGTYPE）→ 提示刷新
```

- [ ] **Step 4: Commit**

```bash
git add docs/redis-editing-smoke-test.md
git commit -m "docs: Redis 编辑能力冒烟测试清单

覆盖值编辑、增删行、键操作、新建键、UI、错误处理的手动验证清单。"
```

---

## Self-Review

### Spec 覆盖检查

| Spec 要求 | 覆盖 Task |
|---|---|
| 修复 Drop 删除（§3.2） | Task 2 |
| 网格内编辑值（§3.5） | Task 4 |
| CheckEditable 重写（§3.3） | Task 3 |
| GetKeyColumns 重写（§3.4） | Task 3 |
| SaveModifications 重写（§3.5） | Task 4 |
| DeleteRow 重写（§3.5） | Task 4 |
| InsertRow 重写（§3.5） | Task 4 |
| EnsureFullRow 重写（§3.6） | Task 4 |
| 保存后本地数据同步（§3.7） | Task 4（SaveModifications 内更新 FReply） |
| 键操作右键菜单（§4.1） | Task 9 |
| 新建键对话框（§4.3） | Task 8 + Task 9 |
| 键树刷新（§4.4） | Task 9（InvalidateVT） |
| 信息栏（§5.1） | Task 10 |
| 隐藏 tabEditor（§5.2） | Task 6 |
| 网格列可编辑性（§5.3） | Task 2 + Task 5 |
| 文本编辑器保存路径（§5.4） | Task 7（懒加载冲突修复） |
| 错误处理（§6） | Task 4 + Task 9（try/except） |
| 测试（§7） | Task 11 + Task 12 |

### 占位符扫描
无 TBD/TODO/占位符。

### 类型一致性
- `TRedisQuery.ColIsKeyPart` 在 Task 2 定义，Task 5 使用 ✓
- `TfrmRedisNewKey.SetConnection/GetKeyName/GetKeyType/GetInitialValue` 在 Task 8 定义，Task 9 使用 ✓
- `UpdateRedisInfoBar` 在 Task 10 定义并调用 ✓
- `TRedisConnection.Drop` 在 Task 2 定义，Task 9 的删除键复用 `actDropObjects` 自动生效 ✓
