unit dbeaver_import;

{$mode delphi}{$H+}

// -------------------------------------
// DBeaver session import — pure logic
// -------------------------------------
// Parses DBeaver's modern JSON workspace (data-sources.json + AES-128-CBC
// encrypted credentials-config.json), maps connections to neutral records,
// and returns an import result. This unit has NO dependency on LCL or on
// HeidiSQL's TConnectionParameters/AppSettings, so it can be unit-tested in
// a standalone console program (see tests/test_dbeaver_import.lpr).
//
// The dialog unit (dbeaver_import_dlg) converts the returned records into
// TConnectionParameters and persists them via SaveToRegistry.
//
// Format details confirmed against DBeaver source (see
// docs/superpowers/specs/2026-09-23-dbeaver-import-gui-design.md):
//   * credentials: AES-128-CBC, PKCS7, key = hex babb4a9f774ab853c96c2d653dfe544a
//     (DBeaver BaseProjectImpl.LOCAL_KEY_CACHE, a public hardcoded constant),
//     file layout = IV(16 bytes) || ciphertext.

interface

uses
  Classes, SysUtils, fpjson, jsonparser, jsonscanner, base64, fgl;

type
  TDBeaverEngine = (dbeNone, dbeMySQL, dbePg, dbeMSSQL, dbeSQLite,
    dbeInterbase, dbeRedis);

  TDBeaverCredentials = record
    User, Password: string;
  end;

  // A folder parsed from data-sources.json "folders" map.
  TDBeaverFolder = record
    Id, Name, ParentId: string;
  end;

  TDBeaverDataSource = record
    Id, Provider, Driver, Name, FolderId: string;
    Configuration: TJSONObject;   // owned by the parsed root document
  end;

  // Neutral, fully mapped import candidate (engine-agnostic, no HeidiSQL types).
  TDBeaverImportEntry = record
    Name: string;
    Engine: TDBeaverEngine;
    Host: string;
    Port: Integer;
    User: string;
    Password: string;
    Database: string;     // pg/mysql/mssql database name; redis db index (as string)
    SslMode: string;      // pg properties.sslmode / mysql ssl.mode
    WantsSSL: Boolean;
    SshHost: string;      // best-effort SSH fields (not auto-enabled)
    SshPort: Integer;
    SshUser: string;
    SshPrivateKey: string;
    HasPassword: Boolean; // whether a credential password was recovered
    Reason: string;       // skip reason when Engine = dbeNone
    FolderPath: string;   // '/'-joined DBeaver folder chain (parent-first, no
                          // trailing slash); '' = session root
  end;

  TDBeaverImportEntryArray = array of TDBeaverImportEntry;

  TDBeaverImportResult = record
    Entries: TDBeaverImportEntryArray;
    ImportedCount, SkippedCount, NeedsPasswordCount: Integer;
    CredentialsDecrypted: Boolean;
  end;

  TDBeaverFolderArray = array of TDBeaverFolder;
  // credentials keyed by connection id
  TDBeaverCredentialsMap = TFPGMap<string, TDBeaverCredentials>;
  // data sources keyed by connection id
  TDBeaverDataSourceMap = TFPGMap<string, TDBeaverDataSource>;

const
  DBEAVER_AES_KEY: array[0..15] of Byte = (
    $ba, $bb, $4a, $9f, $77, $4a, $b8, $53,
    $c9, $6c, $2d, $65, $3d, $fe, $54, $4a);

// Locate the DBeaver ".dbeaver" workspace directory. Returns '' when explicit
// is empty and no candidate exists. When explicit is non-empty it is returned
// unchanged if it exists.
function DBeaverFindWorkspace(const Explicit: string): string;

// Parse <ws>/data-sources.json. Returns True on success (False = file missing
// or unparseable). On success DataSources and Folders are populated. The caller
// owns the returned objects (DataSources.Configuration objects are freed when
// the root document is freed — keep RootAlive alive while you use them).
function DBeaverLoadDataSources(const Workspace: string;
  out RootAlive: TJSONObject;
  out DataSources: TDBeaverDataSourceMap;
  out Folders: TDBeaverFolderArray): Boolean;

// Decrypt a DBeaver credentials file at the given explicit path ('' = none).
// Returns True if the file existed (Decrypted=True when plaintext was
// recovered; False on missing/unreadable/malformed — malformed input never
// raises). On success Creds is populated keyed by connection id.
function DBeaverLoadCredentials(const CredentialsFile: string;
  out Creds: TDBeaverCredentialsMap;
  out Decrypted: Boolean): Boolean;

