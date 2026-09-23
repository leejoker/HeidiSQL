unit dbeaver_import_dlg;

{$mode delphi}{$H+}

// -------------------------------------
// DBeaver session import dialog
// -------------------------------------
// Converts TDBeaverImportEntry records (from dbeaver_import) into
// TConnectionParameters and persists them via SaveToRegistry, then asks the
// session manager to refresh its tree. Folders and name conflicts are handled
// here (the pure dbeaver_import unit knows nothing about HeidiSQL's registry).

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, EditBtn,
  ExtCtrls, Buttons, extra_controls, extfiledialog, dbconnection, dbstructures,
  apphelpers, dbeaver_import;

type
  { TfrmDBeaverImport }

  TfrmDBeaverImport = class(TExtForm)
    btnClose: TBitBtn;
    btnImport: TBitBtn;
    chkImportPasswords: TCheckBox;
    editCredentials: TEditButton;
    editDataSources: TEditButton;
    lblDataSources: TLabel;
    lblCredentials: TLabel;
    memoResult: TMemo;
    pnlTop: TPanel;
    procedure editDataSourcesButtonClick(Sender: TObject);
    procedure editCredentialsButtonClick(Sender: TObject);
    procedure btnImportClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
  private
    function EngineToNetType(Engine: TDBeaverEngine): TNetType;
    function UniqueSessionPath(const ParentPath, Name: string): string;
    function IsFolderSession(const Path: string): Boolean;
    function EnsureFolderChain(const FolderPath: string): string;
    function ImportEntry(const Entry: TDBeaverImportEntry): string;
  public
  end;

var
  frmDBeaverImport: TfrmDBeaverImport;

implementation

uses connections;

{$R *.lfm}
{$I const.inc}

procedure TfrmDBeaverImport.FormCreate(Sender: TObject);
var
  Ws: string;
begin
  // Auto-detect the DBeaver workspace as the default.
  Ws := DBeaverFindWorkspace('');
  if Ws <> '' then
    editDataSources.Text := Ws + 'data-sources.json'
  else
    editDataSources.Text := '';
  editCredentials.Text := '';
  chkImportPasswords.Checked := True;
end;

procedure TfrmDBeaverImport.editDataSourcesButtonClick(Sender: TObject);
var
  Dlg: TExtFileOpenDialog;
begin
  Dlg := TExtFileOpenDialog.Create(Self);
  try
    Dlg.Title := _('Select DBeaver data-sources.json');
    Dlg.AddFileType('*.json', _('JSON files'));
    Dlg.AddFileType('*.*', _('All files'));
    Dlg.InitialDir := ExtractFilePath(editDataSources.Text);
    Dlg.FileName := ExtractFileName(editDataSources.Text);
    if Dlg.Execute then begin
      editDataSources.Text := Dlg.FileName;
      // Default credentials file to the same directory.
      if editCredentials.Text = '' then
        editCredentials.Text := ExtractFilePath(Dlg.FileName) + 'credentials-config.json';
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TfrmDBeaverImport.editCredentialsButtonClick(Sender: TObject);
var
  Dlg: TExtFileOpenDialog;
begin
  Dlg := TExtFileOpenDialog.Create(Self);
  try
    Dlg.Title := _('Select DBeaver credentials-config.json');
    Dlg.AddFileType('*.json', _('JSON files'));
    Dlg.AddFileType('*.*', _('All files'));
    if editCredentials.Text <> '' then
      Dlg.InitialDir := ExtractFilePath(editCredentials.Text)
    else
      Dlg.InitialDir := ExtractFilePath(editDataSources.Text);
    Dlg.FileName := ExtractFileName(editCredentials.Text);
    if Dlg.Execute then
      editCredentials.Text := Dlg.FileName;
  finally
    Dlg.Free;
  end;
end;

function TfrmDBeaverImport.EngineToNetType(Engine: TDBeaverEngine): TNetType;
begin
  case Engine of
    dbeMySQL: Result := ntMySQL_TCPIP;
    dbePg: Result := ntPgSQL_TCPIP;
    dbeMSSQL: Result := ntMSSQL_TCPIP;
    dbeSQLite: Result := ntSQLite;
    dbeInterbase: Result := ntInterbase_TCPIP;
    dbeRedis: Result := ntRedis_TCPIP;
  else
    Result := ntMySQL_TCPIP;
  end;
