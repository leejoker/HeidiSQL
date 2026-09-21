program test_redis_proto;

{$mode delphi}{$H+}

uses
  {$IFDEF UNIX} cthreads, cwstring, {$ENDIF}
  SysUtils, Classes,
  redisclient;  // 单元在 source/，编译时用 -Fusource

var
  Pass, Fail: Integer;
  got: TBytes;
  s: string;

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

var
  src0: TRedisMemorySource;
  rdr0: TRedisReader;
  v0: TRedisValue;
  arrSrc: TRedisMemorySource;
  arrRdr: TRedisReader;
  arrV: TRedisValue;
  mapSrc, setSrc: TRedisMemorySource;
  mapRdr, setRdr: TRedisReader;
  mapV, setV: TRedisValue;
  full, c0, c1, c2: TBytes;
  chunks: array of TBytes;
  cSrc, bSrc: TRedisChunkedSource;
  cRdr, bRdr: TRedisReader;
  cV, bV: TRedisValue;
  bChunks: array of TBytes;

begin
  Pass := 0;
  Fail := 0;
  writeln('=== redisclient protocol tests ===');

  // 真实的单元加载检查：函数地址可取即单元已链接
  Check('unit loads', Assigned(@RedisSerializeCommand));

  // --- Task 2: RedisSerializeCommand ---
  got := RedisSerializeCommand(['GET', 'foo']);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize GET foo', s = '*2' + #13#10 + '$3' + #13#10 + 'GET' + #13#10 + '$3' + #13#10 + 'foo' + #13#10);

  got := RedisSerializeCommand(['SET', 'k', 'v']);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize SET k v', s = '*3' + #13#10 + '$3' + #13#10 + 'SET' + #13#10 + '$1' + #13#10 + 'k' + #13#10 + '$1' + #13#10 + 'v' + #13#10);

  // 多字节: "café" = 5 UTF-8 字节，bulk 长度应为 $5，且字节为 63 61 66 C3 A9
  got := RedisSerializeCommand(['SET', 'name', 'café']);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize multibyte value byte-length', Pos('$5' + #13#10, s) > 0);
  Check('serialize multibyte value bytes', Pos('$5' + #13#10 + 'caf' + #$C3 + #$A9, s) > 0);

  got := RedisSerializeCommand([]);
  s := TEncoding.UTF8.GetString(got);
  Check('serialize empty command', s = '*0' + #13#10);

  // --- Task 3: RESP2 解析 ---
  CheckReply('simple string', Bytes('+OK' + #13#10), rkString, 'OK');
  CheckReply('error', Bytes('-ERR boom' + #13#10), rkError, 'ERR boom');
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

  // --- Task 4: RESP3 解析 ---
  CheckReply3('resp3 true', Bytes('#t' + #13#10), rkBoolean, '', 1);
  CheckReply3('resp3 false', Bytes('#f' + #13#10), rkBoolean, '', 0);
  CheckReply3('resp3 double', Bytes(',3.14' + #13#10), rkDouble, '', 0, 3.14);
  CheckReply3('resp3 bignumber', Bytes('(12345678901234567890' + #13#10), rkBigNumber, '12345678901234567890');
  CheckReply3('resp3 null', Bytes('_' + #13#10), rkNull, '');
  // =15\r\ntxt:hello world\r\n  (txt: =4 字节, hello world =11 字节, 共15)
  CheckReply3('resp3 verbatim', Bytes('=15' + #13#10 + 'txt:hello world' + #13#10), rkVerbatim, 'hello world');
  // 额外断言 verbatim 的 3 字节格式子类型被正确提取
  src0 := TRedisMemorySource.Create(Bytes('=15' + #13#10 + 'txt:hello world' + #13#10));
  rdr0 := TRedisReader.Create(src0, 3);
  try
    v0 := rdr0.ReadReply;
    try
      Check('resp3 verbatim fmt', v0.VerbatimFormat = 'txt');
    finally
      v0.Free;
    end;
  finally
    rdr0.Free;
    src0.Free;
  end;

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

  // --- Task 5: 分块输入重组 ---
  // 把 "*2\r\n$3\r\nfoo\r\n$3\r\nbar\r\n" 切成 3 块
  full := Bytes('*2' + #13#10 + '$3' + #13#10 + 'foo' + #13#10 + '$3' + #13#10 + 'bar' + #13#10);
  SetLength(chunks, 3);
  c0 := Copy(full, 0, 4);                          // *2\r\n
  c1 := Copy(full, 4, 10);                         // $3\r\nfoo\r\n (+)
  c2 := Copy(full, 14, Length(full) - 14);         // 3\r\nbar\r\n
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

  writeln;
  writeln(Format('=== %d passed, %d failed ===', [Pass, Fail]));
  if Fail > 0 then
    Halt(1);
end.
