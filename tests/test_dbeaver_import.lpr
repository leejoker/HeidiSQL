program test_dbeaver_import;

{$mode delphi}{$H+}

// Standalone unit tests for dbeaver_import (pure logic, no LCL/dbconnection).
// Build: see /tmp/fpcbuild.sh or:
//   fpc -Mdelphi -Fu<rtl> -Fu<fcl-json> ... -Fusource tests/test_dbeaver_import.lpr

uses
  {$IFDEF UNIX} cthreads, cwstring, {$ENDIF}
  Classes, SysUtils, base64, fpjson, jsonparser, jsonscanner,
  dbeaver_import;

var
  Pass, Fail: Integer;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
  begin
    Inc(Pass);
    writeln('  PASS: ', Name);
  end
  else
  begin
    Inc(Fail);
    writeln('  FAIL: ', Name);
  end;
end;

procedure CheckEq(const Name, Got, Expect: string);
begin
  Check(Name + ' (got="' + Got + '")', Got = Expect);
end;

// --- Build an encrypted credentials-config.json fixture using the known
// DBeaver key + a fixed IV, so we validate the AES implementation against
// an independently-generated ciphertext. We generate it at runtime with a
// tiny AES *encrypt* routine embedded here (mirror of the decrypt path).
const
  FIX_B64: AnsiString =
    'AAECAwQFBgcICQoLDA0OD/mLu49KDaYSPdj7Xz1yJV9sAtaUbmlo2n8Xr9x0g3L7' +
    'IwBUk2/w8tgfwJyqQHS9imGYuLpn6eUd9nVKJpBf3xlHkZt/tKen8Ky2e5PWdGzf';
  // Decodes to IV(000102...0f) || ciphertext of:
  //   {"pg-abc":{"#connection":{"user":"readonly","password":"s3cret"}}}

// Minimal AES-128 encrypt block (for fixture generation only).
var
  SBOX: array[0..255] of Byte;