end;

// Find a non-conflicting SessionPath under ParentPath for the given display
// name, appending " (2)", " (3)", ... as needed. Never overwrites.
function TfrmDBeaverImport.UniqueSessionPath(const ParentPath, Name: string): string;
var
  Base, Candidate: string;
  N: Integer;
begin
  Base := ValidFilename(Name);
  if Base = '' then
    Base := 'DBeaver';
  Candidate := ParentPath + Base;
  N := 2;
  while AppSettings.SessionPathExists(Candidate) do
  begin
    Candidate := ParentPath + Base + ' (' + IntToStr(N) + ')';
    Inc(N);
  end;
  Result := Candidate;
end;


// True when Path exists as a session key and carries the folder flag.
function TfrmDBeaverImport.IsFolderSession(const Path: string): Boolean;
begin
  Result := False;
  if not AppSettings.SessionPathExists(Path) then
    Exit;
  AppSettings.SessionPath := Path;
  // asSessionFolder is session-scoped, so this read keeps the current path.
  Result := AppSettings.ReadBool(asSessionFolder);
end;


// Ensure a '/'-joined folder chain exists: create missing folder sessions,
// reuse existing folders, suffix around collisions with plain sessions.
// Returns the actual chain ('' = root / no folder).
function TfrmDBeaverImport.EnsureFolderChain(const FolderPath: string): string;
var
  Parts: TStringList;
  i: Integer;
  Parent, Seg, Candidate, Unique: string;
  Sess: TConnectionParameters;
begin
  Result := '';
  if FolderPath = '' then
    Exit;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '/';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := FolderPath;
    Parent := '';
    for i := 0 to Parts.Count - 1 do
    begin
      Seg := ValidFilename(Parts[i]);
      if Seg = '' then
        Continue;
      Candidate := Parent + Seg;
      if not AppSettings.SessionPathExists(Candidate) then
        Unique := Candidate
      else if IsFolderSession(Candidate) then
        Unique := Candidate              // reuse the existing folder
      else
        Unique := UniqueSessionPath(Parent, Seg); // occupied by a session
      if not AppSettings.SessionPathExists(Unique) then
      begin
        Sess := TConnectionParameters.Create;
        try
          Sess.IsFolder := True;
          Sess.SessionPath := Unique;
          Sess.SaveToRegistry;
        finally
          Sess.Free;
        end;
      end;
      Parent := Unique + '/';
    end;
    Result := Copy(Parent, 1, Length(Parent) - 1);
    AppSettings.ResetPath;
  finally
    Parts.Free;
  end;
end;

// Persist one import entry as a HeidiSQL session. Returns the created
// SessionPath (or '' on skip). v1 imports connections flat at the root;
// DBeaver folders are not preserved (future enhancement).
function TfrmDBeaverImport.ImportEntry(const Entry: TDBeaverImportEntry): string;
var
  Sess: TConnectionParameters;
  Path, Parent: string;
begin
  Result := '';
  if Entry.Engine = dbeNone then
    Exit;

  Sess := TConnectionParameters.Create;
  try
    Sess.NetType := EngineToNetType(Entry.Engine);
    Sess.Hostname := Entry.Host;
    if Entry.Port <> 0 then
      Sess.Port := Entry.Port;
    Sess.Username := Entry.User;
    if Entry.HasPassword then
      Sess.Password := Entry.Password
    else
      Sess.LoginPrompt := True;
    Sess.AllDatabasesStr := Entry.Database;
    Sess.WantSSL := Entry.WantsSSL;
    if Entry.SslMode <> '' then
      Sess.Comment := 'DBeaver: sslmode=' + Entry.SslMode
    else
      Sess.Comment := 'Imported from DBeaver';
    // SSH fields captured but NOT auto-enabled (HeidiSQL SSH uses an external
    // process; enabling blindly would break connections). User can enable in
    // the session manager.
    if Entry.SshHost <> '' then
    begin
      Sess.SSHHost := Entry.SshHost;
      if Entry.SshPort <> 0 then
        Sess.SSHPort := Entry.SshPort;
      Sess.SSHUser := Entry.SshUser;
      Sess.SSHPrivateKey := Entry.SshPrivateKey;
    end;

    Parent := EnsureFolderChain(Entry.FolderPath);
    if Parent <> '' then
      Parent := Parent + '/';
    Path := UniqueSessionPath(Parent, Entry.Name);
    Sess.SessionPath := Path;
    Sess.SaveToRegistry;
    Result := Path;
  finally
    Sess.Free;
  end;