// Resolve a DBeaver folder id to a HeidiSQL SessionPath chain: parent-first,
// '/' separated, no trailing slash. '' when FolderId is empty or unknown.
// Path separators inside folder names become '_'; parentFolder cycles are
// bounded (depth 32) so malformed data cannot loop forever.
function DBeaverFolderPath(const Folders: TDBeaverFolderArray; const FolderId: string): string;

// Map provider+driver substring to an engine. dbeNone = unsupported.
function DBeaverDetectEngine(const Provider, Driver: string): TDBeaverEngine;

// Parse a jdbc:<engine>://host[:port]/db[?...] URL. Port=0 when absent.
procedure DBeaverParseJdbcUrl(const Url: string; out Host: string;
  out Port: Integer; out Database: string);

// Read + parse + map an entire workspace into a result. Does NOT touch the
// HeidiSQL registry. TryPasswords=False skips credential loading entirely.
// CredentialsFile='' derives <ws>/credentials-config.json; a non-empty path
// points at an explicit credentials file. Malformed JSON never raises into
// the caller: bad data-sources fails (False), bad credentials degrade to
// Decrypted=False.
function DBeaverImport(const Workspace: string; TryPasswords: Boolean;
  const CredentialsFile: string; out AResult: TDBeaverImportResult): Boolean;

implementation

{ ===== AES-128-CBC decryption (pure Pascal, decrypt only) ===== }

const
  // AES S-box (forward), used by key expansion.
  AES_SBOX: array[0..255] of Byte = (
    $63,$7c,$77,$7b,$f2,$6b,$6f,$c5,$30,$01,$67,$2b,$fe,$d7,$ab,$76,
    $ca,$82,$c9,$7d,$fa,$59,$47,$f0,$ad,$d4,$a2,$af,$9c,$a4,$72,$c0,
    $b7,$fd,$93,$26,$36,$3f,$f7,$cc,$34,$a5,$e5,$f1,$71,$d8,$31,$15,
    $04,$c7,$23,$c3,$18,$96,$05,$9a,$07,$12,$80,$e2,$eb,$27,$b2,$75,
    $09,$83,$2c,$1a,$1b,$6e,$5a,$a0,$52,$3b,$d6,$b3,$29,$e3,$2f,$84,
    $53,$d1,$00,$ed,$20,$fc,$b1,$5b,$6a,$cb,$be,$39,$4a,$4c,$58,$cf,
    $d0,$ef,$aa,$fb,$43,$4d,$33,$85,$45,$f9,$02,$7f,$50,$3c,$9f,$a8,
    $51,$a3,$40,$8f,$92,$9d,$38,$f5,$bc,$b6,$da,$21,$10,$ff,$f3,$d2,
    $cd,$0c,$13,$ec,$5f,$97,$44,$17,$c4,$a7,$7e,$3d,$64,$5d,$19,$73,
    $60,$81,$4f,$dc,$22,$2a,$90,$88,$46,$ee,$b8,$14,$de,$5e,$0b,$db,
    $e0,$32,$3a,$0a,$49,$06,$24,$5c,$c2,$d3,$ac,$62,$91,$95,$e4,$79,
    $e7,$c8,$37,$6d,$8d,$d5,$4e,$a9,$6c,$56,$f4,$ea,$65,$7a,$ae,$08,
    $ba,$78,$25,$2e,$1c,$a6,$b4,$c6,$e8,$dd,$74,$1f,$4b,$bd,$8b,$8a,
    $70,$3e,$b5,$66,$48,$03,$f6,$0e,$61,$35,$57,$b9,$86,$c1,$1d,$9e,
    $e1,$f8,$98,$11,$69,$d9,$8e,$94,$9b,$1e,$87,$e9,$ce,$55,$28,$df,
    $8c,$a1,$89,$0d,$bf,$e6,$42,$68,$41,$99,$2d,$0f,$b0,$54,$bb,$16);

  // AES inverse S-box, used by InvSubBytes.
  AES_INVSBOX: array[0..255] of Byte = (
    $52,$09,$6a,$d5,$30,$36,$a5,$38,$bf,$40,$a3,$9e,$81,$f3,$d7,$fb,
    $7c,$e3,$39,$82,$9b,$2f,$ff,$87,$34,$8e,$43,$44,$c4,$de,$e9,$cb,
    $54,$7b,$94,$32,$a6,$c2,$23,$3d,$ee,$4c,$95,$0b,$42,$fa,$c3,$4e,
    $08,$2e,$a1,$66,$28,$d9,$24,$b2,$76,$5b,$a2,$49,$6d,$8b,$d1,$25,
    $72,$f8,$f6,$64,$86,$68,$98,$16,$d4,$a4,$5c,$cc,$5d,$65,$b6,$92,
    $6c,$70,$48,$50,$fd,$ed,$b9,$da,$5e,$15,$46,$57,$a7,$8d,$9d,$84,
    $90,$d8,$ab,$00,$8c,$bc,$d3,$0a,$f7,$e4,$58,$05,$b8,$b3,$45,$06,
    $d0,$2c,$1e,$8f,$ca,$3f,$0f,$02,$c1,$af,$bd,$03,$01,$13,$8a,$6b,
    $3a,$91,$11,$41,$4f,$67,$dc,$ea,$97,$f2,$cf,$ce,$f0,$b4,$e6,$73,
    $96,$ac,$74,$22,$e7,$ad,$35,$85,$e2,$f9,$37,$e8,$1c,$75,$df,$6e,
    $47,$f1,$1a,$71,$1d,$29,$c5,$89,$6f,$b7,$62,$0e,$aa,$18,$be,$1b,
    $fc,$56,$3e,$4b,$c6,$d2,$79,$20,$9a,$db,$c0,$fe,$78,$cd,$5a,$f4,
    $1f,$dd,$a8,$33,$88,$07,$c7,$31,$b1,$12,$10,$59,$27,$80,$ec,$5f,
    $60,$51,$7f,$a9,$19,$b5,$4a,$0d,$2d,$e5,$7a,$9f,$93,$c9,$9c,$ef,
    $a0,$e0,$3b,$4d,$ae,$2a,$f5,$b0,$c8,$eb,$bb,$3c,$83,$53,$99,$61,
    $17,$2b,$04,$7e,$ba,$77,$d6,$26,$e1,$69,$14,$63,$55,$21,$0c,$7d);

  // Rcon for AES-128 key expansion (rounds 1..10).
  AES_RCON: array[1..10] of Byte = ($01,$02,$04,$08,$10,$20,$40,$80,$1b,$36);

