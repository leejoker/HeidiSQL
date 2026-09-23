# AGENTS.md — HeidiSQL (Lazarus/Free Pascal port)

This document captures the **actual** conventions of this codebase so that any
agent (or human) generating code, forms, or UI changes produces output that is
indistinguishable from the existing code. Follow these rules literally. When a
rule conflicts with a "nicer" alternative, the existing code wins.

> The codebase is a port of the Windows-native HeidiSQL to Lazarus/FPC, targeting
> Windows, Linux (GTK2/Qt5/Qt6) and macOS. It is written in **Delphi-mode Object
> Pascal** (`{$mode delphi}{$H+}`), not classic FPC syntax.

---

## 1. Build & toolchain

- **Compiler**: Free Pascal 3.2.2 (`/data/fpc_tools/fpc/bin/x86_64-linux/fpc`)
- **IDE/build tool**: Lazarus 4.x (`lazbuild`, `/data/fpc_tools/lazarus/lazbuild`)
- **Lazarus config**: `--primary-config-path=/data/fpc_tools/config_lazarus`
- **Project file**: `heidisql.lpi` / main program `heidisql.lpr`
- **Source units**: all live under `source/` (flat — no deep subdirectories
  except `source/metadarkstyle/`, a vendored Windows-only theming library)
- **Constants**: shared constants go in `source/const.inc`, included via `{$I const.inc}`
- **Output**: binaries land in `out/heidisql` then are moved to `out/<widgetset>/heidisql`
  by the Makefile targets (`out/qt6/`, `out/gtk2/`, `out/win64/`, etc.)

### Build command (Qt6 Release — the primary Linux target)
```bash
export PATH=/data/fpc_tools/fpc/bin/x86_64-linux:/data/fpc_tools/lazarus:$PATH
/data/fpc_tools/lazarus/lazbuild \
  --primary-config-path=/data/fpc_tools/config_lazarus \
  -B --bm=Release --ws=qt6 heidisql.lpi
```

### Makefile targets (preferred for full pipeline)
- `make build-qt6` / `build-qt5` / `build-gtk2` / `build-win64` / `build-macos`
- `make all` builds every target + packages (requires cross-compilers + `fpm`)
- `make clean` removes `bin/lib/<cpu>-<os>/` and `out/`

### Build modes (in `heidisql.lpi`)
- `Default`, `Debug`, `Release` — pass `--bm=Release` or `--bm=Debug`.
- Release enables `SmartLinkUnit`, `OptimizationLevel=3`, no debug info.
- Unit output directory: `bin/lib/$(TargetCPU)-$(TargetOS)`.

**Rule**: never introduce a new build mode or change `lpi` search paths without
also updating the Makefile. Never check in `bin/`, `out/`, `*.ppu`, `*.o`,
`lib/`, or `units/` (see `.gitignore`).

---

## 2. Unit & file organization

Every source unit follows this skeleton:

```pascal
unit <unitname>;

{$mode delphi}{$H+}

interface

uses
  Classes, SysUtils, ...;

type
  ...
implementation

uses <secondary units>;  // units only needed in implementation go here

{$R *.lfm}      // ONLY in form/frame units with an .lfm file
{$I const.inc}  // when constants are needed

... method bodies ...

end.
```

### Conventions
- **One unit per file**, filename matches unit name (e.g. `dbconnection.pas` → `unit dbconnection;`).
- **`{$mode delphi}{$H+}` is the first line after `unit`** in *every* `.pas` file. No exceptions.
- **Form/frame units** have a paired `.lfm` file and include `{$R *.lfm}` in the implementation section.
- **`const.inc`** is included with `{$I const.inc}` wherever constants like `APPNAME`, `CRLF`,
  icon indexes, or size constants are used. It also disables warnings 5028/5025.
- **Interface `uses`** lists FCL/LCL units first, then project units (`dbconnection`,
  `dbstructures`, `apphelpers`, `generic_types`, `extra_controls`).
- **Implementation `uses`** is used to break circular dependencies — `apphelpers` is very
  frequently an implementation-only dependency (e.g. `dbstructures` implementation `uses apphelpers`).
- **No namespaces**: units are referenced by bare name (`dbconnection`, not `HeidiSQL.dbconnection`).

