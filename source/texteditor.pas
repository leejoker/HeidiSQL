unit texteditor;

{$mode delphi}{$H+}

interface

uses
  Classes, Graphics, Forms, Controls, StdCtrls, laz.VirtualTrees,
  ComCtrls, Dialogs, SysUtils, Menus, LCLType, SynGutterCodeFolding,
  apphelpers, ActnList, extra_controls,
  ExtCtrls, dbconnection, SynEdit, SynEditHighlighter, customize_highlighter,
  Laz2_DOM, Laz2_XMLRead, Laz2_XMLWrite,
  reformatter, jsonparser, fpjson, extfiledialog, lazaruscompat,

  SynHighlighterBat,
  SynHighlighterCpp, SynHighlighterCss,
  SynHighlighterHtml,
  SynHighlighterIni, SynHighlighterJScript,
  SynHighlighterJava,
  SynHighlighterPHP, SynHighlighterPas, SynHighlighterPerl,
  SynHighlighterPython,
  SynHighlighterSQL,
  SynHighlighterTeX, SynHighlighterUNIXShellScript,
  SynHighlighterVB,
  SynHighlighterXML
  ;

{$I const.inc}

type
  TfrmTextEditor = class(TExtForm)
    Panel1: TPanel;
    tlbStandard: TToolBar;
    btnWrap: TToolButton;
    btnLoadText: TToolButton;
    btnApply: TToolButton;
    btnCancel: TToolButton;
    lblTextLength: TLabel;
    btnLinebreaks: TToolButton;
    popupLinebreaks: TPopupMenu;
    menuWindowsLB: TMenuItem;
    menuUnixLB: TMenuItem;
    menuMacLB: TMenuItem;
    menuMixedLB: TMenuItem;
    menuWideLB: TMenuItem;
    btnSearchFind: TToolButton;
    btnSearchReplace: TToolButton;
    btnSearchFindNext: TToolButton;
    btnSeparator1: TToolButton;
    TimerMemoChange: TTimer;
    comboHighlighter: TComboBox;
    MemoText: TSynEdit;
    popupEditor: TPopupMenu;
    Copy1: TMenuItem;
    Paste1: TMenuItem;
    Selectall1: TMenuItem;
    Undo1: TMenuItem;
    Findtext1: TMenuItem;
    Findorreplaceagain1: TMenuItem;
    Replacetext1: TMenuItem;
    N1: TMenuItem;
    ToolButton1: TToolButton;
    btnCustomizeHighlighter: TToolButton;
    popupHighlighter: TPopupMenu;
    menuCustomizeHighlighter: TMenuItem;
    menuFormatCodeOnce: TMenuItem;
    menuAlwaysFormatCode: TMenuItem;
    procedure btnApplyClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnLoadTextClick(Sender: TObject);
    procedure btnWrapClick(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure MemoTextChange(Sender: TObject);
    procedure MemoTextKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure MemoTextClick(Sender: TObject);
    procedure FormCreate(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure SelectLinebreaks(Sender: TObject);
    procedure TimerMemoChangeTimer(Sender: TObject);
    procedure comboHighlighterSelect(Sender: TObject);
    procedure btnCustomizeHighlighterClick(Sender: TObject);
    procedure menuFormatCodeOnceClick(Sender: TObject);
    procedure menuAlwaysFormatCodeClick(Sender: TObject);
  private
    { Private declarations }
    FModified: Boolean;
    FClosingByApplyButton: Boolean;
    FClosingByCancelButton: Boolean;
    FDetectedLineBreaks,
    FSelectedLineBreaks: TLineBreaks;
    FMaxLength: Int64;
    FTableColumn: TTableColumn;
    FHighlighter: TSynCustomHighlighter;
    FHighlighterFormatters: TStringList;
    FLazyLoadQuery: TDBQuery;
    FLazyLoadRecNo: Int64;
    FLazyLoadColumn: Integer;
    FLazyLoadTimer: TTimer;
    FRedisQuery: TRedisQuery;
    FIsTruncated: Boolean;
    FImgData: array of String;
    FImgTypes: array of String;
    FRawJson: String;  // 已拉取的原始 JSON 数据，供图片预览使用
    btnImages: TToolButton;
    btnRawData: TToolButton;
    procedure SetModified(NewVal: Boolean);
    procedure CustomizeHighlighterChanged(Sender: TObject);
    procedure TimerLazyLoadTimer(Sender: TObject);
    procedure DoAutoDetectAndFormat;
    procedure btnImagesClick(Sender: TObject);
    procedure btnRawDataClick(Sender: TObject);
    procedure ImageSaveClick(Sender: TObject);
    procedure ImageDblClick(Sender: TObject);
  public
    function GetText: String;
    procedure SetText(text: String);
    procedure SetTitleText(Title: String);
    procedure SetMaxLength(len: Int64);
    procedure SetFont(font: TFont);
    procedure SetUpLazyLoad(Query: TDBQuery; RecNo: Int64; Column: Integer);
    property Modified: Boolean read FModified write SetModified;
    property TableColumn: TTableColumn read FTableColumn write FTableColumn;
  end;


implementation

uses main, Types, base64, process;

{$R *.lfm}


function TfrmTextEditor.GetText: String;
var
  LB: String;
begin
  Result := MemoText.Text;
  // Convert linebreaks back to selected
  LB := GetLineBreak(FSelectedLineBreaks);
  if LB <> CRLF then
    Result := StringReplace(Result, CRLF, LB, [rfReplaceAll]);
end;


procedure TfrmTextEditor.SetText(text: String);
var
  Detected, Item: TMenuItem;
begin
  // Apply text string, and detect type of line breaks in it
  FDetectedLineBreaks := ScanLineBreaks(text);
  Detected := nil;
  if FDetectedLineBreaks = lbsNone then
    FDetectedLineBreaks := TLineBreaks(AppSettings.ReadInt(asLineBreakStyle));
  for Item in popupLinebreaks.Items do begin
    if Item.Tag = Integer(FDetectedLineBreaks) then begin
      Detected := Item;
    end;
  end;
  if Assigned(Detected) then
    SelectLineBreaks(Detected);
  if (Length(text) > SIZE_KB*10) then begin
    MainForm.LogSQL(_('Auto-disabling wordwrap for large text'));
    btnWrap.Enabled := False;
  end else begin
    btnWrap.Enabled := True;
    comboHighlighter.Enabled := True;
    btnCustomizeHighlighter.Enabled := True;
  end;

  MemoText.Text := text;
  MemoText.SelectAll;
  Modified := False;
end;


procedure TfrmTextEditor.SetTitleText(Title: String);
begin
  // Add column name to window title bar
  if Title <> '' then
    Caption := Title + ' - ' + Caption;
end;


procedure TfrmTextEditor.TimerMemoChangeTimer(Sender: TObject);
var
  MaxLen, CursorPos: String;
begin
  // Timer based onchange handler, so we don't scan the whole text on every typed character
  TimerMemoChange.Enabled := False;
  if FMaxLength = 0 then
    MaxLen := '?'
  else
    MaxLen := FormatNumber(FMaxLength);
  CursorPos := FormatNumber(MemoText.CaretY) + ':' + FormatNumber(MemoText.CaretX);
  lblTextLength.Caption := f_('%s characters (max: %s), %s lines, cursor at %s', [FormatNumber(MemoText.GetTextLen), MaxLen, FormatNumber(MemoText.Lines.Count), CursorPos]);
  if MemoText.ReadOnly then
    lblTextLength.Caption := lblTextLength.Caption + ', read-only';
end;


procedure TfrmTextEditor.btnCustomizeHighlighterClick(Sender: TObject);
var
  Dialog: TfrmCustomizeHighlighter;
begin
  // let user customize highlighter colors
  Dialog := TfrmCustomizeHighlighter.Create(Self);
  Dialog.FriendlyLanguageName := MemoText.Highlighter.GetLanguageName;
  Dialog.OnChange := CustomizeHighlighterChanged;
  Dialog.ShowModal;
  Dialog.Free;
end;

procedure TfrmTextEditor.CustomizeHighlighterChanged(Sender: TObject);
var
  Dialog: TfrmCustomizeHighlighter;
begin
  Dialog := Sender as TfrmCustomizeHighlighter;
  comboHighlighter.ItemIndex := comboHighlighter.Items.IndexOf(Dialog.FriendlyLanguageName);
  comboHighlighter.OnSelect(comboHighlighter);
end;

procedure TfrmTextEditor.SelectLinebreaks(Sender: TObject);
var
  Selected, Item: TMenuItem;
begin
  Selected := Sender as TMenuItem;
  menuWindowsLB.Caption := _('Windows linebreaks');
  menuUnixLB.Caption := _('UNIX linebreaks');
  menuMacLB.Caption := _('Mac OS linebreaks');
  menuWideLB.Caption := _('Unicode linebreaks');
  menuMixedLB.Caption := _('Mixed linebreaks');
  for Item in popupLinebreaks.Items do begin
    if Item.Tag = Integer(FDetectedLineBreaks) then begin
      Item.Caption := Item.Caption + ' (' + _('detected') + ')';
    end;
  end;

  Selected.Default := True;
  btnLineBreaks.Hint := Selected.Caption;
  btnLineBreaks.ImageIndex := Selected.ImageIndex;
  FSelectedLineBreaks := TLineBreaks(Selected.Tag);
  Modified := True;
end;


procedure TfrmTextEditor.SetMaxLength(len: Int64);
begin
  // Input: Length in number of bytes.
  FMaxLength := len;
end;

procedure TfrmTextEditor.SetFont(font: TFont);
begin
  MemoText.Font.Name := font.Name;
  MemoText.Font.Size := font.Size;
end;

procedure TfrmTextEditor.FormCreate(Sender: TObject);
var
  Highlighters: TSynHighlighterList;
  i: Integer;
  CodeFoldingPart: TSynGutterCodeFolding;
begin
  FClosingByApplyButton := False;
  // Assign linebreak values to their menu item tags, to write less code later
  menuWindowsLB.Tag := Integer(lbsWindows);
  menuUnixLB.Tag := Integer(lbsUnix);
  menuMacLB.Tag := Integer(lbsMac);
  menuWideLB.Tag := Integer(lbsWide);
  menuMixedLB.Tag := Integer(lbsMixed);

  Highlighters := SynEditHighlighter.GetPlaceableHighlighters;
  comboHighlighter.Items.Add(_('Text'));
  for i:=0 to Highlighters.Count-1 do begin
    comboHighlighter.Items.Add(Highlighters[i].GetLanguageName);
  end;
  comboHighlighter.AutoSizeItemWidth;

  FTableColumn := nil;

  // Fix label position:
  lblTextLength.Top := tlbStandard.Top + (tlbStandard.Height-lblTextLength.Height) div 2;

  // Define highlighters for which we have a reformatter
  FHighlighterFormatters := TStringList.Create;
  FHighlighterFormatters.Add(TSynJScriptSyn.ClassName);
  FHighlighterFormatters.Add(TSynSQLSyn.ClassName);
  FHighlighterFormatters.Add(TSynXMLSyn.ClassName);

  MainForm.SetupSynEditor(MemoText);

  // 懒加载定时器：FormShow 后异步获取完整值
  FLazyLoadTimer := TTimer.Create(Self);
  FLazyLoadTimer.Enabled := False;
  FLazyLoadTimer.Interval := 50;
  FLazyLoadTimer.OnTimer := TimerLazyLoadTimer;

  // 图片预览按钮（动态添加到工具栏）
  btnImages := TToolButton.Create(tlbStandard);
  btnImages.Parent := tlbStandard;
  btnImages.Style := tbsButton;
  btnImages.Caption := _('🖼 Images');
  btnImages.Hint := _('Preview base64 images in this value');
  btnImages.ShowHint := True;
  btnImages.OnClick := btnImagesClick;
  btnImages.Visible := False;

  // 原始数据按钮
  btnRawData := TToolButton.Create(tlbStandard);
  btnRawData.Parent := tlbStandard;
  btnRawData.Style := tbsButton;
  btnRawData.Caption := '📄 Raw';
  btnRawData.Hint := _('Fetch full raw data and format');
  btnRawData.ShowHint := True;
  btnRawData.OnClick := btnRawDataClick;
  btnRawData.Visible := False;

  if AppSettings.ReadBool(asMemoEditorMaximized) then
    WindowState := wsMaximized;
  // Restore form dimensions
  if WindowState <> wsMaximized then begin
    Width := AppSettings.ReadInt(asMemoEditorWidth);
    Height := AppSettings.ReadInt(asMemoEditorHeight);
  end;
end;


procedure TfrmTextEditor.FormDestroy(Sender: TObject);
begin
  if WindowState <> wsMaximized then begin
    AppSettings.WriteInt(asMemoEditorWidth, ScaleFormToDesign(Width));
    AppSettings.WriteInt(asMemoEditorHeight, ScaleFormToDesign(Height));
  end;
  AppSettings.WriteBool(asMemoEditorMaximized, WindowState=wsMaximized);
  if btnWrap.Enabled then begin
    AppSettings.WriteBool(asMemoEditorWrap, btnWrap.Down);
  end;
  if Assigned(FTableColumn) then begin
    AppSettings.SessionPath := MainForm.GetRegKeyTable;
    if comboHighlighter.Text <> AppSettings.GetDefaultString(asMemoEditorHighlighter) then
      AppSettings.WriteString(asMemoEditorHighlighter, comboHighlighter.Text, FTableColumn.Name)
    else
      AppSettings.DeleteValue(asMemoEditorHighlighter, FTableColumn.Name);
  end;
  // Fixes EAccessViolation under 64-bit when using non-default themes
  if Assigned(Panel1) then
    Panel1.Parent := nil;
end;


procedure TfrmTextEditor.FormShow(Sender: TObject);
begin
  if AppSettings.ReadBool(asMemoEditorWrap) and btnWrap.Enabled then begin
    btnWrap.Click;
  end;
  menuAlwaysFormatCode.Checked := AppSettings.ReadBool(asMemoEditorAlwaysFormatCode);

  if FLazyLoadQuery <> nil then begin
    // 懒加载模式：先用截断值快速显示（不格式化），然后定时器异步获取完整值
    // 选用默认高亮器 + 自动换行
    if (not btnWrap.Down) and btnWrap.Enabled then
      btnWrap.Click;
    FLazyLoadTimer.Enabled := True;
  end else begin
    DoAutoDetectAndFormat;
  end;

  if MemoText.ReadOnly then begin
    MemoText.Color := clBtnFace;
  end;

  // Trigger change event, which is not fired when text is empty. See #132.
  TimerMemoChangeTimer(Self);
  MemoText.TrySetFocus;
end;


procedure TfrmTextEditor.DoAutoDetectAndFormat;
var
  HighlighterName: String;
  Txt: String;
  LooksLikeJson, LooksLikeXml: Boolean;
  Highlighters: TSynHighlighterList;
  i: Integer;
  TempIn, TempOut, OutText: String;
  SL: TStringList;
  JqOk: Boolean;
  JsonParser: TJSONParser;
  JsonData: TJSONData;
begin
  Txt := Trim(MemoText.Text);

  // 自动检测内容类型
  LooksLikeJson := (Length(Txt) > 0) and ((Txt[1] = '{') or (Txt[1] = '['));
  LooksLikeXml := (Length(Txt) > 0) and (Copy(Txt, 1, 5) = '<?xml');

  if LooksLikeJson and (not Txt.IsEmpty) then begin
    // JSON: JScript 高亮器 + jq 格式化
    HighlighterName := TSynJScriptSyn.GetLanguageName;
    comboHighlighter.ItemIndex := comboHighlighter.Items.IndexOf(HighlighterName);
    MemoText.Highlighter := nil;
    FHighlighter.Free;
    FHighlighter := nil;
    Highlighters := SynEditHighlighter.GetPlaceableHighlighters;
    for i := 0 to Highlighters.Count - 1 do begin
      if Highlighters[i].GetLanguageName = HighlighterName then begin
        FHighlighter := Highlighters[i].Create(Self);
        MemoText.Highlighter := FHighlighter;
        Break;
      end;
    end;
    if Assigned(FHighlighter) then begin
      try
        MemoText.Highlighter.LoadFromFile(AppSettings.DirnameHighlighters + MemoText.Highlighter.LanguageName + '.ini');
      except
      end;
    end;
    menuFormatCodeOnce.Enabled := Assigned(FHighlighter) and (FHighlighterFormatters.IndexOf(FHighlighter.ClassName) > -1);
    if Assigned(FHighlighter) and (FHighlighter is TSynJScriptSyn) then begin
      // 用 jq 格式化（比 fpjson 快 1800 倍，6MB 只需 ~100ms）
      try
        TempIn := GetTempDir + 'dsh_json_in.tmp';
        TempOut := GetTempDir + 'dsh_json_out.tmp';
        SL := TStringList.Create;
        try
          SL.Text := MemoText.Text;
          SL.SaveToFile(TempIn);
        finally
          SL.Free;
        end;
        // jq '.' < in > out
        JqOk := RunCommandIndir('', 'bash', ['-c', 'jq ''.'' < ''' + TempIn + ''' > ''' + TempOut + ''''], OutText, []);
        if JqOk and FileExists(TempOut) then begin
          SL := TStringList.Create;
          try
            SL.LoadFromFile(TempOut);
            if SL.Text <> '' then
              MemoText.Text := SL.Text;
          finally
            SL.Free;
          end;
        end;
        DeleteFile(TempIn);
        DeleteFile(TempOut);
        MemoText.CaretXY := Point(1, 1);
        MemoText.ClearSelection;
      except
        // jq 不可用时回退到 fpjson（仅小 JSON）
        try
          JsonParser := TJSONParser.Create(MemoText.Text, []);
          try
            JsonData := JsonParser.Parse;
            if Assigned(JsonData) then begin
              MemoText.Text := JsonData.FormatJSON();
              JsonData.Free;
            end;
          finally
            JsonParser.Free;
          end;
          MemoText.CaretXY := Point(1, 1);
          MemoText.ClearSelection;
        except
        end;
      end;
    end;
    if btnWrap.Down and btnWrap.Enabled then
      btnWrap.Click;
  end
  else if LooksLikeXml then begin
    HighlighterName := TSynXMLSyn.GetLanguageName;
    comboHighlighter.ItemIndex := comboHighlighter.Items.IndexOf(HighlighterName);
    comboHighlighter.OnSelect(comboHighlighter);
    if btnWrap.Down and btnWrap.Enabled then
      btnWrap.Click;
  end
  else begin
    HighlighterName := AppSettings.GetDefaultString(asMemoEditorHighlighter);
    if Assigned(FTableColumn) then begin
      AppSettings.SessionPath := MainForm.GetRegKeyTable;
      HighlighterName := AppSettings.ReadString(asMemoEditorHighlighter, FTableColumn.Name, HighlighterName);
    end;
    comboHighlighter.ItemIndex := comboHighlighter.Items.IndexOf(HighlighterName);
    comboHighlighter.OnSelect(comboHighlighter);
    if (not btnWrap.Down) and btnWrap.Enabled then
      btnWrap.Click;
  end;
end;


procedure TfrmTextEditor.SetUpLazyLoad(Query: TDBQuery; RecNo: Int64; Column: Integer);
begin
  FLazyLoadQuery := Query;
  FLazyLoadRecNo := RecNo;
  FLazyLoadColumn := Column;
  // 保留 Redis 查询引用供 Images / RawData 按钮使用
  if Query is TRedisQuery then
    FRedisQuery := TRedisQuery(Query);
  btnImages.Visible := Assigned(FRedisQuery);
  btnRawData.Visible := Assigned(FRedisQuery);
end;


procedure TfrmTextEditor.TimerLazyLoadTimer(Sender: TObject);
var
  FullText: String;
  RedisQ: TRedisQuery;
  ValLen: Int64;
  wasTruncated: Boolean;
begin
  FLazyLoadTimer.Enabled := False;
  if FLazyLoadQuery = nil then Exit;

  // 先检查值大小，超大值提示用户
  if FLazyLoadQuery is TRedisQuery then begin
    RedisQ := TRedisQuery(FLazyLoadQuery);
    try
      ValLen := RedisQ.GetValueLength(FLazyLoadRecNo);
    except
      ValLen := 0;
    end;
    if ValLen > 100*1024 then begin
      lblTextLength.Caption := Format(_('Loading (value is %s, truncating large fields ...)'),
        [FormatNumber(ValLen) + ' bytes']);
      Application.ProcessMessages;
    end else
      lblTextLength.Caption := _('Loading full value ...');
  end;

  FullText := '';
  wasTruncated := False;
  try
    if FLazyLoadQuery is TRedisQuery then begin
      RedisQ := TRedisQuery(FLazyLoadQuery);
      FullText := RedisQ.GetFullValue(FLazyLoadRecNo, FLazyLoadColumn);
      wasTruncated := (ValLen > 100*1024) and (Length(FullText) < ValLen);
    end;
  except
    Exit;
  end;

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

  if wasTruncated then
    lblTextLength.Caption := Format(_('%s (truncated) — click "Raw" for more'), [FormatNumber(Length(MemoText.Text)) + ' ' + _('characters')])
  else
    lblTextLength.Caption := FormatNumber(Length(MemoText.Text)) + ' ' + _('characters');
end;


procedure TfrmTextEditor.btnImagesClick(Sender: TObject);
var
  frm: TForm;
  sb: TScrollBox;
  pnlTop: TPanel;
  lblProgress: TLabel;
  imgCount, i: Integer;
  img: TImage;
  pnl: TPanel;
  lbl: TLabel;
  btnSave: TButton;
  yPos: Integer;
  TempIn, TempOut, jqOutput: String;
  SL: TStringList;
  JqOk: Boolean;
  base64Lines: TStringList;
  b64Str, decoded, mediaType: String;
  ms: TMemoryStream;
  jpg: TJPEGImage;
  png: TPortableNetworkGraphic;
begin
  // 从已拉取的原始数据中提取 base64 图片（用 jq，不二次请求 Redis）
  if FRawJson = '' then begin
    ShowMessage(_('Click "Raw" first to load the original data.'));
    Exit;
  end;

  Screen.Cursor := crHourglass;
  try
    // 用 jq 提取所有 type=="base64" 的 data 和 media_type
    TempIn := GetTempDir + 'dsh_img_in.tmp';
    TempOut := GetTempDir + 'dsh_img_out.tmp';
    SL := TStringList.Create;
    try
      SL.Text := FRawJson;
      SL.SaveToFile(TempIn);
    finally
      SL.Free;
    end;

    // jq 提取所有 base64 图片的 media_type 和 data
    JqOk := RunCommandIndir('', 'bash', ['-c',
      'jq -r ''[.. | objects | select(.type=="base64" and .data) | (.media_type // "image/jpeg") + "\t" + .data] | .[]'' < ''' + TempIn + ''' > ''' + TempOut + ''''],
      jqOutput, []);
    DeleteFile(TempIn);

    if (not JqOk) or (not FileExists(TempOut)) then begin
      ShowMessage(_('Failed to extract images from JSON.'));
      Exit;
    end;

    base64Lines := TStringList.Create;
    try
      base64Lines.LoadFromFile(TempOut);
      DeleteFile(TempOut);
    except
      base64Lines.Free;
      Exit;
    end;

    imgCount := base64Lines.Count;
    if imgCount = 0 then begin
      ShowMessage(_('No base64 images found in this value.'));
      base64Lines.Free;
      Exit;
    end;

    SetLength(FImgData, imgCount);
    SetLength(FImgTypes, imgCount);

    // 创建预览窗体
    frm := TForm.CreateNew(Self);
    try
      frm.Caption := Format(_('Image Preview (%d images)'), [imgCount]);
      frm.Width := 900;
      frm.Height := 700;
      frm.Position := poScreenCenter;

      pnlTop := TPanel.Create(frm);
      pnlTop.Parent := frm;
      pnlTop.Align := alTop;
      pnlTop.Height := 30;
      pnlTop.BevelOuter := bvNone;

      lblProgress := TLabel.Create(frm);
      lblProgress.Parent := pnlTop;
      lblProgress.Align := alClient;
      lblProgress.Alignment := taCenter;
      lblProgress.Layout := tlCenter;

      sb := TScrollBox.Create(frm);
      sb.Parent := frm;
      sb.Align := alClient;
      sb.HorzScrollBar.Tracking := True;
      sb.VertScrollBar.Tracking := True;

      yPos := 10;
      for i := 0 to imgCount - 1 do begin
        // 解析 "media_type\tbase64data"
        if Pos(#9, base64Lines[i]) > 0 then begin
          mediaType := Copy(base64Lines[i], 1, Pos(#9, base64Lines[i]) - 1);
          b64Str := Copy(base64Lines[i], Pos(#9, base64Lines[i]) + 1, MaxInt);
        end else begin
          mediaType := 'image/jpeg';
          b64Str := base64Lines[i];
        end;

        try
          decoded := DecodeStringBase64(b64Str);
        except
          Decoded := '';
        end;
        if decoded = '' then Continue;

        FImgData[i] := decoded;
        FImgTypes[i] := mediaType;

        // 图片面板
        pnl := TPanel.Create(frm);
        pnl.Parent := sb;
        pnl.Left := 10;
        pnl.Top := yPos;
        pnl.Width := sb.ClientWidth - 30;
        pnl.Height := 300;
        pnl.BevelOuter := bvNone;
        pnl.Anchors := [akLeft, akTop, akRight];

        lbl := TLabel.Create(frm);
        lbl.Parent := pnl;
        lbl.Caption := Format(_('Image %d (%s, %s bytes) — double-click to zoom'),
          [i+1, mediaType, FormatNumber(Length(decoded))]);
        lbl.Top := 5;
        lbl.Left := 5;
        lbl.Font.Style := [fsBold];

        btnSave := TButton.Create(frm);
        btnSave.Parent := pnl;
        btnSave.Top := 3;
        btnSave.Left := pnl.Width - 80;
        btnSave.Width := 70;
        btnSave.Height := 25;
        btnSave.Caption := _('Save');
        btnSave.Anchors := [akTop, akRight];
        btnSave.Tag := i + 1;
        btnSave.OnClick := ImageSaveClick;

        img := TImage.Create(frm);
        img.Parent := pnl;
        img.Top := 30;
        img.Left := 5;
        img.Width := pnl.Width - 10;
        img.Height := 260;
        img.Proportional := True;
        img.Stretch := True;
        img.Anchors := [akLeft, akTop, akRight, akBottom];
        img.OnDblClick := ImageDblClick;
        img.Tag := i + 1;

        // 加载图片
        ms := TMemoryStream.Create;
        try
          ms.WriteBuffer(decoded[1], Length(decoded));
          ms.Position := 0;
          try
            if Pos('png', mediaType) > 0 then begin
              png := TPortableNetworkGraphic.Create;
              try
                png.LoadFromStream(ms);
                img.Picture.Assign(png);
              finally
                png.Free;
              end;
            end
            else begin
              jpg := TJPEGImage.Create;
              try
                jpg.LoadFromStream(ms);
                img.Picture.Assign(jpg);
              finally
                jpg.Free;
              end;
            end;
          except
          end;
        finally
          ms.Free;
        end;

        Inc(yPos, 310);
      end;

      lblProgress.Caption := Format(_('%d images loaded from local data.'), [imgCount]);
      frm.ShowModal;
    finally
      frm.Free;
    end;

    base64Lines.Free;
  finally
    Screen.Cursor := crDefault;
  end;
end;


procedure TfrmTextEditor.ImageDblClick(Sender: TObject);
var
  idx: Integer;
  zoomFrm: TForm;
  zoomImg: TImage;
  ms: TMemoryStream;
  jpg: TJPEGImage;
  png: TPortableNetworkGraphic;
begin
  // 双击图片：打开自适应缩放窗口
  idx := TImage(Sender).Tag;
  if (idx < 1) or (idx > Length(FImgData)) or (FImgData[idx-1] = '') then Exit;

  zoomFrm := TForm.CreateNew(Self);
  try
    zoomFrm.Caption := Format(_('Image %d (resize window to zoom)'), [idx]);
    zoomFrm.Width := 1000;
    zoomFrm.Height := 800;
    zoomFrm.Position := poScreenCenter;
    zoomFrm.Color := clBlack;

    // TImage 直接 alClient 填满窗口，Proportional+Stretch 自适应缩放
    zoomImg := TImage.Create(zoomFrm);
    zoomImg.Parent := zoomFrm;
    zoomImg.Align := alClient;
    zoomImg.Stretch := True;
    zoomImg.Proportional := True;
    zoomImg.Center := True;

    ms := TMemoryStream.Create;
    try
      ms.WriteBuffer(FImgData[idx-1][1], Length(FImgData[idx-1]));
      ms.Position := 0;
      try
        if Pos('png', FImgTypes[idx-1]) > 0 then begin
          png := TPortableNetworkGraphic.Create;
          try
            png.LoadFromStream(ms);
            zoomImg.Picture.Assign(png);
          finally
            png.Free;
          end;
        end
        else begin
          jpg := TJPEGImage.Create;
          try
            jpg.LoadFromStream(ms);
            zoomImg.Picture.Assign(jpg);
          finally
            jpg.Free;
          end;
        end;
      except
      end;
    finally
      ms.Free;
    end;

    zoomFrm.ShowModal;
  finally
    zoomFrm.Free;
  end;
end;


procedure TfrmTextEditor.ImageSaveClick(Sender: TObject);
var
  idx: Integer;
  saveDlg: TSaveDialog;
  saveStream: TFileStream;
  saveExt: String;
begin
  idx := TButton(Sender).Tag;
  if (idx < 1) or (idx > Length(FImgData)) then Exit;
  if FImgData[idx-1] = '' then Exit;

  if Pos('png', FImgTypes[idx-1]) > 0 then
    saveExt := '.png'
  else
    saveExt := '.jpg';

  saveDlg := TSaveDialog.Create(Self);
  try
    saveDlg.FileName := 'image_' + IntToStr(idx) + saveExt;
    saveDlg.Filter := _('Image files') + '|*' + saveExt + '|' + _('All files') + '|*.*';
    if saveDlg.Execute then begin
      saveStream := TFileStream.Create(saveDlg.FileName, fmCreate);
      try
        saveStream.WriteBuffer(FImgData[idx-1][1], Length(FImgData[idx-1]));
      finally
        saveStream.Free;
      end;
    end;
  finally
    saveDlg.Free;
  end;
end;


procedure TfrmTextEditor.btnRawDataClick(Sender: TObject);
var
  RawText: String;
  T0: QWord;
begin
  if FRedisQuery = nil then Exit;

  Screen.Cursor := crHourglass;
  lblTextLength.Caption := _('Fetching raw data from Redis ...');
  Application.ProcessMessages;

  T0 := GetTickCount64;
  try
    RawText := FRedisQuery.GetRawValue(FLazyLoadRecNo);
  finally
    Screen.Cursor := crDefault;
  end;

  if RawText = '' then begin
    lblTextLength.Caption := _('Failed to load data.');
    Exit;
  end;

  // 保存原始 JSON 供图片预览使用（不再二次请求 Redis）
  FRawJson := RawText;

  FIsTruncated := False;
  lblTextLength.Caption := _('Formatting JSON ...');
  Application.ProcessMessages;
  MemoText.BeginUpdate;
  try
    MemoText.Text := RawText;
    DoAutoDetectAndFormat;
  finally
    MemoText.EndUpdate;
  end;
  MemoText.CaretXY := Point(1, 1);
  MemoText.ClearSelection;

  lblTextLength.Caption := Format(_('%s (raw + formatted, %d ms)'),
    [FormatNumber(Length(MemoText.Text)) + ' ' + _('characters'), GetTickCount64 - T0]);
end;


procedure TfrmTextEditor.MemoTextKeyDown(Sender: TObject; var Key: Word; Shift:
    TShiftState);
begin
  TimerMemoChange.Enabled := False;
  TimerMemoChange.Enabled := True;
  case Key of
    // Cancel active dialog by Escape
    VK_ESCAPE: begin
      btnCancelClick(Sender);
    end;
    // Apply changes and end editing by Ctrl + Enter
    VK_RETURN: if ssCtrl in Shift then btnApplyClick(Sender);
    Ord('a'), Ord('A'): if (ssCtrl in Shift) and (not (ssAlt in Shift)) then Mainform.actSelectAllExecute(Sender);
  end;
end;

procedure TfrmTextEditor.MemoTextClick(Sender: TObject);
begin
  TimerMemoChange.Enabled := False;
  TimerMemoChange.Enabled := True;
end;

procedure TfrmTextEditor.btnWrapClick(Sender: TObject);
var
  WasModified: Boolean;
begin
  Screen.Cursor := crHourglass;
  // Changing the scrollbars invoke the OnChange event. We avoid thinking the text was really modified.
  WasModified := Modified;
  if MemoText.ScrollBars = ssBoth then begin
    MemoText.ScrollBars := ssVertical;
    //MemoText.WordWrap := True;
  end else begin
    MemoText.ScrollBars := ssBoth;
    //MemoText.WordWrap := False;
  end;
  btnWrap.Down := MemoText.ScrollBars = ssVertical;
  Modified := WasModified;
  Screen.Cursor := crDefault;
end;


procedure TfrmTextEditor.comboHighlighterSelect(Sender: TObject);
var
  Highlighters: TSynHighlighterList;
  i: Integer;
  SelBegin, SelEnd: TPoint;
begin
  // Code highlighter selected
  if not comboHighlighter.Enabled then
    Exit;
  SelBegin := MemoText.BlockBegin;
  SelEnd := MemoText.BlockEnd;
  MemoText.Highlighter := nil;
  FHighlighter.Free;
  FHighlighter := nil;
  Highlighters := SynEditHighlighter.GetPlaceableHighlighters;
  for i:=0 to Highlighters.Count-1 do begin
    if comboHighlighter.Text = Highlighters[i].GetLanguageName then begin
      FHighlighter := Highlighters[i].Create(Self);
      MemoText.Highlighter := FHighlighter;
      Break;
    end;
  end;

  menuFormatCodeOnce.Enabled := Assigned(FHighlighter) and (FHighlighterFormatters.IndexOf(FHighlighter.ClassName) > -1);
  if menuAlwaysFormatCode.Checked and menuFormatCodeOnce.Enabled then begin
    menuFormatCodeOnce.OnClick(Sender);
    SelBegin := Point(1, 1);
    SelEnd := SelBegin;
  end;

  if Assigned(FHighlighter) then begin
    // Load custom highlighter settings from ini file, if exists:
    MemoText.Highlighter.LoadFromFile(AppSettings.DirnameHighlighters + MemoText.Highlighter.LanguageName + '.ini');
  end;

  MemoText.BlockBegin := SelBegin;
  MemoText.BlockEnd := SelEnd;
end;

procedure TfrmTextEditor.btnLoadTextClick(Sender: TObject);
var
  d: TExtFileOpenDialog;
begin
  AppSettings.ResetPath;
  d := TExtFileOpenDialog.Create(Self);
  d.AddFileType('*.txt', _('Text files'));
  d.AddFileType('*.*', _('All files'));
  d.Encodings.Assign(MainForm.FileEncodings);
  d.EncodingIndex := AppSettings.ReadInt(asFileDialogEncoding, Self.Name);
  if d.Execute then try
    Screen.Cursor := crHourglass;
    MemoText.Text := ReadTextFile(d.FileName, MainForm.GetEncodingByName(d.Encodings[d.EncodingIndex]));
    if (FMaxLength > 0) and (Length(MemoText.Text) > FMaxLength) then
      MemoText.Text := Copy(MemoText.Text, 1, FMaxLength);
    AppSettings.WriteInt(asFileDialogEncoding, d.EncodingIndex, Self.Name);
  finally
    Screen.Cursor := crDefault;
  end;
  d.Free;
end;


procedure TfrmTextEditor.btnCancelClick(Sender: TObject);
begin
  FClosingByCancelButton := True;
  Close;
end;


procedure TfrmTextEditor.menuAlwaysFormatCodeClick(Sender: TObject);
begin
  // Change setting for "always reformat"
  AppSettings.WriteBool(asMemoEditorAlwaysFormatCode, menuAlwaysFormatCode.Checked);
  if menuAlwaysFormatCode.Checked and menuFormatCodeOnce.Enabled then begin
    menuFormatCodeOnce.OnClick(Sender);
  end;
end;


procedure TfrmTextEditor.menuFormatCodeOnceClick(Sender: TObject);
var
  JsonParser: TJSONParser;
  Doc: TXMLDocument;
  InStream, OutStream: TStringStream;
begin
  // Reformat code if possible
  try
    if FHighlighter is TSynJScriptSyn then begin
      JsonParser := TJSONParser.Create(MemoText.Text, []);
      try
        MemoText.Text := JsonParser.Parse.FormatJSON();
      finally
        JsonParser.Free;
      end;
      MemoText.CaretXY := Point(1, 1);
      MemoText.ClearSelection;
    end
    else if FHighlighter is TSynSQLSyn then begin
      // Prefer old internal formatter here, so the user does not run into request limits
      frmReformatter := TfrmReformatter.Create(Self);
      MemoText.Text := frmReformatter.FormatSqlInternal(MemoText.Text);
      MemoText.CaretXY := Point(1, 1);
      MemoText.ClearSelection;
      frmReformatter.Free;
    end
    else if FHighlighter is TSynXMLSyn then begin
      InStream := TStringStream.Create(MemoText.Text);
      OutStream := TStringStream.Create('');
      try
        ReadXMLFile(Doc, InStream);  // parse XML
        try
          WriteXMLFile(Doc, OutStream); // pretty-print XML
        finally
          Doc.Free;
        end;
        MemoText.BeginUpdate;
        MemoText.Text := OutStream.DataString; // show formatted XML
        MemoText.EndUpdate;
        MemoText.CaretXY := Point(1, 1);
        MemoText.ClearSelection;
      finally
        InStream.Free;
        OutStream.Free;
      end;
    end
    else begin
      Beep;
    end;
  except
    on E:Exception do begin
      Beep;
      MainForm.LogSQL(f_('Error in code formatting: %s', [E.Message]));
    end;
  end;
end;


procedure TfrmTextEditor.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  if Modified then begin
    if FClosingByCancelButton then
      ModalResult := mrCancel
    else if FClosingByApplyButton then
      ModalResult := mrYes
    else
      ModalResult := MessageDialog(_('Apply modifications?'), mtConfirmation, [mbYes, mbNo]);
  end
  else
    ModalResult := mrCancel;
end;


procedure TfrmTextEditor.btnApplyClick(Sender: TObject);
begin
  FClosingByApplyButton := True;
  Close;
end;


procedure TfrmTextEditor.MemoTextChange(Sender: TObject);
begin
  Modified := True;
  TimerMemoChange.Enabled := False;
  TimerMemoChange.Enabled := True;
end;


procedure TfrmTextEditor.SetModified(NewVal: Boolean);
begin
  // Enables or disables "apply" button, and resets SynEdit's modification marker in its gutter
  if FModified <> NewVal then begin
    FModified := NewVal;
    if not FModified then
      MemoText.Modified := False;
    btnApply.Enabled := FModified;
  end;
end;


end.
