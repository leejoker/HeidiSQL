# Redis 支持 — 阶段 1 实现计划（RESP 协议客户端 + 测试程序）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现纯 Pascal 的 Redis RESP2/RESP3 协议客户端 `redisclient.pas`（解析、序列化、纯 TCP 传输、鉴权、HELLO 协商、SELECT），并用一个独立控制台测试程序以 TDD 方式验证解析与序列化层。

**Architecture:** 协议层与传输层分离以支持 TDD。`TRedisReader` 从一个 `TRedisByteSource`（抽象字节源）读取——测试用 `TRedisMemorySource`（内存 TBytes），生产用 `TRedisSocketSource`（基于 FPC `Sockets` 单元的缓冲 recv）。`RedisSerializeCommand` 把命令参数序列化为 RESP 字节数组。`TRedisClient` 编排 reader+writer+socket，负责 Connect/Authenticate/SelectDb/Execute/Ping/Disconnect。

**Tech Stack:** Free Pascal 3.2.2（`{$mode delphi}{$H+}`）、FPC `Sockets` 单元（TCP）、FPC `Classes`/`SysUtils`。无 LCL 依赖（本阶段）。无第三方库。

## Global Constraints

- 编译器: `/data/fpc_tools/fpc/bin/x86_64-linux/fpc`，Delphi 模式：每个 `.pas`/`.lpr` 文件首行必须 `{$mode delphi}{$H+}`。
- **FPC 3.2.2 不支持内联变量声明**（`var x := ...` 必须在块顶声明）。所有变量在 `var` 区声明。
- 源单元扁平放在 `source/` 下，文件名 = 单元名（项目约定，见 AGENTS.md §2）。
- 测试程序放在 `tests/`，为独立控制台程序（`.lpr`），不引入 FPCUnit（spec §8 决策）。
- 不提交编译产物（`.ppu`/`.o`/二进制）；已在 `.gitignore` 中，但需为测试二进制补条目。
- 命令序列化按 UTF-8 **字节**长度计算 RESP bulk 长度（正确处理多字节字符）。
- 错误统一抛 `ERedisError`（本阶段本地定义；阶段 2 集成 `TDBConnection` 时再映射为 `EDbError`，避免本阶段依赖巨型 `dbconnection.pas`）。
- FPC `Sockets` 单元 API：`fpSocket`/`fpConnect`/`fpSend`/`fpRecv`/`fpCloseSocket`、`htons`、`StrToHostAddr`（返回 `TInAddr`，赋给 `sin.sin_addr`）、`sockaddr_in`（字段 `sin_family`/`sin_port`/`sin_addr`）。**注意是 `StrToHostAddr`，不是 `StrToNetHost`。**
- `TBytesStream.Bytes` 返回容量缓冲（非已写长度）；序列化结果须用 `bs.Size` 截取。

---

## 文件结构

| 文件 | 职责 | 阶段 |
|---|---|---|
| `source/redisclient.pas` | RESP2/RESP3 协议客户端：类型、序列化、解析、字节源、传输、`TRedisClient` | 本阶段创建 |
| `tests/test_redis_proto.lpr` | 独立控制台测试程序：断言序列化与解析层，无真实 Redis 依赖 | 本阶段创建 |
| `.gitignore` | 补测试二进制忽略条目 | 本阶段修改 |

`redisclient.pas` 内部分区（同一文件，但职责边界清晰）：
1. **类型** — `TRedisReplyKind`、`TRedisValue`（class，自管理子项）
2. **序列化** — `RedisSerializeCommand(Args): TBytes`
3. **字节源** — `TRedisByteSource`（抽象）、`TRedisMemorySource`（测试）、`TRedisSocketSource`（生产）
4. **解析** — `TRedisReader.ReadReply: TRedisValue`
5. **客户端** — `TRedisClient`（Connect/Authenticate/SelectDb/Execute/Ping/Disconnect）
6. **错误** — `ERedisError`

---

## Task 1: 脚手架 — 类型、测试程序骨架、gitignore

**Files:**
- Create: `source/redisclient.pas`
- Create: `tests/test_redis_proto.lpr`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `ERedisError`（`class(Exception)`）、`TRedisReplyKind` 枚举、`TRedisValue` 类（`Kind`/`Str`/`Int`/`Dbl`/`VerbatimFormat`/`Items` 字段，自管理子项）。后续任务的测试与实现都引用这些。

- [ ] **Step 1: 创建 `source/redisclient.pas` 骨架（仅类型 + 错误类）**

```pascal
unit redisclient;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils;

type
  ERedisError = class(Exception);

  TRedisReplyKind = (
    rkString,      // RESP2/3 "+"
    rkError,       // "-"
    rkInteger,     // ":"
    rkBulk,        // "$"
    rkArray,       // "*"
    rkMap,         // RESP3 "%"
    rkSet,         // RESP3 "~"
    rkPush,        // RESP3 ">"
    rkDouble,      // RESP3 ","
    rkBigNumber,   // RESP3 "("
    rkVerbatim,    // RESP3 "="
    rkBoolean,     // RESP3 "#"
    rkNull         // RESP2 nil ($-1/*-1) 或 RESP3 "_"
  );

  { TRedisValue — 一个解析后的回复。自管理其子项（array/map/set/push）。
    标量: Kind + Str/Int/Dbl。聚合: Kind + Items。 }
  TRedisValue = class
  public
    Kind: TRedisReplyKind;
    Str: string;                 // rkString/rkBulk/rkError/rkVerbatim/rkBigNumber 文本
    Int: Int64;                  // rkInteger 值；rkBoolean 0/1
    Dbl: Double;                 // rkDouble 值
    VerbatimFormat: string;      // rkVerbatim 的 3 字节子类型（如 "txt"/"mkd"）
    Items: array of TRedisValue; // rkArray/rkMap/rkSet/rkPush 子项
    constructor Create(AKind: TRedisReplyKind);
    destructor Destroy; override;
  end;

implementation

{ TRedisValue }

constructor TRedisValue.Create(AKind: TRedisReplyKind);
begin
  inherited Create;
  Kind := AKind;
end;

destructor TRedisValue.Destroy;
var
  i: Integer;
begin
  for i := 0 to High(Items) do
    Items[i].Free;
  inherited Destroy;
end;

end.
```

- [ ] **Step 2: 创建 `tests/test_redis_proto.lpr` 骨架（空测试，验证工具链）**