function XTime(b: Byte): Byte; inline;
begin
  Result := (b shl 1) xor (((b shr 7) and 1) * $1b);
end;

function GMul(a, b: Byte): Byte;
var
  i: Integer;
  p: Byte;
begin
  p := 0;
  for i := 0 to 7 do
  begin
    if (b and 1) <> 0 then
      p := p xor a;
    b := b shr 1;
    a := XTime(a);
  end;
  Result := p;
end;

// Expand a 16-byte key into 11 round keys (176 bytes), column-major words.
procedure AesKeyExpansion(const Key: array of Byte; var RoundKeys: array of Byte);
var
  i: Integer;
  temp, rot: array[0..3] of Byte;
begin
  // First 4 words = the key.
  for i := 0 to 15 do
    RoundKeys[i] := Key[i];
  // Words 4..43.
  for i := 4 to 43 do
  begin
    temp[0] := RoundKeys[(i-1)*4+0];
    temp[1] := RoundKeys[(i-1)*4+1];
    temp[2] := RoundKeys[(i-1)*4+2];
    temp[3] := RoundKeys[(i-1)*4+3];
    if (i mod 4) = 0 then
    begin
      // RotWord: [a0,a1,a2,a3] -> [a1,a2,a3,a0], then SubWord via S-box.
      rot[0] := temp[1]; rot[1] := temp[2]; rot[2] := temp[3]; rot[3] := temp[0];
      temp[0] := AES_SBOX[rot[0]] xor AES_RCON[i div 4];
      temp[1] := AES_SBOX[rot[1]];
      temp[2] := AES_SBOX[rot[2]];
      temp[3] := AES_SBOX[rot[3]];
    end;
    RoundKeys[i*4+0] := RoundKeys[(i-4)*4+0] xor temp[0];
    RoundKeys[i*4+1] := RoundKeys[(i-4)*4+1] xor temp[1];
    RoundKeys[i*4+2] := RoundKeys[(i-4)*4+2] xor temp[2];
    RoundKeys[i*4+3] := RoundKeys[(i-4)*4+3] xor temp[3];
  end;
end;

// AES state buffers below are fully written through untyped var parameters
// (Move / key expansion) before their first read; FPC's flow analysis cannot
// track that, so silence the resulting 5057/5058 hints for this section.
{$WARN 5057 off}
{$WARN 5058 off}

// Decrypt one 16-byte block. State is column-major: state[r + 4*c].
procedure AesDecryptBlock(const InBlock: array of Byte;
  const RoundKeys: array of Byte; out OutBlock: array of Byte);
