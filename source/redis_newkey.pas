unit redis_newkey;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Buttons, ExtCtrls, Dialogs,
  extra_controls, apphelpers, dbconnection;

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
  // FPC {$mode delphi} does not support case-on-string; use if/else if chain.
  if comboType.Text = 'string' then
    lblValue.Caption := _('Initial value:') + ' ' + _('(plain text)')
  else if comboType.Text = 'hash' then
    lblValue.Caption := _('Initial value:') + ' ' + _('(one "field value" per line)')
  else if comboType.Text = 'list' then
    lblValue.Caption := _('Initial value:') + ' ' + _('(one element per line)')
  else if comboType.Text = 'set' then
    lblValue.Caption := _('Initial value:') + ' ' + _('(one member per line)')
  else if comboType.Text = 'zset' then
    lblValue.Caption := _('Initial value:') + ' ' + _('(one "member score" per line)');
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