procedure InitSBox;
const
  S: array[0..255] of Byte = (
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
var i: Integer;
begin
  for i := 0 to 255 do SBOX[i] := S[i];
end;

function XT(b: Byte): Byte; inline;
begin
  Result := (b shl 1) xor (((b shr 7) and 1) * $1b);
end;

function GM(a, b: Byte): Byte;
var i: Integer; p: Byte;
begin
  p := 0;
  for i := 0 to 7 do
  begin
    if (b and 1) <> 0 then p := p xor a;
    b := b shr 1;
    a := XT(a);
  end;
  Result := p;
end;

procedure ExpandKey(const Key: array of Byte; var rk: array of Byte);
var i: Integer; temp, rot: array[0..3] of Byte;
const RCON: array[1..10] of Byte = ($01,$02,$04,$08,$10,$20,$40,$80,$1b,$36);
begin
  for i := 0 to 15 do rk[i] := Key[i];
  for i := 4 to 43 do
  begin
    temp[0]:=rk[(i-1)*4]; temp[1]:=rk[(i-1)*4+1]; temp[2]:=rk[(i-1)*4+2]; temp[3]:=rk[(i-1)*4+3];
    if (i mod 4)=0 then
    begin
      rot[0]:=temp[1]; rot[1]:=temp[2]; rot[2]:=temp[3]; rot[3]:=temp[0];
      temp[0]:=SBOX[rot[0]] xor RCON[i div 4];
      temp[1]:=SBOX[rot[1]]; temp[2]:=SBOX[rot[2]]; temp[3]:=SBOX[rot[3]];
    end;
    rk[i*4]:=rk[(i-4)*4] xor temp[0];
    rk[i*4+1]:=rk[(i-4)*4+1] xor temp[1];
    rk[i*4+2]:=rk[(i-4)*4+2] xor temp[2];
    rk[i*4+3]:=rk[(i-4)*4+3] xor temp[3];
  end;
end;

procedure EncBlock(const inp: array of Byte; const rk: array of Byte; out outp: array of Byte);
var s: array[0..15] of Byte; round, r, c: Integer;
  a0,a1,a2,a3: Byte;
  procedure AddRK(k: Integer);
  var j: Integer;
  begin for j:=0 to 15 do s[j]:=s[j] xor rk[k+j]; end;
  procedure SubBytes;
  var j: Integer;
  begin for j:=0 to 15 do s[j]:=SBOX[s[j]]; end;
  procedure ShiftRows;
  var tmp: Byte;
  begin
    // row1 left 1
    tmp:=s[1+4*0]; s[1+4*0]:=s[1+4*1]; s[1+4*1]:=s[1+4*2]; s[1+4*2]:=s[1+4*3]; s[1+4*3]:=tmp;
    // row2 left 2
    tmp:=s[2+4*0]; s[2+4*0]:=s[2+4*2]; s[2+4*2]:=tmp;
    tmp:=s[2+4*1]; s[2+4*1]:=s[2+4*3]; s[2+4*3]:=tmp;
    // row3 left 3
    tmp:=s[3+4*0]; s[3+4*0]:=s[3+4*3]; s[3+4*3]:=s[3+4*2]; s[3+4*2]:=s[3+4*1]; s[3+4*1]:=tmp;
  end;
  procedure MixCols;
  var col: Integer;
  begin
    for col:=0 to 3 do
    begin
      a0:=s[0+4*col]; a1:=s[1+4*col]; a2:=s[2+4*col]; a3:=s[3+4*col];
      s[0+4*col]:=GM(2,a0) xor GM(3,a1) xor a2 xor a3;
      s[1+4*col]:=a0 xor GM(2,a1) xor GM(3,a2) xor a3;
      s[2+4*col]:=a0 xor a1 xor GM(2,a2) xor GM(3,a3);
      s[3+4*col]:=GM(3,a0) xor a1 xor a2 xor GM(2,a3);
    end;
  end;
begin
  Move(inp[0], s[0], 16);
  AddRK(0);
  for round := 1 to 9 do
  begin
    SubBytes; ShiftRows; MixCols; AddRK(round*16);
  end;
  SubBytes; ShiftRows; AddRK(160);
  Move(s[0], outp[0], 16);
end;

// Encrypt plaintext with AES-128-CBC, return IV(16)||ciphertext (PKCS7 padded).
function EncryptFixture(const Plain: RawByteString): TBytes;
var
  rk: array[0..175] of Byte;
  iv, prev, blk, ob: array[0..15] of Byte;
  padded: TBytes;
  i, pad, n, off: Integer;
begin
  InitSBox;
  ExpandKey(DBEAVER_AES_KEY, rk);
  for i := 0 to 15 do iv[i] := Byte(i); // IV = 00 01 02 ... 0f
  // PKCS7 pad
  pad := 16 - (Length(Plain) mod 16);
  if pad = 0 then pad := 16;
  SetLength(padded, Length(Plain) + pad);
  Move(Plain[1], padded[0], Length(Plain));
  for i := Length(Plain) to Length(Plain)+pad-1 do padded[i] := pad;
  SetLength(Result, 16 + Length(padded));
  Move(iv[0], Result[0], 16);
  Move(iv[0], prev[0], 16);
  off := 0;
  n := Length(padded);
  while off < n do
  begin
    for i := 0 to 15 do blk[i] := padded[off+i] xor prev[i];
    EncBlock(blk, rk, ob);
    Move(ob[0], Result[16+off], 16);
    Move(ob[0], prev[0], 16);
    Inc(off, 16);
  end;
end;

procedure WriteFile(const Path, Data: AnsiString);
var f: TextFile;
begin
  AssignFile(f, Path); Rewrite(f); Write(f, Data); CloseFile(f);
end;

procedure WriteBytes(const Path: string; const B: TBytes);
var fs: TFileStream;
begin
  fs := TFileStream.Create(Path, fmCreate);
  try
    if Length(B) > 0 then fs.Write(B[0], Length(B));
  finally
    fs.Free;
  end;
end;

procedure TestDecryptRoundTrip;
var
  Tmp: string;
  Plain: RawByteString;
  ct: TBytes;
  cr: TDBeaverCredentialsMap;
  Decrypted: Boolean;
  idx: Integer;
begin
  writeln('AES-128-CBC credential decrypt round-trip');
  Tmp := GetTempDir + 'dbimp-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  Plain := '{"pg-abc":{"#connection":{"user":"readonly","password":"s3cret"}}}';
  ct := EncryptFixture(Plain);
  WriteBytes(Tmp + 'credentials-config.json', ct);
  cr := nil;
  if DBeaverLoadCredentials(Tmp + 'credentials-config.json', cr, Decrypted) then
  begin
    Check('credentials file existed', True);
    Check('credentials decrypted', Decrypted);
    if cr <> nil then
    begin
      idx := cr.IndexOf('pg-abc');
      Check('pg-abc found', idx >= 0);
      if idx >= 0 then
      begin
        CheckEq('user', cr.Data[idx].User, 'readonly');
        CheckEq('password', cr.Data[idx].Password, 's3cret');
      end;
    end;
  end
  else
    Check('credentials loaded', False);
  cr.Free;
  DeleteFile(Tmp + 'credentials-config.json');
  RemoveDir(Tmp);
end;

procedure TestKnownAnswerFixture;
var
  cr: TDBeaverCredentialsMap;
  Decrypted: Boolean;
  Tmp: string;
  Raw: AnsiString;
  RawBytes: TBytes;
  idx: Integer;
begin
  writeln('AES known-answer fixture (precomputed ciphertext)');
  Tmp := GetTempDir + 'dbimpka-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  Raw := DecodeStringBase64(FIX_B64);
  SetLength(RawBytes, Length(Raw));
  if Length(Raw) > 0 then
    Move(Raw[1], RawBytes[0], Length(Raw));
  WriteBytes(Tmp + 'credentials-config.json', RawBytes);
  cr := nil;
  if DBeaverLoadCredentials(Tmp + 'credentials-config.json', cr, Decrypted) then
  begin
    Check('fixture decrypted', Decrypted);
    if cr <> nil then
    begin
      idx := cr.IndexOf('pg-abc');
      Check('fixture pg-abc found', idx >= 0);
      if idx >= 0 then
      begin
        CheckEq('fixture user', cr.Data[idx].User, 'readonly');
        CheckEq('fixture password', cr.Data[idx].Password, 's3cret');
      end;
    end;
  end
  else
    Check('fixture loaded', False);
  cr.Free;
  DeleteFile(Tmp + 'credentials-config.json');
  RemoveDir(Tmp);
end;

procedure TestPlainJsonFallback;
var
  Tmp: string;
  cr: TDBeaverCredentialsMap;
  Decrypted: Boolean;
  idx: Integer;
begin
  writeln('credentials plain-JSON fallback');
  Tmp := GetTempDir + 'dbimppj-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'credentials-config.json',
    '{"x":{"#connection":{"user":"u","password":"p"}}}');
  cr := nil;
  DBeaverLoadCredentials(Tmp + 'credentials-config.json', cr, Decrypted);
  Check('plain json decrypted', Decrypted);
  if cr <> nil then
  begin
    idx := cr.IndexOf('x');
    Check('plain json found', idx >= 0);
    if idx >= 0 then
      CheckEq('plain json pw', cr.Data[idx].Password, 'p');
  end;
  cr.Free;
  DeleteFile(Tmp + 'credentials-config.json');
  RemoveDir(Tmp);