var
  s: array[0..15] of Byte;   // column-major flat state
  round: Integer;

  procedure AddRoundKey(kOff: Integer);
  var
    j: Integer;
  begin
    for j := 0 to 15 do
      s[j] := s[j] xor RoundKeys[kOff + j];
  end;

  procedure InvSubBytes;
  var
    j: Integer;
  begin
    for j := 0 to 15 do
      s[j] := AES_INVSBOX[s[j]];
  end;

  procedure InvShiftRows;
  // row r shifted right by r. index = r + 4*c.
  var
    tmp: Byte;
  begin
    // row 1: [c0 c1 c2 c3] -> [c3 c0 c1 c2]
    tmp := s[1+4*3]; s[1+4*3] := s[1+4*2]; s[1+4*2] := s[1+4*1]; s[1+4*1] := s[1+4*0]; s[1+4*0] := tmp;
    // row 2: shift right by 2
    tmp := s[2+4*0]; s[2+4*0] := s[2+4*2]; s[2+4*2] := tmp;
    tmp := s[2+4*1]; s[2+4*1] := s[2+4*3]; s[2+4*3] := tmp;
    // row 3: shift right by 3 (= left by 1)
    tmp := s[3+4*0]; s[3+4*0] := s[3+4*1]; s[3+4*1] := s[3+4*2]; s[3+4*2] := s[3+4*3]; s[3+4*3] := tmp;
  end;

  procedure InvMixColumns;
  var
    col: Integer;
    a0, a1, a2, a3: Byte;
  begin
    for col := 0 to 3 do
    begin
      a0 := s[0+4*col]; a1 := s[1+4*col]; a2 := s[2+4*col]; a3 := s[3+4*col];
      s[0+4*col] := GMul($0e,a0) xor GMul($0b,a1) xor GMul($0d,a2) xor GMul($09,a3);
      s[1+4*col] := GMul($09,a0) xor GMul($0e,a1) xor GMul($0b,a2) xor GMul($0d,a3);
      s[2+4*col] := GMul($0d,a0) xor GMul($09,a1) xor GMul($0e,a2) xor GMul($0b,a3);
      s[3+4*col] := GMul($0b,a0) xor GMul($0d,a1) xor GMul($09,a2) xor GMul($0e,a3);
    end;
  end;

begin
  Move(InBlock[0], s[0], 16);
  AddRoundKey(160);                // round 10 key (byte offset 10*16)
  for round := 9 downto 1 do
  begin
    InvShiftRows;
    InvSubBytes;
    AddRoundKey(round * 16);       // round key byte offset
    InvMixColumns;
  end;
  InvShiftRows;
  InvSubBytes;
  AddRoundKey(0);
  Move(s[0], OutBlock[0], 16);
end;

// AES-128-CBC decrypt. Data = IV(16) || ciphertext. Returns plaintext bytes
// (without PKCS7 unpadding). Raises EDecryptError on length/alignment errors.
type
  EDecryptError = class(Exception);

function AesCbcDecrypt(const Data: TBytes): TBytes;
var
  RoundKeys: array[0..175] of Byte;
  iv: array[0..15] of Byte;
  prev: array[0..15] of Byte;
  block: array[0..15] of Byte;
  outblk: array[0..15] of Byte;
  i, n, off: Integer;
begin
  if Length(Data) < 32 then
    raise EDecryptError.Create('DBeaver: credentials too short');
  if (Length(Data) - 16) mod 16 <> 0 then
    raise EDecryptError.Create('DBeaver: ciphertext not block-aligned');
  AesKeyExpansion(DBEAVER_AES_KEY, RoundKeys);
  Move(Data[0], iv[0], 16);
  Move(iv[0], prev[0], 16);
  n := Length(Data) - 16;
  SetLength(Result, n);
  off := 16;
  while off < Length(Data) do
  begin
    Move(Data[off], block[0], 16);
    AesDecryptBlock(block, RoundKeys, outblk);
    for i := 0 to 15 do
      Result[off - 16 + i] := outblk[i] xor prev[i];
    Move(block[0], prev[0], 16);
    Inc(off, 16);
  end;
end;

function Pkcs7Unpad(const Data: TBytes): TBytes;
var
  n, i: Integer;
begin
  if Length(Data) = 0 then
    raise EDecryptError.Create('DBeaver: empty plaintext');
  n := Data[Length(Data) - 1];
  if (n < 1) or (n > 16) or (n > Length(Data)) then
    raise EDecryptError.Create('DBeaver: invalid PKCS7 padding');
  for i := Length(Data) - n to Length(Data) - 1 do
    if Data[i] <> n then
      raise EDecryptError.Create('DBeaver: invalid PKCS7 padding');
  SetLength(Result, Length(Data) - n);
  if Length(Result) > 0 then
    Move(Data[0], Result[0], Length(Result));
end;

{$WARN 5057 on}
{$WARN 5058 on}

{ ===== JSON helpers ===== }

// JSON scalar -> string without raising (AsString alone is unsafe on booleans).
function JsonValueToStr(const D: TJSONData): string;
begin
  case D.JSONType of
    jtString, jtNumber:
      Result := D.AsString;
    jtBoolean:
      if D.AsBoolean then
        Result := 'true'
      else
        Result := 'false';
  else
    Result := '';
  end;