### File naming
- Form/dialog units: lowercase or `lower_with_underscores` (e.g. `loginform.pas`, `change_password.pas`).
- DB-structure providers: `dbstructures.<engine>.pas` (`dbstructures.mysql.pas`, `dbstructures.postgresql.pas`, etc.).
- The `.lpi` uses backslash `PathDelim` and backslash paths internally (Windows heritage) — **do not
  "fix" these to forward slashes**; `lazbuild` accepts them on all platforms.

---

## 3. Naming conventions

| Element | Convention | Examples |
|---|---|---|
| Units | lowercase, no prefixes | `dbconnection`, `apphelpers`, `table_editor` |
| Classes | `T`-prefixed PascalCase | `TDBConnection`, `TDBObject`, `TExtForm` |
| Form classes | `Tfrm...` or `T...Form` | `TfrmLogin`, `TfrmTableEditor`, `TUserManagerForm`, `TMainForm` |
| Frame-based editors | `Tfrm...` inheriting `TDBObjectEditor` | `TfrmTableEditor`, `TfrmView`, `TfrmRoutineEditor` |
| Enums | `T`-prefixed, 2–4 letter lowercase prefix | `TListNodeType = (lntNone, lntDb, lntTable...)`, `TEditingStatus = (esUntouched...)` |
| Enum values | prefix + PascalCase | `ngMySQL`, `cdtText`, `dtcInteger`, `asHost` |
| Setting indices | `as...` prefix | `asHost`, `asPort`, `asThemeMode`, `asPreferencesWindowWidth` |
| Query ids | `q...` prefix | `qDatabaseTable`, `qGetRowCountExact` |
| Constants | `UPPER_SNAKE_CASE` | `APPNAME`, `CRLF`, `ICONINDEX_FIELD`, `SIZE_MB` |
| Private fields | `F`-prefixed | `FConnection`, `FModified`, `FServerVersion` |
| Form controls (in `.pas`/`.lfm`) | Hungarian-ish prefixes | `edit...`, `combo...`, `lbl...`, `btn...`, `chk...`, `list...`, `tree...`, `memo...`, `pnl...`, `tab...`, `splt...`, `menu...`, `popup...` |
| Event handlers | `<control><event>` | `btnAddColumnClick`, `listColumnsFocusChanged`, `FormCreate`, `FormShow` |
| Generic collections | `TObjectList<T>` / `TDictionary<K,V>` aliases | `TDBObjectList = class(TObjectList<TDBObject>)` |

**Rule**: new identifiers must reuse the existing prefix scheme. A new setting
gets an `as...` entry; a new enum value uses the same prefix as its siblings.

---

## 4. Type & class patterns

### `TObjectList<T>` subclasses are the standard collection type
Collections are named `T<Thing>List` and add convenience helpers:

```pascal
TTableColumnList = class(TObjectList<TTableColumn>)
public
  procedure Assign(Source: TTableColumnList);
  function FindByName(const Value: String): TTableColumn;
  function QuoteIdents: String;
end;
```

- Lists own their objects by default (`TObjectList` with default `AOwnsObjects=True`).
- `TDictionary` aliases are declared as type aliases, not new classes:
  `TColumnCache = TDictionary<String,TTableColumnList>;`

### `TPersistent` subclasses with `Assign`
Domain objects (`TTableColumn`, `TTableKey`, `TDBObject`) inherit `TPersistent` and
override `Assign(Source: TPersistent)`. They carry an `OldName`/`Old...` twin field
for tracking renames, and an editing-status enum (`TEditingStatus`).

### Class-of references for plugin-style dispatch
```pascal
TDBObjectEditorClass = class of TDBObjectEditor;
```
Used to instantiate editor frames by node type (see §7).

### Class helpers for LCL types
```pascal
TClipboardHelper = class helper for TClipboard)   // adds TryAsText
TWinControlHelper = class helper for TWinControl)  // adds TrySetFocus
```
Prefer extending an existing helper over adding free functions.

### FPC-version compatibility shims
Use conditional `{$IF FPC_FULLVERSION<30203}` for `constref` vs `const` in comparer
overrides. Put cross-version differences in `lazaruscompat.pas` / `DelphiCompat`.

---

## 5. Database access layer

This is the heart of the app. **Never** call raw SQL libs directly from UI code.