end;

procedure TestMissingCredentials;
var
  Tmp: string;
  cr: TDBeaverCredentialsMap;
  Decrypted: Boolean;
begin
  writeln('credentials missing file');
  Tmp := GetTempDir + 'dbimpmiss-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  cr := nil;
  Check('missing returns false', DBeaverLoadCredentials(Tmp + 'credentials-config.json', cr, Decrypted) = False);
  Check('missing -> nil map', cr = nil);
  RemoveDir(Tmp);
end;

procedure TestDetectEngine;
begin
  writeln('provider/driver detection');
  Check('mysql8 -> mysql', DBeaverDetectEngine('mysql', 'mysql8') = dbeMySQL);
  Check('mariadb -> mysql', DBeaverDetectEngine('mariadb', 'mariadb-jdbc') = dbeMySQL);
  Check('postgres -> pg', DBeaverDetectEngine('postgresql', 'postgres-jdbc') = dbePg);
  Check('sqlserver -> mssql', DBeaverDetectEngine('sqlserver', 'mssql-jdbc') = dbeMSSQL);
  Check('mssql -> mssql', DBeaverDetectEngine('dbtype', 'mssql') = dbeMSSQL);
  Check('sqlite -> sqlite', DBeaverDetectEngine('sqlite', 'sqlite-jdbc') = dbeSQLite);
  Check('firebird -> interbase', DBeaverDetectEngine('generic', 'firebird') = dbeInterbase);
  Check('interbase -> interbase', DBeaverDetectEngine('interbase', 'ib') = dbeInterbase);
  Check('redis -> redis', DBeaverDetectEngine('generic', 'redis-ce') = dbeRedis);
  Check('oracle -> none', DBeaverDetectEngine('oracle', 'ojdbc') = dbeNone);
  Check('empty -> none', DBeaverDetectEngine('', '') = dbeNone);