end;

function ObjGetString(Obj: TJSONObject; const Key: string): string;
var
  D: TJSONData;
begin
  Result := '';
  if Obj = nil then
    Exit;
  D := Obj.Find(Key);
  if D <> nil then
    Result := JsonValueToStr(D);
end;

function ConfigStr(ds: TDBeaverDataSource; const Key: string): string;
var
  D: TJSONData;
begin
  Result := '';
  if ds.Configuration = nil then
    Exit;
  D := ds.Configuration.Find(Key);
  if D <> nil then
    Result := JsonValueToStr(D);
end;

function ConfigProps(ds: TDBeaverDataSource): TJSONObject;
var
  D: TJSONData;
begin
  Result := nil;
  if ds.Configuration = nil then
    Exit;
  D := ds.Configuration.Find('properties');
  if (D <> nil) and (D.JSONType = jtObject) then
    Result := D as TJSONObject;
end;

function PropStr(ds: TDBeaverDataSource; const Key: string): string;
var
  Props: TJSONObject;
  D: TJSONData;
begin
  Result := '';
  Props := ConfigProps(ds);
  if Props = nil then
    Exit;
  D := Props.Find(Key);
  if D <> nil then
    Result := JsonValueToStr(D);
end;

{ ===== public API ===== }

function DBeaverFindWorkspace(const Explicit: string): string;
var
  Home: string;
  {$IFDEF MSWINDOWS}
  AppData: string;
  {$ENDIF}

  function Exists(const P: string): Boolean;
  begin
    Result := (P <> '') and DirectoryExists(P);
  end;

begin
  Result := '';
  if Explicit <> '' then
  begin
    if Exists(Explicit) then
      Result := IncludeTrailingPathDelimiter(Explicit);
    Exit;
  end;
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Home := '.';
  {$IFDEF MSWINDOWS}
  AppData := GetEnvironmentVariable('APPDATA');
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  if Exists(AppData + '\DBeaverData\workspace6\General\.dbeaver') then
    Result := AppData + '\DBeaverData\workspace6\General\.dbeaver\';
  {$ELSE}
  {$IFDEF DARWIN}
  if Exists(Home + '/Library/DBeaverData/workspace6/General/.dbeaver') then
    Result := Home + '/Library/DBeaverData/workspace6/General/.dbeaver/'
  else if Exists(Home + '/Library/Application Support/DBeaverData/workspace6/General/.dbeaver') then
    Result := Home + '/Library/Application Support/DBeaverData/workspace6/General/.dbeaver/';
  {$ELSE}
  // Linux + other unix
  if Exists(Home + '/.local/share/DBeaverData/workspace6/General/.dbeaver') then
    Result := Home + '/.local/share/DBeaverData/workspace6/General/.dbeaver/'
  else if Exists(Home + '/snap/dbeaver-ce/current/.local/share/DBeaverData/workspace6/General/.dbeaver') then
    Result := Home + '/snap/dbeaver-ce/current/.local/share/DBeaverData/workspace6/General/.dbeaver/'
  else if Exists(Home + '/.var/app/io.dbeaver.DBeaverCommunity/data/DBeaverData/workspace6/General/.dbeaver') then
    Result := Home + '/.var/app/io.dbeaver.DBeaverCommunity/data/DBeaverData/workspace6/General/.dbeaver/';
  {$ENDIF}
  {$ENDIF}
end;

function DBeaverLoadDataSources(const Workspace: string;
  out RootAlive: TJSONObject;
  out DataSources: TDBeaverDataSourceMap;
  out Folders: TDBeaverFolderArray): Boolean;
var
  Path: string;
  fs: TFileStream;
  Parser: TJSONParser;
  Root, Conns, Flds, FolderObj, Conn: TJSONObject;
  Data: TJSONData;
  i: Integer;
  ds: TDBeaverDataSource;
  fld: TDBeaverFolder;