### Class hierarchy (`dbconnection.pas`)
```
TDBConnection (TComponent, abstract)
├── TMySQLConnection        (libmysql/libmariadb via DLL)
├── TSqlSrvConnection       (FreeTDS, {$IFDEF HASMSSQL})
├── TPgConnection           (libpq)
└── TSQLiteConnection       (libsqlite3)
```
- `HASMSSQL` is defined only on Linux/Windows. Guard MSSQL code with `{$IFDEF HASMSSQL}`.
- Each subclass overrides: `SetActive`, `Query`, `Ping`, `FetchDbObjects`,
  `GetTableColumns/Keys/ForeignKeys`, `GetLastErrorCode/Msg`, `GetCreateCode`.

### Querying — use these, not raw SQL strings:
```pascal
Conn.Query(SQL, DoStoreResult, LogCategory);   // execute, no result needed
Results := Conn.GetResults(SQL);                // returns TDBQuery
SL := Conn.GetCol(SQL, ValueColumn, NameColumn);// one column → TStringList
Val := Conn.GetVar(SQL, Column);                // single scalar
```

### SQL provider pattern (`dbstructures.pas`)
SQL is **not** hardcoded in connection methods. It comes from a provider:
```pascal
TSqlProvider.GetSql(qGetRowCountExact);                      // base default
TSqlProvider.GetSql(qId, [Args]);                            // Format()-style
TSqlProvider.GetSql(qId, NamedParameters: TStringMap);       // :name replacement
```
- Base `TSqlProvider` holds engine-agnostic snippets (`qEmptyTable`, `qOrderAsc`...).
- Engine-specific providers (`TMySQLProvider`, `TPGProvider`...) override `GetSql`
  and switch on `TQueryId`. **New SQL must add a `TQueryId` enum value** and provide
  it in at least the relevant engine provider.
- Server-version-gated SQL uses `FServerVersion` comparisons inside `GetSql`.

### Identifier quoting
Always go through `Conn.QuoteIdent(...)`, `Conn.QuotedDbAndTableName(...)`,
`Obj.QuotedName(...)`. Never concatenate raw identifiers into SQL with string math.

### Exception type
DB errors raise `EDbError` (carries `ErrorCode` + `Hint`). Catch `EDbError` in UI,
let it propagate from connection internals.

### Threading
Long-running queries run on `TQueryThread` (`apphelpers.pas`). UI code reads
results via the thread's `Connection`/`Batch`/`RowsAffected`/`RowsFound`
properties and marshals logs through `LogFromThread`. **Never** touch LCL controls
from the query thread.

---

## 6. Settings persistence (`TAppSettings`)

All user/session settings flow through the global `AppSettings: TAppSettings`.

- Every setting is an entry in the `TAppSettingIndex` enum (`asHost`, `asPort`,
  `asThemeMode`, `asPreferencesWindowWidth`, ...). **Adding a setting means adding
  an enum value** in `apphelpers.pas` and registering a default in `TAppSettings.Create`.
- Three data types: `adInt`, `adBool`, `adString`. Accessors:
  ```pascal
  AppSettings.ReadInt(asPort);
  AppSettings.ReadBool(asAutoReconnect);
  AppSettings.ReadString(asHost);
  AppSettings.ReadString(asListColWidths, Regname);        // FormatName overload
  AppSettings.WriteInt(asPreferencesWindowWidth, ScaleFormToDesign(Width));
  ```
- `FormatName` parameter supports per-instance storage (e.g. per-list column widths,
  keyed by `OwnerForm.Name + '.' + List.Name`).
- `Session: Boolean` flag marks session-scoped settings (stored under the session path).
- Storage backend is `TJsonRegistry` (a JSON file), **not** the Windows registry —
  portable across platforms. `PortableMode` is auto-detected.
- Path helpers: `ResetPath` / `StorePath` / `RestorePath` / `SessionPath`.

**Rule**: never store settings in ad-hoc INI files or registry calls. Add an
`as...` enum value and use `AppSettings`.

---

## 7. Forms & dialogs (UI lifecycle)

### Base classes (`extra_controls.pas`)
- **`TExtForm`** — the base form for almost all dialogs. Use it instead of `TForm`.
  It provides: DPI scaling helpers (`ScaleFromDesign`, `Space`, `GetCurrentPPI`),
  virtual-tree column setup persistence (`SaveListSetup`/`RestoreListSetup`),
  `PageControlTabHighlight`, `ShowPopup`, `FilterNodesByEdit`.
