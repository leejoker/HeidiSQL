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

{ Serialize a command (array of string args) into RESP array bytes: *N CRLF $len CRLF bytes CRLF ... }
function RedisSerializeCommand(const Args: array of string): TBytes;

type
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

  { TRedisSocketSource — 基于 FPC Sockets 单元的缓冲 recv 字节源。 }
  TRedisSocketSource = class(TRedisByteSource)
  private
    FSocket: LongInt;
    FBuf: array[0..8191] of Byte;
    FBufStart, FBufEnd: Integer;
    procedure FillBuffer;
    procedure CloseSocket;
  public
    constructor Create(AHost: string; APort: Integer);
    destructor Destroy; override;
    function ReadByte: Byte; override;
    function ReadExact(Count: Integer): RawByteString; override;
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
    procedure DoAuthenticate(AUser: string; APassword: string);
  public
    procedure SelectDb(ADb: Integer);
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

implementation

uses
  Math, Sockets
  {$IFDEF UNIX}, BaseUnix{$ENDIF};

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

{ TRedisByteSource }

function TRedisByteSource.ReadExact(Count: Integer): RawByteString;
var
  i, ChunkLen: Integer;
begin
  SetLength(Result, Count);
  i := 0;
  while i < Count do begin
    // 子类可提供更快的块读，默认仍逐字节
    ChunkLen := Count - i;
    Result[i + 1] := AnsiChar(ReadByte);
    Inc(i);
  end;
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
  // 避免 UTF8ToString 的额外内存拷贝：直接赋值 + 设置 codepage
  Result := string(raw);
  SetCodePage(RawByteString(Result), CP_UTF8, False);
  FSource.ReadByte;  // CR
  FSource.ReadByte;  // LF
end;

function TRedisReader.ParseReply: TRedisValue;
var
  b: Byte;
  line: RawByteString;
  count, i: Integer;
  raw: RawByteString;
begin
  b := FSource.ReadByte;
  case AnsiChar(b) of
    '+': begin
      Result := TRedisValue.Create(rkString);
      try
        Result.Str := UTF8ToString(ReadLine);
      except
        Result.Free; raise;
      end;
    end;
    '-': begin
      Result := TRedisValue.Create(rkError);
      try
        Result.Str := UTF8ToString(ReadLine);
      except
        Result.Free; raise;
      end;
    end;
    ':': begin
      Result := TRedisValue.Create(rkInteger);
      try
        Result.Int := StrToInt64Def(Trim(UTF8ToString(ReadLine)), 0);
      except
        Result.Free; raise;
      end;
    end;
    '$': begin
      line := Trim(ReadLine);
      if line = '-1' then
        Result := TRedisValue.Create(rkNull)
      else begin
        count := StrToIntDef(line, 0);
        Result := TRedisValue.Create(rkBulk);
        try
          Result.Str := ReadBulk(count);
        except
          Result.Free; raise;
        end;
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
        try
          for i := 0 to count - 1 do
            Result.Items[i] := ParseReply;  // 递归；子项抛错则整树由 except 释放
        except
          Result.Free; raise;
        end;
      end;
    end;
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
      try
        Result.Str := UTF8ToString(ReadLine);
      except
        Result.Free; raise;
      end;
    end;
    '=': begin  // verbatim: <len>\r\n<fmt>:<payload>\r\n
      if FProtocol < 3 then raise ERedisError.Create('RESP3 verbatim in RESP2 mode');
      line := Trim(ReadLine);  // = len
      count := StrToIntDef(line, 0);  // 复用 count 作为总长度
      Result := TRedisValue.Create(rkVerbatim);
      try
        raw := FSource.ReadExact(count);
        // raw = fmt(3) + ':' + payload
        Result.VerbatimFormat := UTF8ToString(Copy(raw, 1, 3));
        Result.Str := UTF8ToString(Copy(raw, 5, count - 4));
        FSource.ReadByte;  // CR
        FSource.ReadByte;  // LF
      except
        Result.Free; raise;
      end;
    end;
    '%': begin  // map: 声明数 = 对数；元素数 = 对数*2
      if FProtocol < 3 then raise ERedisError.Create('RESP3 map in RESP2 mode');
      line := Trim(ReadLine);
      count := StrToIntDef(line, 0);
      Result := TRedisValue.Create(rkMap);
      SetLength(Result.Items, count * 2);
      try
        for i := 0 to (count * 2) - 1 do
          Result.Items[i] := ParseReply;
      except
        Result.Free; raise;
      end;
    end;
    '~': begin  // set
      if FProtocol < 3 then raise ERedisError.Create('RESP3 set in RESP2 mode');
      line := Trim(ReadLine);
      count := StrToIntDef(line, 0);
      Result := TRedisValue.Create(rkSet);
      SetLength(Result.Items, count);
      try
        for i := 0 to count - 1 do
          Result.Items[i] := ParseReply;
      except
        Result.Free; raise;
      end;
    end;
    '>': begin  // push (结构同 array)
      if FProtocol < 3 then raise ERedisError.Create('RESP3 push in RESP2 mode');
      line := Trim(ReadLine);
      count := StrToIntDef(line, 0);
      Result := TRedisValue.Create(rkPush);
      SetLength(Result.Items, count);
      try
        for i := 0 to count - 1 do
          Result.Items[i] := ParseReply;
      except
        Result.Free; raise;
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