begin
  Result := False;
  RootAlive := nil;
  DataSources := nil;
  Folders := nil;
  Path := IncludeTrailingPathDelimiter(Workspace) + 'data-sources.json';
  if not FileExists(Path) then
    Exit;
  fs := nil;
  Parser := nil;
  Root := nil;
  try
    try
      fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
      Parser := TJSONParser.Create(fs, [joUTF8]);
      Data := Parser.Parse;
      if Data = nil then
        Exit;
      if Data.JSONType <> jtObject then
      begin
        Data.Free;
        Exit;
      end;
      Root := Data as TJSONObject;
      RootAlive := Root;

      DataSources := TDBeaverDataSourceMap.Create;

      // Folders
      Data := Root.Find('folders');
      if (Data <> nil) and (Data.JSONType = jtObject) then
      begin
        Flds := Data as TJSONObject;
        for i := 0 to Flds.Count - 1 do
        begin
          FolderObj := Flds.Items[i] as TJSONObject;
          fld.Id := Flds.Names[i];
          fld.Name := ObjGetString(FolderObj, 'name');
          fld.ParentId := ObjGetString(FolderObj, 'parentFolder');
          SetLength(Folders, Length(Folders) + 1);
          Folders[High(Folders)] := fld;
        end;
      end;

      // Connections
      Data := Root.Find('connections');
      if (Data <> nil) and (Data.JSONType = jtObject) then
      begin
        Conns := Data as TJSONObject;
        for i := 0 to Conns.Count - 1 do
        begin
          ds.Id := Conns.Names[i];
          Conn := Conns.Items[i] as TJSONObject;
          ds.Provider := ObjGetString(Conn, 'provider');
          ds.Driver := ObjGetString(Conn, 'driver');
          ds.Name := ObjGetString(Conn, 'name');
          ds.FolderId := ObjGetString(Conn, 'folder');
          Data := Conn.Find('configuration');
          if (Data <> nil) and (Data.JSONType = jtObject) then
            ds.Configuration := Data as TJSONObject
          else
            ds.Configuration := nil;
          DataSources.Add(ds.Id, ds);
          // Configuration object is owned by RootAlive; the map stores a copy
          // of the record (TJSONObject pointer copied by value).
        end;
      end;
      Result := True;
    except
      // Malformed data-sources.json must not raise into the UI: fail
      // gracefully (Result stays False; everything is cleaned up below).
      Result := False;
    end;
  finally
    Parser.Free;
    fs.Free;
    // RootAlive is returned to caller (not freed here). On failure, clean up.
    if not Result then
    begin
      if Assigned(Root) then
      begin
        Root.Free;
        Root := nil;
      end;
      RootAlive := nil;
      DataSources.Free;
      DataSources := nil;
      SetLength(Folders, 0);
    end;
  end;
end;

function DBeaverLoadCredentials(const CredentialsFile: string;
  out Creds: TDBeaverCredentialsMap;
  out Decrypted: Boolean): Boolean;
var
  Path: string;
  fs: TFileStream;
  Data, Plain: TBytes;
  Parser: TJSONParser;
  JsonData: TJSONData;
  Root, ConnObj, Node: TJSONObject;
  i: Integer;
  cr: TDBeaverCredentials;
  S, Decoded: RawByteString;
begin
  Result := False;
  Creds := nil;
  Decrypted := False;
  Path := CredentialsFile;
  if not FileExists(Path) then
    Exit;
  Result := True; // file existed
  Creds := TDBeaverCredentialsMap.Create;
  fs := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Data, fs.Size);
    if Length(Data) > 0 then
      fs.ReadBuffer(Data[0], Length(Data));
  finally
    fs.Free;
  end;

  // 1. AES-128-CBC whole-file decrypt.
  S := '';
  try
    Plain := Pkcs7Unpad(AesCbcDecrypt(Data));
    SetLength(S, Length(Plain));
    if Length(Plain) > 0 then
      Move(Plain[0], S[1], Length(Plain));
  except
    S := '';
  end;

  // 2. Plain JSON fallback.
  if (S = '') or (S[1] <> '{') then
  begin
    SetLength(S, Length(Data));
    if Length(Data) > 0 then
      Move(Data[0], S[1], Length(Data));
  end;

  // 3. Base64 fallback.
  if (S = '') or (S[1] <> '{') then
  begin
    try
      Decoded := DecodeStringBase64(S);
      if (Decoded <> '') and (Decoded[1] = '{') then
        S := Decoded
      else
        S := '';
    except
      S := '';
    end;
  end;

  if (S = '') or (S[1] <> '{') then
    Exit; // Decrypted stays False, empty map returned.

  Parser := TJSONParser.Create(S, [joUTF8]);
  JsonData := nil;
  try
    try
      JsonData := Parser.Parse;
      if (JsonData = nil) or (JsonData.JSONType <> jtObject) then
        Exit;
      Root := JsonData as TJSONObject;
      Decrypted := True;
      for i := 0 to Root.Count - 1 do
      begin
        ConnObj := Root.Items[i] as TJSONObject;
        Node := ConnObj.Find('#connection') as TJSONObject;
        if Node = nil then
          Continue;
        cr.User := ObjGetString(Node, 'user');
        cr.Password := ObjGetString(Node, 'password');
        Creds.Add(Root.Names[i], cr);
      end;
    except
      // Malformed credentials JSON must never abort the import: keep whatever
      // was parsed; entries without a recovered password fall back to
      // LoginPrompt on connect.
    end;
  finally
    JsonData.Free;
    Parser.Free;
  end;
end;