end;

procedure TfrmDBeaverImport.btnImportClick(Sender: TObject);
var
  Ws, CredFile, Summary, Status: string;
  Res: TDBeaverImportResult;
  i: Integer;
  E: TDBeaverImportEntry;
  Created, Skipped, NeedsPw, Errors: Integer;
begin
  if editDataSources.Text = '' then
  begin
    MessageDialog(_('Please select a DBeaver data-sources.json file.'), mtWarning, [mbOK]);
    Exit;
  end;
  // Workspace = directory containing data-sources.json. Accept a file path or
  // the directory itself.
  if DirectoryExists(editDataSources.Text) then
    Ws := IncludeTrailingPathDelimiter(editDataSources.Text)
  else
    Ws := ExtractFilePath(editDataSources.Text);
  if Ws = '' then
    Ws := '.';
  // Explicit credentials file (optional); a directory gets the default name.
  CredFile := editCredentials.Text;
  if DirectoryExists(CredFile) then
    CredFile := IncludeTrailingPathDelimiter(CredFile) + 'credentials-config.json';

  memoResult.Clear;
  Created := 0;
  Skipped := 0;
  NeedsPw := 0;
  Errors := 0;

  Screen.Cursor := crHourGlass;
  try
    if not DBeaverImport(Ws, chkImportPasswords.Checked, CredFile, Res) then
    begin
      memoResult.Lines.Add('Could not read DBeaver data-sources.json in:');
      memoResult.Lines.Add(Ws);
      Exit;
    end;

    for i := 0 to High(Res.Entries) do
    begin
      E := Res.Entries[i];
      if E.Engine = dbeNone then
      begin
        Inc(Skipped);
        memoResult.Lines.Add(Format('- [skipped] %s (%s)', [E.Name, E.Reason]));
        Continue;
      end;
      // One failing session must not abort the remaining imports.
      try
        Status := ImportEntry(E);
      except
        on Ex: Exception do
        begin
          Inc(Errors);
          memoResult.Lines.Add(Format('- [error] %s: %s', [E.Name, Ex.Message]));
          Continue;
        end;
      end;
      if Status <> '' then
      begin
        Inc(Created);
        if E.HasPassword then
          memoResult.Lines.Add(Format('+ [imported] %s -> %s', [E.Name, Status]))
        else
        begin
          Inc(NeedsPw);
          memoResult.Lines.Add(Format('+ [imported, password prompt] %s -> %s', [E.Name, Status]));
        end;
      end;
    end;
  finally
    Screen.Cursor := crDefault;
  end;

  Summary := Format('Imported: %d   Skipped: %d   Needs password: %d',
    [Created, Skipped, NeedsPw]);
  if Errors > 0 then
    Summary := Summary + Format('   Errors: %d', [Errors]);
  if chkImportPasswords.Checked and (not Res.CredentialsDecrypted) and (Created > 0) then
    Summary := Summary + sLineBreak + 'Note: credentials file could not be decrypted; ' +
      'imported sessions will prompt for a password.';
  memoResult.Lines.Insert(0, Summary);
  memoResult.Lines.Insert(1, '');

  // Ask the session manager to refresh its tree (existing pattern).
  if Assigned(connform) and (Created > 0) then
    connform.timerSettingsImport.Enabled := True;

  MessageDialog(Summary, mtInformation, [mbOK]);
end;

end.