- **`TDBObjectEditor`** (a `TFrame`) — base for object editor frames (table, view,
  routine, trigger, event). Provides `Init(Obj)`, `DeInit`, `Modified` property,
  and abstract `ApplyModifications`.
- Plain `TForm` is used only for a few legacy/simple dialogs (`TAboutBox`,
  `TfrmLogin`, `TfrmCrashDialog`, `TprintlistForm`, `TRoleManagerPgForm`).
  **New dialogs should use `TExtForm`.**

### Form declaration pattern
```pascal
type
  TfrmFoo = class(TExtForm)
    btnOK: TButton;
    editBar: TEdit;
    procedure FormCreate(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormDestroy(Sender: TObject);
  private
    FSomeState: Boolean;
  public
  end;

var
  frmFoo: TfrmFoo;

implementation

uses main, apphelpers;
{$R *.lfm}
{$I const.inc}
```
- A unit-global `var frmFoo: TfrmFoo;` is declared for the main reusable forms
  (mirrors Delphi auto-create forms). Modal dialogs are created locally with
  `TfrmFoo.Create(Self)` and freed after `ShowModal`.

### Editor frames (the table/view/routine/trigger/event editors)
These are **frames**, not forms, and inherit `TDBObjectEditor`:
```pascal
type
  TFrame = TDBObjectEditor;          // rebinds "TFrame" to the app base
  TfrmTableEditor = class(TFrame)
    ...
    procedure Init(Obj: TDBObject); override;       // load object into UI
    function ApplyModifications: TModalResult; override;  // save
  end;
```
- The `type TFrame = TDBObjectEditor;` alias is the idiom — copy it for new editors.
- Dispatch happens in `TMainForm.PlaceObjectEditor`:
  ```pascal
  case Obj.NodeType of
    lntTable: EditorClass := TfrmTableEditor;
    lntView: EditorClass := TfrmView;
    ...
  end;
  ActiveObjectEditor := EditorClass.Create(tabEditor);
  ActiveObjectEditor.Parent := tabEditor;
  ```
  **New object editor → add a `TListNodeType` value, a `Tfrm...Editor` frame, and a
  `case` branch in `PlaceObjectEditor`.**

### Window geometry persistence
Every resizable dialog persists its size (and often position) through `AppSettings`:
```pascal
// FormCreate / FormShow — restore
Width := AppSettings.ReadInt(asFooWindowWidth);
Height := AppSettings.ReadInt(asFooWindowHeight);
// FormDestroy / FormClose — save (scale back to design-DPI!)
AppSettings.WriteInt(asFooWindowWidth, ScaleFormToDesign(Width));
AppSettings.WriteInt(asFooWindowHeight, ScaleFormToDesign(Height));
```
- Add `asFooWindowWidth`/`asFooWindowHeight` (and Left/Top if non-centered) to the enum.
- **Always** use `ScaleFormToDesign`/`ScaleDesignToForm` when reading/writing pixel sizes.

### List/tree column persistence
```pascal
TExtForm.RestoreListSetup(listColumns);   // on show
TExtForm.SaveListSetup(listColumns);      // on close
```
This stores widths, visibility, position, and sort column under
`OwnerForm.Name + '.' + List.Name`.

---

## 8. `.lfm` form design conventions

LFM files are the source of truth for layout. Follow these rules:

- **Naming**: controls use the prefixes in §3 (`editUsername`, `comboEngine`,
  `listColumns`, `treeIndexes`, `btnSave`, `lblName`, `pnlBackground`).
- **Anchors**: use `Anchors = [akLeft, akRight, akBottom]` etc. for resizable
  controls; `Align = alTop/alClient/alBottom` for docked panels. Dialog buttons
  use `Anchors = [akRight, akBottom]`.
- **`BorderStyle = bsDialog`** for modal dialogs; `Position = poScreenCenter` or
  `poMainFormCenter`.
- **Default/ModalResult**: `Default = True` on the OK button, `ModalResult = 1` (mrOK).
  Cancel button: `ModalResult = 2`, `Cancel = True`.