function DBeaverFolderPath(const Folders: TDBeaverFolderArray; const FolderId: string): string;
var
  Chain, Id, Seg: string;
  i, Depth, Found: Integer;

  function SanitizeSeg(const S: string): string;
  var
    k: Integer;
  begin
    Result := S;
    for k := Length(Result) downto 1 do
      if (Result[k] = '/') or (Result[k] = ':') or (Result[k] = #0) then
        Result[k] := '_';
  end;

begin
  Result := '';
  Id := FolderId;
  Chain := '';
  Depth := 0;
  // Walk parentFolder links upward (cycle-safe). Unknown ids drop the rest
  // of the chain instead of failing the whole import.
  while (Id <> '') and (Depth < 32) do
  begin
    Found := -1;
    for i := 0 to High(Folders) do
      if Folders[i].Id = Id then
      begin
        Found := i;
        Break;
      end;
    if Found < 0 then
      Break;
    Seg := Folders[Found].Name;
    if Seg = '' then
      Seg := Folders[Found].Id;
    Chain := SanitizeSeg(Seg) + '/' + Chain;
    Id := Folders[Found].ParentId;
    Inc(Depth);
  end;
  if Chain <> '' then
    SetLength(Chain, Length(Chain) - 1);
  Result := Chain;
end;

function DBeaverDetectEngine(const Provider, Driver: string): TDBeaverEngine;
var
  S: string;
begin
  Result := dbeNone;
  S := LowerCase(Provider + ' ' + Driver);
  if Pos('mariadb', S) > 0 then
    Result := dbeMySQL
  else if Pos('mysql', S) > 0 then
    Result := dbeMySQL
  else if Pos('postgres', S) > 0 then
    Result := dbePg
  else if Pos('sqlserver', S) > 0 then
    Result := dbeMSSQL
  else if Pos('mssql', S) > 0 then
    Result := dbeMSSQL
  else if Pos('firebird', S) > 0 then
    Result := dbeInterbase
  else if Pos('interbase', S) > 0 then
    Result := dbeInterbase
  else if Pos('sqlite', S) > 0 then
    Result := dbeSQLite
  else if Pos('redis', S) > 0 then
    Result := dbeRedis;
end;

procedure DBeaverParseJdbcUrl(const Url: string; out Host: string;
  out Port: Integer; out Database: string);
var
  S, Rest, Authority: string;
  idx, q, slash, colon: Integer;
begin
  Host := '';
  Port := 0;
  Database := '';
  S := Url;
  // Strip "jdbc:" prefix.
  if Pos('jdbc:', S) = 1 then
    Delete(S, 1, 5);
  idx := Pos('://', S);
  if idx = 0 then
    Exit;
  Rest := Copy(S, idx + 3, MaxInt);
  // Drop query string.
  q := Pos('?', Rest);
  if q > 0 then
    Rest := Copy(Rest, 1, q - 1);
  slash := Pos('/', Rest);
  if slash > 0 then
  begin
    Authority := Copy(Rest, 1, slash - 1);
    Database := Copy(Rest, slash + 1, MaxInt);
  end
  else
    Authority := Rest;
  colon := LastDelimiter(':', Authority);
  if colon > 0 then
  begin
    Host := Copy(Authority, 1, colon - 1);
    Port := StrToIntDef(Copy(Authority, colon + 1, MaxInt), 0);
  end
  else
    Host := Authority;
end;

function DefaultPortForEngine(Engine: TDBeaverEngine): Integer;
begin
  case Engine of
    dbeMySQL: Result := 3306;
    dbePg: Result := 5432;
    dbeMSSQL: Result := 1433;
    dbeInterbase: Result := 3050;
    dbeRedis: Result := 6379;
  else
    Result := 0;
  end;
end;

function DBeaverImport(const Workspace: string; TryPasswords: Boolean;
  const CredentialsFile: string; out AResult: TDBeaverImportResult): Boolean;
var
  Root: TJSONObject;
  DataSources: TDBeaverDataSourceMap;
  Folders: TDBeaverFolderArray;
  Creds: TDBeaverCredentialsMap;
  CredsDecrypted: Boolean;
  i, CrIdx: Integer;
  ds: TDBeaverDataSource;
  cr: TDBeaverCredentials;
  Entry: TDBeaverImportEntry;
  SPort, SslMode: string;
  CredPath: string;
  Host2, Db2: string;
  Port2: Integer;
begin
  AResult.Entries := nil;
  AResult.ImportedCount := 0;
  AResult.SkippedCount := 0;
  AResult.NeedsPasswordCount := 0;
  AResult.CredentialsDecrypted := False;

  if not DBeaverLoadDataSources(Workspace, Root, DataSources, Folders) then
    Exit(False);

  Creds := nil;
  CredsDecrypted := False;
  try
    if TryPasswords then
    begin
      CredPath := CredentialsFile;
      if CredPath = '' then
        CredPath := IncludeTrailingPathDelimiter(Workspace) + 'credentials-config.json';
      DBeaverLoadCredentials(CredPath, Creds, CredsDecrypted);
    end;
    AResult.CredentialsDecrypted := CredsDecrypted;

    for i := 0 to DataSources.Count - 1 do
    begin
      ds := DataSources.Data[i];
      Entry.Name := ds.Name;
      if Entry.Name = '' then
        Entry.Name := ds.Id;
      Entry.Engine := DBeaverDetectEngine(ds.Provider, ds.Driver);
      Entry.Reason := '';
      Entry.FolderPath := DBeaverFolderPath(Folders, ds.FolderId);

      if Entry.Engine = dbeNone then
      begin
        Entry.Reason := 'Unsupported provider/driver: ' + ds.Provider + '/' + ds.Driver;
        // Clear per-connection fields so a skipped entry never carries stale
        // data from the previous loop iteration.
        Entry.Host := '';
        Entry.Port := 0;
        Entry.User := '';
        Entry.Password := '';
        Entry.Database := '';
        Entry.SslMode := '';
        Entry.WantsSSL := False;
        Entry.SshHost := '';
        Entry.SshPort := 0;
        Entry.SshUser := '';
        Entry.SshPrivateKey := '';
        Entry.HasPassword := False;
        Inc(AResult.SkippedCount);
      end
      else
      begin
        Entry.Host := ConfigStr(ds, 'host');
        SPort := ConfigStr(ds, 'port');
        Entry.Port := StrToIntDef(SPort, 0);
        Entry.Database := ConfigStr(ds, 'database');

        // JDBC url fallback for host/port/database.
        if Entry.Host = '' then
        begin
          DBeaverParseJdbcUrl(ConfigStr(ds, 'url'), Host2, Port2, Db2);
          Entry.Host := Host2;
          if Entry.Port = 0 then
            Entry.Port := Port2;
          if Entry.Database = '' then
            Entry.Database := Db2;
        end;
        if Entry.Port = 0 then
          Entry.Port := DefaultPortForEngine(Entry.Engine);

        // Credentials.
        Entry.HasPassword := False;
        Entry.Password := '';
        Entry.User := '';
        cr.User := '';
        cr.Password := '';
        CrIdx := -1;
        if Creds <> nil then
          CrIdx := Creds.IndexOf(ds.Id);
        if CrIdx >= 0 then
        begin
          cr := Creds.Data[CrIdx];
          Entry.User := cr.User;
          if cr.User = '' then
            Entry.User := ConfigStr(ds, 'user');
          Entry.Password := cr.Password;
          Entry.HasPassword := cr.Password <> '';
        end
        else
        begin
          Entry.User := ConfigStr(ds, 'user');
        end;

        if not Entry.HasPassword then
          Inc(AResult.NeedsPasswordCount);

        // SSL: pg uses properties.sslmode; mysql uses properties["ssl.mode"] /
        // "ssl.use". Map require/verify* to WantsSSL.
        SslMode := PropStr(ds, 'sslmode');
        if SslMode = '' then
          SslMode := LowerCase(PropStr(ds, 'ssl.mode'));
        Entry.SslMode := SslMode;
        Entry.WantsSSL := (SslMode = 'require') or (SslMode = 'verify-ca') or
          (SslMode = 'verify-full') or (SslMode = 'verifyidentity') or
          (PropStr(ds, 'ssl.use') = 'true');

        // SSH (best-effort field capture, not auto-enabled).
        Entry.SshHost := PropStr(ds, 'ssh.host');
        if Entry.SshHost = '' then
          Entry.SshHost := ConfigStr(ds, 'sshHost');
        Entry.SshPort := StrToIntDef(PropStr(ds, 'ssh.port'), 0);
        if Entry.SshPort = 0 then
          Entry.SshPort := StrToIntDef(ConfigStr(ds, 'sshPort'), 0);
        Entry.SshUser := PropStr(ds, 'ssh.user');
        if Entry.SshUser = '' then
          Entry.SshUser := ConfigStr(ds, 'sshUser');
        Entry.SshPrivateKey := PropStr(ds, 'ssh.key.path');
        if Entry.SshPrivateKey = '' then
          Entry.SshPrivateKey := ConfigStr(ds, 'sshKeyPath');

        Inc(AResult.ImportedCount);
      end;

      SetLength(AResult.Entries, Length(AResult.Entries) + 1);
      AResult.Entries[High(AResult.Entries)] := Entry;
    end;
  finally
    Root.Free;
    DataSources.Free;
    Creds.Free;
  end;
  Exit(True);
end;

end.