end;

procedure TestParseJdbcUrl;
var
  h, db: string; p: Integer;
begin
  writeln('JDBC URL parsing');
  DBeaverParseJdbcUrl('jdbc:postgresql://10.0.0.5:5432/appdb?sslmode=require', h, p, db);
  CheckEq('jdbc host', h, '10.0.0.5');
  Check('jdbc port', p = 5432);
  CheckEq('jdbc db', db, 'appdb');
  DBeaverParseJdbcUrl('jdbc:postgresql://h/db', h, p, db);
  CheckEq('jdbc noport host', h, 'h');
  Check('jdbc noport port=0', p = 0);
  CheckEq('jdbc noport db', db, 'db');
  DBeaverParseJdbcUrl('jdbc:postgresql://h:5432', h, p, db);
  CheckEq('jdbc nodb host', h, 'h');
  Check('jdbc nodb port', p = 5432);
  Check('jdbc nodb db empty', db = '');
  DBeaverParseJdbcUrl('not-a-url', h, p, db);
  Check('jdbc bad -> empty', (h='') and (p=0) and (db=''));
end;

procedure TestImportEndToEnd;
var
  Tmp: string;
  dsJson: AnsiString;
  ct: TBytes;
  r: TDBeaverImportResult;
  i: Integer;
  foundPg, foundRedis, foundOra: Boolean;
  e: TDBeaverImportEntry;
begin
  writeln('end-to-end Import (mixed engines + credentials)');
  Tmp := GetTempDir + 'dbimpe2e-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  dsJson :=
    '{"connections":{' +
      '"pg-abc":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg-prod","configuration":{"host":"10.0.0.5","port":"5432","database":"appdb","properties":{"sslmode":"require"}}},' +
      '"redis-xyz":{"provider":"generic","driver":"redis-ce","name":"redis-cache","configuration":{"host":"10.0.0.6","port":"6379","database":"2"}},' +
      '"ora-1":{"provider":"oracle","driver":"ojdbc8","name":"oradb","configuration":{"host":"h","port":"1521"}}' +
    '}}';
  WriteFile(Tmp + 'data-sources.json', dsJson);
  ct := EncryptFixture('{"pg-abc":{"#connection":{"user":"readonly","password":"s3cret"}},"redis-xyz":{"#connection":{"user":"","password":"rwpw"}}}');
  WriteBytes(Tmp + 'credentials-config.json', ct);

  if DBeaverImport(Tmp, True, '', r) then
  begin
    Check('import succeeded', True);
    Check('imported count = 2', r.ImportedCount = 2);
    Check('skipped count = 1', r.SkippedCount = 1);
    Check('needs-password = 0', r.NeedsPasswordCount = 0);
    Check('credentials decrypted', r.CredentialsDecrypted);
    foundPg := False; foundRedis := False; foundOra := False;
    for i := 0 to High(r.Entries) do
    begin
      e := r.Entries[i];
      if e.Name = 'pg-prod' then
      begin
        foundPg := True;
        Check('pg engine', e.Engine = dbePg);
        CheckEq('pg host', e.Host, '10.0.0.5');
        Check('pg port', e.Port = 5432);
        CheckEq('pg db', e.Database, 'appdb');
        CheckEq('pg user', e.User, 'readonly');
        CheckEq('pg pw', e.Password, 's3cret');
        Check('pg ssl', e.WantsSSL);
      end;
      if e.Name = 'redis-cache' then
      begin
        foundRedis := True;
        Check('redis engine', e.Engine = dbeRedis);
        CheckEq('redis db', e.Database, '2');
        CheckEq('redis pw', e.Password, 'rwpw');
      end;
      if e.Name = 'oradb' then
      begin
        foundOra := True;
        Check('ora skipped engine', e.Engine = dbeNone);
      end;
    end;
    Check('pg entry present', foundPg);
    Check('redis entry present', foundRedis);
    Check('ora entry present (skipped)', foundOra);
  end
  else
    Check('import succeeded', False);

  DeleteFile(Tmp + 'data-sources.json');
  DeleteFile(Tmp + 'credentials-config.json');
  RemoveDir(Tmp);