```pascal
program test_redis_proto;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  SysUtils, Classes,
  redisclient;  // 单元在 source/，编译时用 -Fusource

var
  Pass, Fail: Integer;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then begin
    Inc(Pass);
    writeln('  PASS: ', Name);
  end else begin
    Inc(Fail);
    writeln('  FAIL: ', Name);
  end;
end;

function Bytes(const s: string): TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(s);
end;

begin
  Pass := 0;
  Fail := 0;
  writeln('=== redisclient protocol tests ===');

  // 占位：后续任务在此添加断言
  Check('unit loads', True);

  writeln;
  writeln(Format('=== %d passed, %d failed ===', [Pass, Fail]));
  if Fail > 0 then
    Halt(1);
end.
```

- [ ] **Step 3: 补 `.gitignore` 忽略测试二进制与编译产物**

在 `.gitignore` 的 `# Others` 段之前追加：

```
# Redis protocol test program (standalone console)
/tests/test_redis_proto
/tests/_probe
/tests/_smoke
/tests/*.ppu
/tests/*.o
/tests/*.compiled
```

- [ ] **Step 4: 编译并运行测试程序，验证工具链与单元加载**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -5
./tests/test_redis_proto
```
Expected: 编译成功（0 errors），运行输出 `PASS: unit loads` 与 `1 passed, 0 failed`，退出码 0。

- [ ] **Step 5: Commit**

```bash
git add source/redisclient.pas tests/test_redis_proto.lpr .gitignore
git commit -m "feat(redis): scaffold redisclient unit and protocol test harness

- Add source/redisclient.pas with TRedisReplyKind, TRedisValue class
  (self-managing children) and ERedisError
- Add tests/test_redis_proto.lpr console test harness (no FPCUnit)
- Ignore test binaries/units in .gitignore"
```

---

## Task 2: 命令序列化 — `RedisSerializeCommand`

**Files:**
- Modify: `source/redisclient.pas`
- Modify: `tests/test_redis_proto.lpr`

**Interfaces:**
- Produces: `function RedisSerializeCommand(const Args: array of string): TBytes;` — 把命令参数序列化为 RESP 数组格式字节（`*N\r\n$len\r\nbytes\r\n...`）。bulk 长度按 UTF-8 字节计数。

- [ ] **Step 1: 在 `redisclient.pas` interface 区添加函数声明**

在 `TRedisValue` 类定义之后、`implementation` 之前添加：
```pascal
{ Serialize a command (array of string args) into RESP array bytes: *N CRLF $len CRLF bytes CRLF ... }
function RedisSerializeCommand(const Args: array of string): TBytes;
```

- [ ] **Step 2: 在 `redisclient.pas` implementation 区添加函数体**

在 `TRedisValue` 方法实现之后添加：
```pascal
function RedisSerializeCommand(const Args: array of string): TBytes;
var
  bs: TBytesStream;
  i: Integer;
  b: RawByteString;
  procedure W(const s: RawByteString);
  begin
    if s <> '' then
      bs.Write(s[1], Length(s));
  end;