{ TRedisSocketSource }

constructor TRedisSocketSource.Create(AHost: string; APort: Integer);
var
  sin: Sockets.sockaddr_in;
  s: LongInt;
begin
  inherited Create;
  FSocket := -1;  // 防止 fpSocket 失败时析构关闭 fd 0
  s := Sockets.fpSocket(Sockets.AF_INET, Sockets.SOCK_STREAM, 0);
  if s = -1 then
    raise ERedisError.Create('fpSocket failed');
  FillChar(sin, SizeOf(sin), 0);
  sin.sin_family := Sockets.AF_INET;
  sin.sin_port := Sockets.htons(APort);
  sin.sin_addr := Sockets.StrToNetAddr(AHost);
  if Sockets.fpConnect(s, @sin, SizeOf(sin)) <> 0 then begin
    FSocket := s;
    CloseSocket;
    raise ERedisError.CreateFmt('Connect to %s:%d failed', [AHost, APort]);
  end;
  FSocket := s;
  FBufStart := 0;
  FBufEnd := 0;
end;

destructor TRedisSocketSource.Destroy;
begin
  if FSocket <> -1 then
    CloseSocket;
  inherited Destroy;
end;

procedure TRedisSocketSource.CloseSocket;
begin
  {$IFDEF UNIX}
  BaseUnix.FpClose(FSocket);
  {$ELSE}
  // Windows: winsock closesocket — Sockets unit aliases it on that platform
  Sockets.CloseSocket(FSocket);
  {$ENDIF}
  FSocket := -1;
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

function TRedisSocketSource.ReadExact(Count: Integer): RawByteString;
var
  Avail, ChunkLen, TotalRead: Integer;
begin
  SetLength(Result, Count);
  TotalRead := 0;
  while TotalRead < Count do begin
    if FBufStart >= FBufEnd then
      FillBuffer;
    Avail := FBufEnd - FBufStart;
    ChunkLen := Count - TotalRead;
    if ChunkLen > Avail then
      ChunkLen := Avail;
    Move(FBuf[FBufStart], Result[TotalRead + 1], ChunkLen);
    Inc(FBufStart, ChunkLen);
    Inc(TotalRead, ChunkLen);
  end;
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
  // 释放可能存在的旧连接，避免重入（重连/重试）时泄漏旧 socket fd 与 reader。
  // 同时重置协议为 RESP2，由 DoAuthenticate 重新协商。
  Disconnect;
  FProtocol := 2;
  FHost := AHost;
  FPort := APort;
  FSource := TRedisSocketSource.Create(AHost, APort);
  FReader := TRedisReader.Create(FSource, FProtocol);
  // 鉴权必须在 PING 探测之前：带 requirepass 的服务器对未认证的 PING 返回 -NOAUTH，
  // 会被 Execute 转为 ERedisError。先 DoAuthenticate 建立认证会话，再 Ping 验证链路。
  DoAuthenticate(AUser, APassword);
  if not Ping then
    raise ERedisError.Create('PING failed after connect');
  SelectDb(ADb);
end;

procedure TRedisClient.DoAuthenticate(AUser: string; APassword: string);
var
  v: TRedisValue;
begin
  if AUser <> '' then begin
    // 尝试 HELLO 3 AUTH user pass（Redis 6+，RESP3 + ACL）。
    // HELLO 3 的响应本身就是 RESP3 编码，故必须在读取响应前先把 reader 升为 RESP3，
    // 否则按 RESP2 解析 RESP3 的 boolean/map 等会失败。
    FReader.Protocol := 3;
    try
      v := Execute(['HELLO', '3', 'AUTH', AUser, APassword]);
      try
        // 成功返回 map（RESP3）含 proto/server/...；协议已升 3
        FProtocol := 3;
      finally
        v.Free;
      end;
      Exit;
    except
      on ERedisError do begin
        // 旧版不支持 HELLO 或认证失败，回退到 AUTH（RESP2）
        FReader.Protocol := 2;
      end;
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

end.