end;

procedure TestImportNoCredentials;
var
  Tmp: string;
  r: TDBeaverImportResult;
begin
  writeln('Import without credentials file (needs-password)');
  Tmp := GetTempDir + 'dbimpnc-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'data-sources.json',
    '{"connections":{"pg-1":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg","configuration":{"host":"h","port":"5432"}}}}');
  if DBeaverImport(Tmp, True, '', r) then
  begin
    Check('imported=1', r.ImportedCount = 1);
    Check('needs-password=1', r.NeedsPasswordCount = 1);
    Check('credentials not decrypted', not r.CredentialsDecrypted);
  end
  else
    Check('import ok', False);
  DeleteFile(Tmp + 'data-sources.json');
  RemoveDir(Tmp);
end;

procedure TestImportMissingWorkspace;
var
  r: TDBeaverImportResult;
begin
  writeln('Import missing workspace');
  Check('missing -> false', DBeaverImport('/nonexistent/path/xyz', True, '', r) = False);
end;

procedure TestNameFallbackToId;
var
  Tmp: string;
  r: TDBeaverImportResult;
begin
  writeln('connection name falls back to id');
  Tmp := GetTempDir + 'dbimpnf-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'data-sources.json',
    '{"connections":{"pg-abc":{"provider":"postgresql","driver":"postgres-jdbc","configuration":{"host":"h","port":"5432"}}}}');
  if DBeaverImport(Tmp, False, '', r) then
  begin
    Check('one entry', Length(r.Entries) = 1);
    if Length(r.Entries) = 1 then
      CheckEq('name = id', r.Entries[0].Name, 'pg-abc');
  end
  else
    Check('import ok', False);
  DeleteFile(Tmp + 'data-sources.json');
  RemoveDir(Tmp);
end;

procedure TestMalformedDataSources;
var
  Tmp: string;
  r: TDBeaverImportResult;
begin
  writeln('malformed data-sources.json degrades gracefully');
  Tmp := GetTempDir + 'dbimpbad-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'data-sources.json', '{"connections": {');
  Check('malformed ds -> false', DBeaverImport(Tmp, True, '', r) = False);
  Check('malformed ds -> no entries', Length(r.Entries) = 0);
  DeleteFile(Tmp + 'data-sources.json');
  RemoveDir(Tmp);
end;

procedure TestMalformedCredentialsContinue;
var
  Tmp: string;
  r: TDBeaverImportResult;
begin
  writeln('malformed credentials JSON does not abort the import');
  Tmp := GetTempDir + 'dbimpbc-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'data-sources.json',
    '{"connections":{"pg-1":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg","configuration":{"host":"h","port":"5432"}}}}');
  WriteFile(Tmp + 'credentials-config.json', '{"broken":');
  if DBeaverImport(Tmp, True, '', r) then
  begin
    Check('import still succeeds', True);
    Check('credentials not decrypted', not r.CredentialsDecrypted);
    Check('entry present', Length(r.Entries) = 1);
    Check('needs-password = 1', r.NeedsPasswordCount = 1);
  end
  else
    Check('import ok', False);
  DeleteFile(Tmp + 'data-sources.json');
  DeleteFile(Tmp + 'credentials-config.json');
  RemoveDir(Tmp);
end;

procedure TestExplicitCredentialsPath;
var
  Tmp: string;
  r: TDBeaverImportResult;
begin
  writeln('explicit credentials file path');
  Tmp := GetTempDir + 'dbimpex-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'data-sources.json',
    '{"connections":{"pg-1":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg","configuration":{"host":"h","port":"5432","user":"alice"}}}}');
  WriteFile(Tmp + 'elsewhere.json',
    '{"pg-1":{"#connection":{"user":"alice","password":"s3cret"}}}');
  if DBeaverImport(Tmp, True, Tmp + 'elsewhere.json', r) then
  begin
    Check('credentials decrypted', r.CredentialsDecrypted);
    Check('one entry', Length(r.Entries) = 1);
    if Length(r.Entries) = 1 then
    begin
      Check('password recovered', r.Entries[0].HasPassword);
      CheckEq('password value', r.Entries[0].Password, 's3cret');
      Check('needs-password = 0', r.NeedsPasswordCount = 0);
    end;
  end
  else
    Check('import ok', False);
  DeleteFile(Tmp + 'data-sources.json');
  DeleteFile(Tmp + 'elsewhere.json');
  RemoveDir(Tmp);