- **TabOrder**: set explicitly and sequentially within each container.
- **Labels**: set `FocusControl = editFoo` so `&`-mnemonics focus the control.
- **Images**: use `ImageIndex` + `Images = MainForm.ImageListMain` — icon constants
  live in `const.inc` (`ICONINDEX_*`). Never hardcode magic image indexes in code;
  reference the named constant.
- **Virtual trees** (`TLazVirtualStringTree`): set `Header.Columns`, enable
  `TreeOptions.MiscOptions`/`PaintOptions`/`SelectionOptions` as needed. Wire
  `OnGetText`, `OnInitNode`, `OnFocusChanged`, `OnNewText` (for editing).
- **PageControls**: inactive-tab grayscale icons via `TExtForm.PageControlTabHighlight`.
- **No hardcoded pixel sizes in code** — use `TExtForm.ScaleFromDesign(value)` or
  `Space(n)` for DPI-aware spacing. The `.lfm` design coordinates are at 96 DPI.
- **`LCLVersion`** line is present at the top of each `.lfm`; leave it as-is.
- **`Color`**: prefer themed/clr constants (`clBtnFace`, `clWindow`) over raw RGB.
  For app-specific grid/highlighter colors, go through `TAppColorScheme`.

---

## 9. Theming, dark mode & colors

- **Windows**: dark mode via vendored `metadarkstyle` (`uMetaDarkStyle`,
  `uDarkStyleParams`, `uDarkStyleSchemes`). Controlled by `asThemeMode`
  (0=system, 1=light, 2=dark). Applied in `heidisql.lpr` before `Application.Initialize`.
- **Linux Qt5/Qt6**: platform palette applied via `platformtheme.pas`
  (`ApplyPlatformTheme`) — called from the `.lpr` after LCL installs its Qt hook.
- **Color schemes** (`generic_types.pas`): `TAppColorSchemes` holds presets
  (`Dark`, `Light`, `Black`, `White`) for SynEdit SQL highlighter + grid text colors.
  `ApplyDark`/`ApplyLight` swap the active scheme. `asCurrentThemeIsDark` caches state.
- **Grid colors by datatype category**: `TGridTextColors` is indexed by
  `TDBDatatypeCategoryIndex` (`dtcInteger`, `dtcReal`, `dtcText`, `dtcBinary`,
  `dtcTemporal`, `dtcSpatial`, `dtcOther`). New display colors go here, not as ad-hoc
  `TColor` constants.
- **Theme-aware system colors**: use `GetThemeColor(clHotlink)` etc., not raw RGB,
  for anything that should follow the OS theme.

**Rule**: never set a control color to a literal `$00RRGGBB` in UI code unless it's
part of a named `TAppColorScheme` preset. Use `clBtnFace`, `clWindow`, `clGrayText`, etc.

---

## 10. Internationalization (i18n)

- All user-visible strings pass through translation helpers in `apphelpers.pas`:
  ```pascal
  _('Username')                              // simple
  f_('Connection to %s closed at %s', [host, time])  // with Format args
  ```
- `f_` is the safe replacement for `Format(_(...))` — it falls back to the
  unformatted pattern on argument mismatch and logs the error.
- Translation files (`.po`/`.mo`) live in `extra/locale/`; loaded by
  `InitMoFile(AppLanguage)` in `heidisql.lpr`. `LCLTranslator.SetDefaultLang` sets
  the LCL's own translations.
- **Do not** use Lazarus's built-in `.lrj` i18n workflow (it's in `.gitignore`).
  Wrap strings with `_`/`f_` manually.
- App language stored in `asAppLanguage`; system language from `GetLanguageID.LanguageCode`.

**Rule**: every new user-facing literal string must be wrapped in `_()` or `f_()`.

---

## 11. Platform conditionals

The codebase is multi-platform. Use FPC conditionals, guarded precisely:

- `{$IFDEF WINDOWS}` / `{$IFDEF LINUX}` / `{$IFDEF DARWIN}` — for OS-specific APIs
  (Registry, Windows messages, `MacOSAll`, `iosxlocale`).
- `{$DEFINE HASMSSQL}` — set in `dbconnection.pas` for Linux+Windows only.
- `{$if defined(LINUX) and (defined(LCLQt5) or defined(LCLQt6))}` — for Qt-specific
  platform theme code (`platformtheme.pas`).