begin
  bs := TBytesStream.Create;
  try
    W('*' + IntToStr(Length(Args)) + #13#10);
    for i := 0 to High(Args) do begin
      b := UTF8Encode(Args[i]);      // 正确的 UTF-8 字节长度
      W('$' + IntToStr(Length(b)) + #13#10);
      W(b);
      W(#13#10);
    end;
    // 注意: TBytesStream.Bytes 是容量缓冲，须用 Size 截取实际写入长度
    SetLength(Result, bs.Size);
    if bs.Size > 0 then
      Move(bs.Bytes[0], Result[0], bs.Size);
  finally
    bs.Free;
  end;
end;
```

- [ ] **Step 3: 在测试程序添加序列化断言**

在 `tests/test_redis_proto.lpr` 中，`Check`/`Bytes` 过程声明之后、`begin` 之前无需改动；在 `begin` 块内、占位 `Check('unit loads'...)` 之后添加。需在主 `var` 区（`Pass, Fail` 下方）补充测试变量。先把主 `var` 区改为：
```pascal
var
  Pass, Fail: Integer;
  got: TBytes;
  s: string;
```
然后在 `begin` 块内 `Check('unit loads', True);` 之后添加：
```pascal
  // --- Task 2: RedisSerializeCommand ---
  got := RedisSerializeCommand(['GET', 'foo']);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize GET foo', s = '*2' + #13#10 + '$3' + #13#10 + 'GET' + #13#10 + '$3' + #13#10 + 'foo' + #13#10);

  got := RedisSerializeCommand(['SET', 'k', 'v']);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize SET k v', s = '*3' + #13#10 + '$3' + #13#10 + 'SET' + #13#10 + '$1' + #13#10 + 'k' + #13#10 + '$1' + #13#10 + 'v' + #13#10);

  // 多字节: "café" = 5 UTF-8 字节，bulk 长度应为 $5
  got := RedisSerializeCommand(['SET', 'name', 'café']);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize multibyte value byte-length', Pos('$5' + #13#10, s) > 0);

  got := RedisSerializeCommand([]);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize empty command', s = '*0' + #13#10);
```

- [ ] **Step 4: 编译并运行，确认测试通过**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -5
./tests/test_redis_proto
```
Expected: 4 个序列化断言 PASS，0 failed。

- [ ] **Step 5: Commit**

```bash
git add source/redisclient.pas tests/test_redis_proto.lpr
git commit -m "feat(redis): add RedisSerializeCommand with UTF-8 byte-length

Serializes string args into RESP array format (*N CRLF \$len CRLF bytes
CRLF ...). Bulk length computed from UTF-8 byte count via UTF8Encode,
not char count, so multibyte values are framed correctly. Result sized
via TBytesStream.Size (not .Bytes capacity)."
```

---

## Task 3: RESP2 解析 — 字节源、内存源、`TRedisReader.ReadReply`

**Files:**
- Modify: `source/redisclient.pas`
- Modify: `tests/test_redis_proto.lpr`

**Interfaces:**
- Produces:
  - `TRedisByteSource`（抽象，`function ReadByte: Byte; virtual; abstract;`，`function ReadExact(Count: Integer): RawByteString; virtual;`，`function ReadLine: RawByteString; virtual;`）
  - `TRedisMemorySource`（测试用，构造接收 `TBytes`，`ReadByte` 顺序返回并在耗尽时抛 `ERedisError`）
  - `TRedisReader`：`constructor Create(ASource: TRedisByteSource; AProtocol: Integer);`、`function ReadReply: TRedisValue;`、`property Protocol: Integer`（2 或 3）。RESP2 模式解析 `+`/`-`/`:`/`$`/`*` 及 `$-1`/`*-1` nil；遇未知字节抛 `ERedisError`。

- [ ] **Step 1: 在 `redisclient.pas` interface 区添加字节源与 reader 声明**

在 `RedisSerializeCommand` 声明之后添加：
```pascal
  { TRedisByteSource — 抽象前向字节源。ReadByte 阻塞直到返回 1 字节或抛错。 }
  TRedisByteSource = class
  public
    function ReadByte: Byte; virtual; abstract;
    function ReadExact(Count: Integer): RawByteString; virtual;
    function ReadLine: RawByteString; virtual;
  end;

  { TRedisMemorySource — 测试用，从内存 TBytes 顺序读取。 }
  TRedisMemorySource = class(TRedisByteSource)
  private
    FData: TBytes;
    FPos: Integer;
  public
    constructor Create(const AData: TBytes);
    function ReadByte: Byte; override;
  end;

  { TRedisReader — RESP 解析器。从字节源读取，返回 TRedisValue。
    Protocol=2 仅解析 RESP2 类型；Protocol=3 额外解析 RESP3 新类型（Task 4）。 }
  TRedisReader = class
  private
    FSource: TRedisByteSource;
    FProtocol: Integer;
    function ReadLine: RawByteString;
    function ReadBulk(Count: Integer): string;
    function ParseReply: TRedisValue;
  public
    constructor Create(ASource: TRedisByteSource; AProtocol: Integer);
    function ReadReply: TRedisValue;
    property Protocol: Integer read FProtocol write FProtocol;
  end;
```

- [ ] **Step 2: 在 implementation 区添加字节源与 reader 实现**

在 `RedisSerializeCommand` 实现之后添加：
```pascal
{ TRedisByteSource }

function TRedisByteSource.ReadExact(Count: Integer): RawByteString;
var
  i: Integer;
begin
  SetLength(Result, Count);
  for i := 0 to Count - 1 do
    Result[i + 1] := AnsiChar(ReadByte);
end;

function TRedisByteSource.ReadLine: RawByteString;
var
  b: Byte;
begin
  Result := '';
  repeat
    b := ReadByte;
    if b = 13 then begin       // CR；下一字节应为 LF
      ReadByte;                // 丢弃 LF
      Break;
    end;
    Result := Result + AnsiChar(b);
  until False;
end;

{ TRedisMemorySource }

constructor TRedisMemorySource.Create(const AData: TBytes);
begin
  inherited Create;
  FData := AData;
  FPos := 0;
end;

function TRedisMemorySource.ReadByte: Byte;
begin
  if FPos >= Length(FData) then
    raise ERedisError.Create('TRedisMemorySource: end of data');
  Result := FData[FPos];
  Inc(FPos);
end;

{ TRedisReader }

constructor TRedisReader.Create(ASource: TRedisByteSource; AProtocol: Integer);
begin
  inherited Create;
  FSource := ASource;
  FProtocol := AProtocol;
end;

function TRedisReader.ReadLine: RawByteString;
begin
  Result := FSource.ReadLine;
end;

function TRedisReader.ReadBulk(Count: Integer): string;
var
  raw: RawByteString;
begin
  raw := FSource.ReadExact(Count);
  Result := UTF8ToString(raw);
  FSource.ReadByte;  // CR
  FSource.ReadByte;  // LF
end;

function TRedisReader.ParseReply: TRedisValue;
var
  b: Byte;
  line: RawByteString;
  count, i: Integer;
begin
  b := FSource.ReadByte;
  case AnsiChar(b) of
    '+': begin
      Result := TRedisValue.Create(rkString);
      Result.Str := UTF8ToString(ReadLine);
    end;
    '-': begin
      Result := TRedisValue.Create(rkError);
      Result.Str := UTF8ToString(ReadLine);
    end;
    ':': begin
      Result := TRedisValue.Create(rkInteger);
      Result.Int := StrToInt64Def(Trim(UTF8ToString(ReadLine)), 0);
    end;
    '$': begin
      line := Trim(ReadLine);
      if line = '-1' then
        Result := TRedisValue.Create(rkNull)
      else begin
        count := StrToIntDef(line, 0);
        Result := TRedisValue.Create(rkBulk);
        Result.Str := ReadBulk(count);
      end;
    end;
    '*': begin
      line := Trim(ReadLine);
      if line = '-1' then
        Result := TRedisValue.Create(rkNull)
      else begin
        count := StrToIntDef(line, 0);
        Result := TRedisValue.Create(rkArray);
        SetLength(Result.Items, count);
        for i := 0 to count - 1 do
          Result.Items[i] := ParseReply;  // 递归
      end;
    end;
    else
      raise ERedisError.CreateFmt('Unexpected reply byte: #%d (%s)', [b, AnsiChar(b)]);
  end;
end;

function TRedisReader.ReadReply: TRedisValue;
begin
  Result := ParseReply;
end;
```

- [ ] **Step 3: 在测试程序添加 RESP2 解析断言**

在 `tests/test_redis_proto.lpr` 中，`Bytes` 函数声明之后、主 `var` 之前添加两个辅助过程（声明在主 `var` 之前；它们引用全局 `Check`）：
```pascal
procedure CheckReply(const Name: string; const Data: TBytes; ExpectedKind: TRedisReplyKind;
  const ExpectedStr: string; ExpectedInt: Int64 = 0);
var
  src: TRedisMemorySource;
  rdr: TRedisReader;
  v: TRedisValue;
begin
  src := TRedisMemorySource.Create(Data);
  rdr := TRedisReader.Create(src, 2);
  try
    v := rdr.ReadReply;
    try
      Check(Name + ' kind', v.Kind = ExpectedKind);
      if ExpectedStr <> '' then Check(Name + ' str', v.Str = ExpectedStr);
      if ExpectedKind = rkInteger then Check(Name + ' int', v.Int = ExpectedInt);
    finally
      v.Free;
    end;
  finally
    rdr.Free;
    src.Free;
  end;
end;
```
在主 `var` 区补充数组测试所需变量，使其变为：
```pascal
var
  Pass, Fail: Integer;
  got: TBytes;
  s: string;
  src0: TRedisMemorySource;
  rdr0: TRedisReader;
  v0: TRedisValue;
  arrSrc: TRedisMemorySource;
  arrRdr: TRedisReader;
  arrV: TRedisValue;
```
在 `begin` 块内 Task 2 断言之后添加：
```pascal
  // --- Task 3: RESP2 解析 ---
  CheckReply('simple string', Bytes('+OK' + #13#10), rkString, 'OK');
  CheckReply('error', Bytes('-ERR boom' + #13#10), rkError, 'boom');
  CheckReply('integer', Bytes(':42' + #13#10), rkInteger, '', 42);
  CheckReply('integer zero', Bytes(':0' + #13#10), rkInteger, '', 0);
  CheckReply('integer negative', Bytes(':-1' + #13#10), rkInteger, '', -1);
  CheckReply('bulk', Bytes('$3' + #13#10 + 'foo' + #13#10), rkBulk, 'foo');
  CheckReply('empty bulk', Bytes('$0' + #13#10 + #13#10), rkBulk, '');
  CheckReply('nil bulk', Bytes('$-1' + #13#10), rkNull, '');

  // 空数组 *0
  src0 := TRedisMemorySource.Create(Bytes('*0' + #13#10));
  rdr0 := TRedisReader.Create(src0, 2);
  try
    v0 := rdr0.ReadReply;
    try
      Check('empty array kind', v0.Kind = rkArray);
      Check('empty array count', Length(v0.Items) = 0);
    finally
      v0.Free;
    end;
  finally
    rdr0.Free;
    src0.Free;
  end;

  CheckReply('nil array', Bytes('*-1' + #13#10), rkNull, '');

  // 嵌套数组 *2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n
  arrSrc := TRedisMemorySource.Create(Bytes('*2' + #13#10 + '$3' + #13#10 + 'foo' + #13#10 + '$3' + #13#10 + 'bar' + #13#10));
  arrRdr := TRedisReader.Create(arrSrc, 2);
  try
    arrV := arrRdr.ReadReply;
    try
      Check('array kind', arrV.Kind = rkArray);
      Check('array count', Length(arrV.Items) = 2);
      Check('array elem0', (Length(arrV.Items) > 0) and (arrV.Items[0].Kind = rkBulk) and (arrV.Items[0].Str = 'foo'));
      Check('array elem1', (Length(arrV.Items) > 1) and (arrV.Items[1].Kind = rkBulk) and (arrV.Items[1].Str = 'bar'));
    finally
      arrV.Free;
    end;
  finally
    arrRdr.Free;
    arrSrc.Free;
  end;
```

- [ ] **Step 4: 编译并运行，确认 RESP2 测试通过**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -5
./tests/test_redis_proto
```
Expected: 所有 RESP2 断言 PASS，0 failed，退出码 0。

- [ ] **Step 5: Commit**

```bash
git add source/redisclient.pas tests/test_redis_proto.lpr
git commit -m "feat(redis): add RESP2 reply parsing

TRedisByteSource (abstract) + TRedisMemorySource (test) + TRedisReader.
Parses RESP2: simple string, error, integer, bulk, array, and nil
(\$-1 / *-1). Nested arrays via recursive ParseReply. Tests cover all
RESP2 reply types including empty/nil arrays."
```

---

## Task 4: RESP3 解析 — 新增类型

**Files:**
- Modify: `source/redisclient.pas`（扩展 `ParseReply` 处理 RESP3 类型，仅当 `Protocol=3`）
- Modify: `tests/test_redis_proto.lpr`

**Interfaces:**
- Consumes: `TRedisReader.Protocol`（Task 3）
- Produces: `ParseReply` 现处理 `_`(null)、`#`(boolean)、`,`(double)、`(`(big number)、`=`(verbatim)、`%`(map)、`~`(set)、`>`(push)。RESP3 类型仅在 `Protocol=3` 时识别；`Protocol=2` 遇到这些字节落入 `else` 抛 `ERedisError`。

- [ ] **Step 1: 在 `redisclient.pas` implementation uses 添加 Math**

将 implementation 区顶部的隐式 implementation 改为显式 uses（`TRedisValue` 之前无 uses，现添加）。在 `implementation` 关键字之后、`{ TRedisValue }` 之前插入：
```pascal
implementation

uses
  Math;
```
（`Infinity`/`NaN` 需要 `Math`；`StrToFloatDef`/`StrToIntDef`/`UTF8ToString` 在 `SysUtils`，已在 interface `uses`。）

- [ ] **Step 2: 扩展 `ParseReply` 的 case 分支**

将 `ParseReply` 中 `'*':` 分支之后、`else` 之前插入 RESP3 分支（仍在一个 case 内）：
```pascal
    '_': begin  // RESP3 null
      if FProtocol < 3 then raise ERedisError.Create('RESP3 null in RESP2 mode');
      ReadLine;  // 丢弃空 line
      Result := TRedisValue.Create(rkNull);
    end;
    '#': begin  // boolean
      if FProtocol < 3 then raise ERedisError.Create('RESP3 boolean in RESP2 mode');
      line := Trim(ReadLine);
      Result := TRedisValue.Create(rkBoolean);
      if line = 't' then Result.Int := 1 else Result.Int := 0;
    end;
    ',': begin  // double
      if FProtocol < 3 then raise ERedisError.Create('RESP3 double in RESP2 mode');
      line := Trim(ReadLine);
      Result := TRedisValue.Create(rkDouble);
      if (line = 'inf') or (line = '+inf') then Result.Dbl := Infinity
      else if line = '-inf' then Result.Dbl := NegInfinity
      else if line = 'nan' then Result.Dbl := NaN
      else Result.Dbl := StrToFloatDef(line, 0, DefaultFormatSettings);
    end;
    '(': begin  // big number
      if FProtocol < 3 then raise ERedisError.Create('RESP3 big number in RESP2 mode');
      Result := TRedisValue.Create(rkBigNumber);
      Result.Str := UTF8ToString(ReadLine);
    end;
    '=': begin  // verbatim: <len>\r\n<fmt>:<payload>\r\n
      if FProtocol < 3 then raise ERedisError.Create('RESP3 verbatim in RESP2 mode');
      line := Trim(ReadLine);  // = len
      Result := TRedisValue.Create(rkVerbatim);
      count := StrToIntDef(line, 0);  // 复用 count 作为总长度
      raw := FSource.ReadExact(count);
      // raw = fmt(3) + ':' + payload
      Result.VerbatimFormat := UTF8ToString(Copy(raw, 1, 3));
      Result.Str := UTF8ToString(Copy(raw, 5, count - 4));
      FSource.ReadByte;  // CR
      FSource.ReadByte;  // LF
    end;
    '%': begin  // map: 声明数 = 对数；元素数 = 对数*2
      if FProtocol < 3 then raise ERedisError.Create('RESP3 map in RESP2 mode');
      line := Trim(ReadLine);
      count := StrToIntDef(line, 0);
      Result := TRedisValue.Create(rkMap);
      SetLength(Result.Items, count * 2);
      for i := 0 to (count * 2) - 1 do
        Result.Items[i] := ParseReply;
    end;
    '~': begin  // set
      if FProtocol < 3 then raise ERedisError.Create('RESP3 set in RESP2 mode');
      line := Trim(ReadLine);
      count := StrToIntDef(line, 0);
      Result := TRedisValue.Create(rkSet);
      SetLength(Result.Items, count);
      for i := 0 to count - 1 do
        Result.Items[i] := ParseReply;
    end;
    '>': begin  // push (结构同 array)
      if FProtocol < 3 then raise ERedisError.Create('RESP3 push in RESP2 mode');
      line := Trim(ReadLine);
      count := StrToIntDef(line, 0);
      Result := TRedisValue.Create(rkPush);
      SetLength(Result.Items, count);
      for i := 0 to count - 1 do
        Result.Items[i] := ParseReply;
    end;
```

- [ ] **Step 3: 在 `ParseReply` 的 var 区补 `raw` 变量**

`ParseReply` 现有 `var b: Byte; line: RawByteString; count, i: Integer;`，改为：
```pascal
var
  b: Byte;
  line: RawByteString;
  count, i: Integer;
  raw: RawByteString;
```

- [ ] **Step 4: 在测试程序添加 RESP3 辅助与断言**

在 `CheckReply` 之后添加 `CheckReply3`（声明在主 `var` 之前）：
```pascal
procedure CheckReply3(const Name: string; const Data: TBytes; ExpectedKind: TRedisReplyKind;
  const ExpectedStr: string; ExpectedInt: Int64 = 0; ExpectedDbl: Double = 0);
var
  src: TRedisMemorySource;
  rdr: TRedisReader;
  v: TRedisValue;
begin
  src := TRedisMemorySource.Create(Data);
  rdr := TRedisReader.Create(src, 3);
  try
    v := rdr.ReadReply;
    try
      Check(Name + ' kind', v.Kind = ExpectedKind);
      if ExpectedStr <> '' then Check(Name + ' str', v.Str = ExpectedStr);
      if ExpectedKind = rkBoolean then Check(Name + ' int', v.Int = ExpectedInt);
      if ExpectedKind = rkDouble then Check(Name + ' dbl', Abs(v.Dbl - ExpectedDbl) < 1e-9);
    finally
      v.Free;
    end;
  finally
    rdr.Free;
    src.Free;
  end;
end;
```
在主 `var` 区补充 RESP3 聚合测试变量：
```pascal
  mapSrc, setSrc: TRedisMemorySource;
  mapRdr, setRdr: TRedisReader;
  mapV, setV: TRedisValue;
```
在 `begin` 块 Task 3 断言之后添加：
```pascal
  // --- Task 4: RESP3 解析 ---
  CheckReply3('resp3 true', Bytes('#t' + #13#10), rkBoolean, '', 1);
  CheckReply3('resp3 false', Bytes('#f' + #13#10), rkBoolean, '', 0);
  CheckReply3('resp3 double', Bytes(',3.14' + #13#10), rkDouble, '', 0, 3.14);
  CheckReply3('resp3 bignumber', Bytes('(12345678901234567890' + #13#10), rkBigNumber, '12345678901234567890');
  CheckReply3('resp3 null', Bytes('_' + #13#10), rkNull, '');
  // =15\r\ntxt:hello world\r\n  (txt: =4 字节, hello world =11 字节, 共15)
  CheckReply3('resp3 verbatim', Bytes('=15' + #13#10 + 'txt:hello world' + #13#10), rkVerbatim, 'hello world');

  // %1\r\n:1\r\n:2\r\n  (map 1 对 = 2 元素)
  mapSrc := TRedisMemorySource.Create(Bytes('%1' + #13#10 + ':1' + #13#10 + ':2' + #13#10));
  mapRdr := TRedisReader.Create(mapSrc, 3);
  try
    mapV := mapRdr.ReadReply;
    try
      Check('resp3 map kind', mapV.Kind = rkMap);
      Check('resp3 map count', Length(mapV.Items) = 2);
      Check('resp3 map key', (Length(mapV.Items) > 0) and (mapV.Items[0].Kind = rkInteger) and (mapV.Items[0].Int = 1));
      Check('resp3 map val', (Length(mapV.Items) > 1) and (mapV.Items[1].Kind = rkInteger) and (mapV.Items[1].Int = 2));
    finally
      mapV.Free;
    end;
  finally
    mapRdr.Free;
    mapSrc.Free;
  end;

  // ~2\r\n+a\r\n+b\r\n
  setSrc := TRedisMemorySource.Create(Bytes('~2' + #13#10 + '+a' + #13#10 + '+b' + #13#10));
  setRdr := TRedisReader.Create(setSrc, 3);
  try
    setV := setRdr.ReadReply;
    try
      Check('resp3 set kind', setV.Kind = rkSet);
      Check('resp3 set count', Length(setV.Items) = 2);
    finally
      setV.Free;
    end;
  finally
    setRdr.Free;
    setSrc.Free;
  end;
```

- [ ] **Step 5: 编译并运行，确认 RESP3 测试通过**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -5
./tests/test_redis_proto
```
Expected: RESP2 + RESP3 全部断言 PASS，0 failed。

- [ ] **Step 6: Commit**

```bash
git add source/redisclient.pas tests/test_redis_proto.lpr
git commit -m "feat(redis): add RESP3 reply types (null, boolean, double, bignumber, verbatim, map, set, push)

RESP3 types only recognized when TRedisReader.Protocol=3; raise
ERedisError if encountered in RESP2 mode. Map element count is pairs*2.
Verbatim stores 3-byte format separately from payload."
```

---

## Task 5: 分块输入重组测试

**Files:**
- Modify: `tests/test_redis_proto.lpr`

**Interfaces:**
- Consumes: `TRedisReader`、`TRedisByteSource`（Task 3/4）
- Produces: 验证 reader 在字节分多次到达时仍能正确重组回复（模拟 socket 分包）。

- [ ] **Step 1: 在测试程序添加分块字节源类型与测试**

在 `tests/test_redis_proto.lpr` 的 `CheckReply3` 之后、主 `var` 之前添加分块源类型（必须在 `begin` 前的 type/var 区声明）：
```pascal
type
  { TRedisChunkedSource — 把一份数据切成多块，模拟 socket 分包到达。 }
  TRedisChunkedSource = class(TRedisByteSource)
  private
    FChunks: array of TBytes;
    FChunkIdx, FPosInChunk: Integer;
  public
    constructor Create(const AChunks: array of TBytes);
    function ReadByte: Byte; override;
  end;

constructor TRedisChunkedSource.Create(const AChunks: array of TBytes);
var
  i: Integer;
begin
  inherited Create;
  SetLength(FChunks, Length(AChunks));
  for i := 0 to High(AChunks) do
    FChunks[i] := AChunks[i];
  FChunkIdx := 0;
  FPosInChunk := 0;
end;

function TRedisChunkedSource.ReadByte: Byte;
begin
  while (FChunkIdx < Length(FChunks)) and (FPosInChunk >= Length(FChunks[FChunkIdx])) do begin
    Inc(FChunkIdx);
    FPosInChunk := 0;
  end;
  if FChunkIdx >= Length(FChunks) then
    raise ERedisError.Create('chunked source exhausted');
  Result := FChunks[FChunkIdx][FPosInChunk];
  Inc(FPosInChunk);
end;
```
> 注意：`TRedisChunkedSource` 与其方法必须声明在主 `begin` 之前的声明区。`constructor`/`function` 实现紧随类声明（仍在 `begin` 前，作为单元级过程实现）。

在主 `var` 区补充：
```pascal
  full, c0, c1, c2: TBytes;
  chunks: array of TBytes;
  cSrc, bSrc: TRedisChunkedSource;
  cRdr, bRdr: TRedisReader;
  cV, bV: TRedisValue;
  bChunks: array of TBytes;
```
在 `begin` 块 Task 4 断言之后添加：
```pascal
  // --- Task 5: 分块输入重组 ---
  // 把 "*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n" 切成 3 块
  full := Bytes('*2' + #13#10 + '$3' + #13#10 + 'foo' + #13#10 + '$3' + #13#10 + 'bar' + #13#10);
  SetLength(chunks, 3);
  c0 := Copy(full, 0, 4);                          // *2\r\n
  c1 := Copy(full, 4, 10);                         // $3\r\nfoo\r\n
  c2 := Copy(full, 14, Length(full) - 14);         // $3\r\nbar\r\n
  chunks[0] := c0; chunks[1] := c1; chunks[2] := c2;
  cSrc := TRedisChunkedSource.Create(chunks);
  cRdr := TRedisReader.Create(cSrc, 2);
  try
    cV := cRdr.ReadReply;
    try
      Check('chunked array kind', cV.Kind = rkArray);
      Check('chunked array count', Length(cV.Items) = 2);
      Check('chunked elem0', (Length(cV.Items) > 0) and (cV.Items[0].Str = 'foo'));
      Check('chunked elem1', (Length(cV.Items) > 1) and (cV.Items[1].Str = 'bar'));
    finally
      cV.Free;
    end;
  finally
    cRdr.Free;
    cSrc.Free;
  end;

  // 分块在 bulk 中间断开: $5\r\nhe | llo\r\n
  SetLength(bChunks, 2);
  bChunks[0] := Bytes('$5' + #13#10 + 'he');
  bChunks[1] := Bytes('llo' + #13#10);
  bSrc := TRedisChunkedSource.Create(bChunks);
  bRdr := TRedisReader.Create(bSrc, 2);
  try
    bV := bRdr.ReadReply;
    try
      Check('chunked bulk kind', bV.Kind = rkBulk);
      Check('chunked bulk str', bV.Str = 'hello');
    finally
      bV.Free;
    end;
  finally
    bRdr.Free;
    bSrc.Free;
  end;
```

- [ ] **Step 2: 编译并运行，确认分块测试通过**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -5
./tests/test_redis_proto
```
Expected: 分块断言 PASS，0 failed。（验证 `ReadBulk`/`ReadExact`/`ReadLine` 跨块边界正确——`ReadByte` 是最小单位，分块源在块边界切换，reader 不感知边界。）

- [ ] **Step 3: Commit**

```bash
git add tests/test_redis_proto.lpr
git commit -m "test(redis): verify reply parsing across chunked input

Add TRedisChunkedSource that slices one reply into multiple byte chunks
(simulating socket packet boundaries). Confirms reader reassembles arrays
and bulks split mid-stream."
```

---

## Task 6: Socket 字节源 + `TRedisClient` 纯 TCP 连接/Ping

**Files:**
- Modify: `source/redisclient.pas`
- Modify: `tests/test_redis_proto.lpr`（仅编译验证；真实 socket 测试为手动冒烟）

**Interfaces:**
- Consumes: `TRedisByteSource`、`TRedisReader`、`RedisSerializeCommand`（Task 2-5）
- Produces:
  - `TRedisSocketSource`（`constructor Create(AHost: string; APort: Integer);`，缓冲 recv 实现 `ReadByte`；`procedure Send(const AData: TBytes);` 供 client 调用）
  - `TRedisClient`：
    - `constructor Create;`
    - `procedure Connect(AHost: string; APort: Integer; AUser: string; APassword: string; ADb: Integer);`（本任务先纯 TCP + 不鉴权；鉴权在 Task 7）
    - `function Execute(const Args: array of string): TRedisValue; overload;`
    - `function Execute(const Cmd: string): TRedisValue; overload;`（空格分词便捷重载）
    - `function Ping: Boolean;`
    - `procedure Disconnect;`
    - `property Protocol: Integer;`
    - `property LastError: string;`

- [ ] **Step 1: 在 `redisclient.pas` interface 区添加 Socket 源与 Client 声明**

在 `TRedisReader` 声明之后添加：
```pascal
  { TRedisSocketSource — 基于 FPC Sockets 单元的缓冲 recv 字节源。 }
  TRedisSocketSource = class(TRedisByteSource)
  private
    FSocket: LongInt;
    FBuf: array[0..8191] of Byte;
    FBufStart, FBufEnd: Integer;
    procedure FillBuffer;
  public
    constructor Create(AHost: string; APort: Integer);
    destructor Destroy; override;
    function ReadByte: Byte; override;
    procedure Send(const AData: TBytes);
  end;

  { TRedisClient — 编排 socket + reader + writer。
    阶段 1: 纯 TCP、无鉴权、RESP2。鉴权/HELLO/RESP3 协商在 Task 7。 }
  TRedisClient = class
  private
    FSource: TRedisSocketSource;
    FReader: TRedisReader;
    FProtocol: Integer;
    FLastError: string;
    FHost: string;
    FPort: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Connect(AHost: string; APort: Integer; AUser: string; APassword: string; ADb: Integer);
    function Execute(const Args: array of string): TRedisValue; overload;
    function Execute(const Cmd: string): TRedisValue; overload;
    function Ping: Boolean;
    procedure Disconnect;
    property Protocol: Integer read FProtocol;
    property LastError: string read FLastError;
  end;
```

- [ ] **Step 2: 在 implementation uses 添加 Sockets**

将 `redisclient.pas` 的：
```pascal
implementation

uses
  Math;
```
改为：
```pascal
implementation

uses
  Math, Sockets;
```

- [ ] **Step 3: 在 implementation 区添加 Socket 源与 Client 实现**

在 `TRedisReader` 实现之后添加：
```pascal
{ TRedisSocketSource }

constructor TRedisSocketSource.Create(AHost: string; APort: Integer);
var
  sin: Sockets.sockaddr_in;
  s: LongInt;
begin
  inherited Create;
  s := Sockets.fpSocket(Sockets.AF_INET, Sockets.SOCK_STREAM, 0);
  if s = -1 then
    raise ERedisError.Create('fpSocket failed');
  FillChar(sin, SizeOf(sin), 0);
  sin.sin_family := Sockets.AF_INET;
  sin.sin_port := Sockets.htons(APort);
  sin.sin_addr := Sockets.StrToHostAddr(AHost);
  if Sockets.fpConnect(s, @sin, SizeOf(sin)) <> 0 then begin
    Sockets.fpCloseSocket(s);
    raise ERedisError.CreateFmt('Connect to %s:%d failed', [AHost, APort]);
  end;
  FSocket := s;
  FBufStart := 0;
  FBufEnd := 0;
end;

destructor TRedisSocketSource.Destroy;
begin
  if FSocket <> -1 then
    Sockets.fpCloseSocket(FSocket);
  inherited Destroy;
end;

procedure TRedisSocketSource.FillBuffer;
var
  n: LongInt;
begin
  n := Sockets.fpRecv(FSocket, @FBuf[0], SizeOf(FBuf), 0);
  if n <= 0 then
    raise ERedisError.Create('fpRecv: connection closed or error');
  FBufStart := 0;
  FBufEnd := n;
end;

function TRedisSocketSource.ReadByte: Byte;
begin
  if FBufStart >= FBufEnd then
    FillBuffer;
  Result := FBuf[FBufStart];
  Inc(FBufStart);
end;

procedure TRedisSocketSource.Send(const AData: TBytes);
var
  n, sent: LongInt;
begin
  n := 0;
  while n < Length(AData) do begin
    sent := Sockets.fpSend(FSocket, @AData[n], Length(AData) - n, 0);
    if sent <= 0 then
      raise ERedisError.Create('fpSend failed');
    Inc(n, sent);
  end;
end;

{ TRedisClient }

constructor TRedisClient.Create;
begin
  inherited Create;
  FProtocol := 2;  // 默认 RESP2，Task 7 的 HELLO 协商可能升为 3
end;

destructor TRedisClient.Destroy;
begin
  Disconnect;
  inherited Destroy;
end;

procedure TRedisClient.Connect(AHost: string; APort: Integer; AUser: string; APassword: string; ADb: Integer);
begin
  FHost := AHost;
  FPort := APort;
  FSource := TRedisSocketSource.Create(AHost, APort);
  FReader := TRedisReader.Create(FSource, FProtocol);
  // 链路探测：PING 应返回 +PONG。鉴权 (HELLO/AUTH) 与 SELECT 在 Task 7。
  if not Ping then
    raise ERedisError.Create('PING failed after connect');
end;

function TRedisClient.Execute(const Args: array of string): TRedisValue;
var
  data: TBytes;
begin
  data := RedisSerializeCommand(Args);
  FSource.Send(data);
  Result := FReader.ReadReply;
  if (Result <> nil) and (Result.Kind = rkError) then begin
    FLastError := Result.Str;
    Result.Free;
    raise ERedisError.Create('Redis error: ' + FLastError);
  end;
end;

function TRedisClient.Execute(const Cmd: string): TRedisValue;
var
  parts: TStringArray;
begin
  parts := Cmd.Split([' ']);
  Result := Execute(parts);
end;

function TRedisClient.Ping: Boolean;
var
  v: TRedisValue;
begin
  Result := False;
  try
    v := Execute(['PING']);
    try
      Result := (v.Kind = rkString) and (v.Str = 'PONG');
    finally
      v.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

procedure TRedisClient.Disconnect;
begin
  FreeAndNil(FReader);
  FreeAndNil(FSource);  // 析构时关 socket
end;
```

- [ ] **Step 4: 编译验证（不连真实 Redis）**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -8
./tests/test_redis_proto
```
Expected: 编译成功（0 errors）。原有协议测试全 PASS。`TRedisClient`/`TRedisSocketSource` 本身无单元测试（需真实 Redis），仅验证可编译链接。

- [ ] **Step 5: 手动冒烟（需本地 Redis；可选）**

若环境有 docker：
```bash
docker run -d --rm --name redis-probe -p 6399:6379 redis:7
redis-cli -p 6399 PING   # 应返回 PONG，确认 Redis 可用
docker stop redis-probe
```
（`TRedisClient` 的真实连接冒烟留到 Task 7 与鉴权一起做。本步仅确认编译产物不破坏现有测试。）

- [ ] **Step 6: Commit**

```bash
git add source/redisclient.pas tests/test_redis_proto.lpr
git commit -m "feat(redis): add TRedisSocketSource (buffered recv) and TRedisClient

TRedisSocketSource: FPC Sockets unit, 8KB read buffer, ReadByte pulls
from buffer or refills via fpRecv; Send() writes full TBytes via fpSend.
TRedisClient: plain TCP Connect, Execute (serialize+send+readReply,
converts -ERR to ERedisError), Ping, Disconnect. Auth/HELLO/SELECT
deferred to next task. Uses StrToHostAddr (not StrToNetHost)."
```

---

## Task 7: 鉴权（HELLO/AUTH 回退）+ SELECT

**Files:**
- Modify: `source/redisclient.pas`
- Modify: `tests/test_redis_proto.lpr`（仅编译验证；鉴权需真实 Redis，为手动冒烟）

**Interfaces:**
- Consumes: `TRedisClient.Connect`（Task 6）
- Produces: `Connect` 现完成完整握手：建 TCP → PING → 鉴权（HELLO 3 AUTH → AUTH 回退）→ 协商 `FProtocol` → `SELECT <db>`。`property Protocol` 反映协商结果。

**鉴权流程（spec §4.3）：**
1. 若 `AUser <> ''`：发 `HELLO 3 AUTH <user> <pass>`。成功（返回 map，含 `proto:3`）→ `FProtocol := 3`，`FReader.Protocol := 3`。失败（旧版不支持）→ 回退步骤 2。
2. 回退：若 `AUser <> ''` 发 `AUTH <user> <pass>`；否则若 `APassword <> ''` 发 `AUTH <pass>`（旧版）。成功（`+OK`）→ `FProtocol := 2`。失败 → 抛 `ERedisError`。
3. 若 `AUser = ''` 且 `APassword = ''`：无鉴权，跳过。`FProtocol := 2`。
4. 若 `ADb > 0`：发 `SELECT <ADb>`，验证 `+OK`。

- [ ] **Step 1: 在 `TRedisClient` private 区添加方法声明**

```pascal
    procedure DoAuthenticate(AUser: string; APassword: string);
    procedure SelectDb(ADb: Integer);
```

- [ ] **Step 2: 在 implementation 区添加方法实现，并改写 `Connect`**

```pascal
procedure TRedisClient.DoAuthenticate(AUser: string; APassword: string);
var
  v: TRedisValue;
begin
  if AUser <> '' then begin
    // 尝试 HELLO 3 AUTH user pass（Redis 6+，RESP3 + ACL）
    try
      v := Execute(['HELLO', '3', 'AUTH', AUser, APassword]);
      try
        // 成功返回 map（RESP3）含 proto/server/...；协议已升 3
        FProtocol := 3;
        FReader.Protocol := 3;
      finally
        v.Free;
      end;
      Exit;
    except
      on ERedisError do
        ; // 旧版不支持 HELLO，回退到 AUTH
    end;
  end;

  // 回退: AUTH user pass 或 AUTH pass
  if AUser <> '' then
    v := Execute(['AUTH', AUser, APassword])
  else if APassword <> '' then
    v := Execute(['AUTH', APassword])
  else
    Exit; // 无凭据，不鉴权

  try
    if (v.Kind <> rkString) or (v.Str <> 'OK') then
      raise ERedisError.Create('AUTH failed: ' + v.Str);
    FProtocol := 2;
    FReader.Protocol := 2;
  finally
    v.Free;
  end;
end;

procedure TRedisClient.SelectDb(ADb: Integer);
var
  v: TRedisValue;
begin
  if ADb <= 0 then
    Exit;
  v := Execute(['SELECT', IntToStr(ADb)]);
  try
    if (v.Kind <> rkString) or (v.Str <> 'OK') then
      raise ERedisError.Create('SELECT failed: ' + v.Str);
  finally
    v.Free;
  end;
end;
```

改写 `Connect`（替换 Task 6 版本）：
```pascal
procedure TRedisClient.Connect(AHost: string; APort: Integer; AUser: string; APassword: string; ADb: Integer);
begin
  FHost := AHost;
  FPort := APort;
  FSource := TRedisSocketSource.Create(AHost, APort);
  FReader := TRedisReader.Create(FSource, FProtocol);
  if not Ping then
    raise ERedisError.Create('PING failed after connect');
  DoAuthenticate(AUser, APassword);  // 鉴权 + HELLO 协商
  SelectDb(ADb);                      // 选库
end;
```

- [ ] **Step 3: 编译验证**

Run:
```bash
cd /data/projects_local/pascal/HeidiSQL
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:$PATH
/data/fpc_tools/fpc/bin/x86_64-linux/fpc @/data/fpc_tools/fpc/bin/x86_64-linux/fpc.cfg \
  -Mdelphi -Sh -Fusource -Futests \
  tests/test_redis_proto.lpr -otests/test_redis_proto 2>&1 | tail -8
./tests/test_redis_proto
```
Expected: 编译成功，原有协议测试全 PASS（鉴权逻辑无单元测试，需真实 Redis 手动验证）。

- [ ] **Step 4: 手动冒烟 — RESP2 无密码 Redis**

写临时 `tests/_smoke.lpr`（已在 .gitignore）：
```pascal
program _smoke;
{$mode delphi}{$H+}
uses SysUtils, redisclient;
var
  c: TRedisClient;
  v: TRedisValue;
begin
  c := TRedisClient.Create;
  try
    c.Connect('127.0.0.1', 6399, '', '', 0);
    writeln('protocol=', c.Protocol);
    v := c.Execute(['SET', 'k', 'v']);
    v.Free;
    v := c.Execute(['GET', 'k']);
    try writeln('GET k = ', v.Str); finally v.Free; end;
    c.Disconnect;
  finally
    c.Free;
  end;
end.
```
编译运行：
```bash
docker run -d --rm --name redis-r2 -p 6399:6379 redis:6
# 编译 _smoke（用 Task 1 的 fpc 命令，-Fusource）
./tests/_smoke   # 期望: protocol=2, GET k = v
docker stop redis-r2
```

- [ ] **Step 5: 手动冒烟 — RESP3 + ACL Redis**

```bash
docker run -d --rm --name redis-r3 -p 6400:6379 redis:7 \
  redis-server --requirepass secret --user alice on '>secret' '~*' '+@all'
# 修改 _smoke.lpr 的 Connect 为 ('127.0.0.1', 6400, 'alice', 'secret', 1)
./tests/_smoke   # 期望: protocol=3, GET k = v
docker stop redis-r3
rm -f tests/_smoke tests/_smoke.o tests/_smoke.ppu
```

- [ ] **Step 6: Commit**

```bash
git add source/redisclient.pas tests/test_redis_proto.lpr
git commit -m "feat(redis): add HELLO/AUTH authentication with RESP3 negotiation and SELECT

Connect flow: TCP -> PING -> DoAuthenticate (try HELLO 3 AUTH for ACL
users, fall back to AUTH user/pass or AUTH pass for legacy) -> SELECT db.
FProtocol/FReader.Protocol upgraded to 3 on HELLO success. Manual smoke
tested against redis:6 (RESP2, no auth) and redis:7 (RESP3+ACL)."
```

---

## 阶段 1 完成标准

- `source/redisclient.pas` 完整实现 RESP2/RESP3 解析、命令序列化、纯 TCP 传输、鉴权（HELLO/AUTH 回退）、SELECT。
- `tests/test_redis_proto.lpr` 全部断言 PASS，退出码 0，覆盖：序列化（含多字节）、RESP2 全类型、RESP3 全类型、嵌套、分块重组。
- 手动冒烟通过 redis:6（RESP2）与 redis:7（RESP3+ACL）。

## 后续阶段（本计划不覆盖，由后续计划承接）

- **阶段 2**: 枚举扩展（`TNetType`/`TNetTypeGroup` 加 Redis 值）、`TRedisConnection : TDBConnection`、`TRedisQuery : TDBQuery`、`dbstructures.redis.pas`、`connections.pas` 会话对话框门控、`dbconnection.pas` 各 `case` 分支。把 `ERedisError` 映射为 `EDbError`。
- **阶段 3**: 键树（SCAN + 前缀分组）、`redis_values.pas` 只读值查看器。
- **阶段 4**: `redis_console.pas` 命令台。
- **阶段 5**: TLS（`TRedisTlsSocket`）、SSH 隧道。
- **阶段 6**: 主窗体动作门控。
- **阶段 7-8（后续里程碑）**: Cluster/Sentinel、ACL 管理 UI、导出。