end;

procedure TestFolderPath;
var
  F: TDBeaverFolderArray;
  Tmp: string;
  r: TDBeaverImportResult;
begin
  writeln('folder chain resolution');
  SetLength(F, 2);
  F[0].Id := 'f1'; F[0].Name := 'Work'; F[0].ParentId := '';
  F[1].Id := 'f2'; F[1].Name := 'Dev'; F[1].ParentId := 'f1';
  CheckEq('empty id', DBeaverFolderPath(F, ''), '');
  CheckEq('unknown id', DBeaverFolderPath(F, 'zzz'), '');
  CheckEq('flat folder', DBeaverFolderPath(F, 'f1'), 'Work');
  CheckEq('nested folder', DBeaverFolderPath(F, 'f2'), 'Work/Dev');
  F[1].ParentId := 'missing';
  CheckEq('orphan parent keeps leaf', DBeaverFolderPath(F, 'f2'), 'Dev');
  SetLength(F, 1);
  F[0].Id := 'fx'; F[0].Name := 'A/B:C'; F[0].ParentId := '';
  CheckEq('separators sanitized', DBeaverFolderPath(F, 'fx'), 'A_B_C');

  // end-to-end: the entry carries the resolved folder chain
  Tmp := GetTempDir + 'dbimpfl-' + IntToStr(GetTickCount64) + PathDelim;
  CreateDir(Tmp);
  WriteFile(Tmp + 'data-sources.json',
    '{"folders":{"fld1":{"name":"Work","description":""}},' +
    '"connections":{"pg-1":{"provider":"postgresql","driver":"postgres-jdbc","name":"pg",' +
    '"folder":"fld1","configuration":{"host":"h","port":"5432"}}}}');
  if DBeaverImport(Tmp, False, '', r) then
  begin
    Check('e2e one entry', Length(r.Entries) = 1);
    if Length(r.Entries) = 1 then
      CheckEq('e2e folder path', r.Entries[0].FolderPath, 'Work');
  end
  else
    Check('e2e import ok', False);
  DeleteFile(Tmp + 'data-sources.json');
  RemoveDir(Tmp);
end;

begin
  Pass := 0; Fail := 0;
  writeln('=== dbeaver_import tests ===');
  TestDecryptRoundTrip;
  TestKnownAnswerFixture;
  TestPlainJsonFallback;
  TestMissingCredentials;
  TestDetectEngine;
  TestParseJdbcUrl;
  TestImportEndToEnd;
  TestImportNoCredentials;
  TestImportMissingWorkspace;
  TestNameFallbackToId;
  TestMalformedDataSources;
  TestMalformedCredentialsContinue;
  TestExplicitCredentialsPath;
  TestFolderPath;
  writeln;
  writeln('Total: ', Pass, ' passed, ', Fail, ' failed');
  if Fail > 0 then
    ExitCode := 1;
end.