- `{$IFDEF Windows} ActiveX {$ELSE} laz.FakeActiveX {$ENDIF}` — COM shim pattern.
- `{$IF FPC_FULLVERSION<30203}` — FPC version shims (e.g. `constref` vs `const`).

**Rules**:
- Keep platform-specific `uses` inline-conditioned, not in a separate unit, when small.
- Never `{$IFDEF WINDOWS}`-out an entire unit that other units reference unconditionally —
  provide a stub on other platforms instead (see `laz.FakeActiveX`, `DelphiCompat`).
- New platform-specific code must compile on all three targets or be cleanly guarded.

---

## 12. Logging & error handling

- DB/connection logging: `Conn.Log(TDBLogCategory, Msg)` and `MainForm.LogSQL(Msg, Category)`.
  Categories: `lcError`, `lcSQL`, `lcUserSQL`, `lcInfo`, `lcDebug`, `lcScript` — gated by
  `asLogSQL`, `asLogErrors`, `asLogInfos`, `asLogDebug` settings.
- `Application.OnException := MainForm.ApplicationException` — global handler shows
  `TfrmCrashDialog`. Never swallow exceptions silently.
- SQL errors surface as `EDbError`; format with `MsgSQLError`/`MsgSQLErrorMultiStatements`.

---

## 13. Adding a feature — checklist

When adding functionality, touch these places in order:

1. **Setting?** → add `as...` to `TAppSettingIndex` + register default in `TAppSettings.Create`.
2. **New SQL?** → add `q...` to `TQueryId`; implement in the relevant `TSqlProvider` subclass(es).
3. **New DB object type?** → add `lnt...` to `TListNodeType` + `ICONINDEX_...` + an editor
   frame (inheriting `TDBObjectEditor`) + a `case` branch in `PlaceObjectEditor`.
4. **New dialog?** → `TExtForm` subclass + `.lfm` + `as...WindowWidth/Height` settings +
   `ScaleFormToDesign` on close.
5. **New collection?** → `TObjectList<T>` subclass with `Assign` + finder helpers.
6. **New user string?** → wrap in `_()` / `f_()`.
7. **New icon?** → add to the `ImageListMain` and define `ICONINDEX_*` in `const.inc`.
8. **New color?** → goes in `TAppColorScheme` (both Dark + Light presets), indexed by
   `TDBDatatypeCategoryIndex` if grid-related.

After changes: `make clean && make build-qt6` (or the matching target) must succeed
with zero new errors. Warnings 5025/5028/5066 (deprecated SynEdit symbols) are
pre-existing and acceptable; do not introduce *new* warning classes.

---

## 14. Things never to do

- ❌ Do not write classic FPC syntax (`begin...end.` blocks, `^` pointer types where
  objects suffice). This is `{$mode delphi}`: use `Self`, `FreeAndNil`, `Exit(Result)`.
- ❌ Do not use the Windows registry directly — settings go through `TAppSettings`.
- ❌ Do not hardcode SQL strings in forms or connection methods — use `TSqlProvider.GetSql`.
- ❌ Do not concatenate identifiers into SQL — use `QuoteIdent`/`QuotedName`.
- ❌ Do not touch LCL controls from `TQueryThread` — marshal via properties/logs.
- ❌ Do not introduce `.lrj`/Lazarus-auto-i18n — use `_()`/`f_()`.
- ❌ Do not fix backslash `PathDelim` in the `.lpi`/`.lfm` — it's intentional and portable.
- ❌ Do not commit `bin/`, `out/`, `lib/`, `units/`, `*.ppu`, `*.o`, `*.lps`.
- ❌ Do not add raw `$00BBGGRR` literals in UI code outside `TAppColorScheme`.
- ❌ Do not bypass `TExtForm` scaling — all pixel math goes through `ScaleFromDesign`/`Space`.

---

## 15. 语言与沟通约定

- **所有对用户的回答一律使用中文**（包括解释、总结、提问、状态汇报）。
- 代码、标识符、文件路径、命令、commit message 保持英文不变（遵循本文件其他章节的既有规范）。
- 文档（spec、README 等）除非任务要求英文，否则默认用中文撰写。

> 此约定由用户在 2026-09-23 会话中明确要求，适用于本仓库下所有后续 agent 交互。
