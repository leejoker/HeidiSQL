# DBeaver 会话导入 HeidiSQL GUI — 设计文档

**日期**：2026-09-23
**状态**：待实现（已通过头脑风暴确认关键决策）
**目标模块**：`source/`（HeidiSQL 主 GUI，Lazarus/FPC）
**关联文档**：`docs/superpowers/specs/2026-09-23-dbeaver-import-design.md`（TUI 版，已实现并验证 DBeaver 格式细节，本设计复用其源码确认结论）

---

## 1. 背景与目标

用户在本机用 DBeaver 管理数据库连接，希望把这些连接快速迁到 **HeidiSQL GUI** 的会话管理器
（`Tconnform` / `ListSessions`），避免逐条手敲。TUI 版（`heidisql-tui import-dbeaver`）已实现并
验证了 DBeaver 的存储格式与 AES 凭据解密算法，但仅覆盖 postgres+redis 且写入 `config.toml`。
本设计把同一能力移植到 GUI：解析 DBeaver workspace → 映射为 `TConnectionParameters` →
`SaveToRegistry` 写入 HeidiSQL 会话注册表 → 刷新会话树。

### 关键决策（头脑风暴结论）

| 维度 | 决策 |
|---|---|
| 入口 | 会话管理器 "More" 弹出菜单 + 主窗口 File 菜单各加一项 "Import DBeaver sessions…" |
| 密码处理 | 尽量解密 DBeaver `credentials-config.json`（AES-128-CBC，公开硬编码密钥）；解不出/无文件则该连接置 `LoginPrompt=True`、密码留空 |
| 冲突处理 | 同名会话追加后缀 ` (2)`、` (3)`，绝不覆盖已有会话 |
| 引擎覆盖 | 全部可映射引擎：MySQL/MariaDB、PostgreSQL、MS SQL Server、SQLite、Interbase/Firebird、Redis。不支持的（Oracle/DB2 等）跳过并在摘要里列出 |
| 格式范围 | 仅 DBeaver 6.1.3+ 现代 JSON 格式（`data-sources.json` + 加密 `credentials-config.json`）。不支持旧版 XML |
| 加密依赖 | 自带纯 Pascal AES-128-CBC 实现，不新增第三方/系统依赖 |
| 进程 | 先写本设计文档，确认后直接实现 |

### 非目标（YAGNI）

- 旧版 XML（`.dbeaver-data-sources.xml`，6.1.3 以前）
- DBeaver master-password 模式（用户自设主密码）—— 公开硬编码密钥模式覆盖绝大多数默认安装
- 反向导出（HeidiSQL → DBeaver）
- 导入后自动连通性校验
- 多 workspace 批量导入（一次一个 workspace）
- DBeaver SSH 隧道的完整等价映射（见 §6 说明：仅做 best-effort 字段搬运）

---

## 2. DBeaver 配置格式（复用 TUI 版源码确认结论）

以下字段名与加密方案已在 TUI 实现中对照 DBeaver 源码确认并通过单测验证。

### 2.1 Workspace 定位

`<workspace>` 即 `.dbeaver` 目录，OS 候选路径（按优先级，首个存在者胜出）：

| OS | 候选路径 |
|---|---|
| Linux | `~/.local/share/DBeaverData/workspace6/General/.dbeaver/` |
| Linux(snap) | `~/snap/dbeaver-ce/current/.local/share/DBeaverData/workspace6/General/.dbeaver/` |
| Linux(flatpak) | `~/.var/app/io.dbeaver.DBeaverCommunity/data/DBeaverData/workspace6/General/.dbeaver/` |
| macOS | `~/Library/DBeaverData/workspace6/General/.dbeaver/` |
| macOS(HB Cask) | `~/Library/Application Support/DBeaverData/workspace6/General/.dbeaver/` |
| Windows | `%APPDATA%\DBeaverData\workspace6\General\.dbeaver\` |

对话框允许用户手动指定 `data-sources.json` 路径，自动从同目录找 `credentials-config.json`。

### 2.2 data-sources.json

```json
{
  "folders": {
    "<folderId>": { "name": "Work", "description": "" }
  },
  "connections": {
    "<connId>": {
      "provider": "mysql",
      "driver": "mysql8",
      "name": "my-prod",
      "folder": "<folderId>",
      "save-password": true,
      "configuration": {
        "host": "10.0.0.5",
        "port": "3306",
        "database": "appdb",
        "user": "root",
        "url": "jdbc:mysql://10.0.0.5:3306/appdb",
        "properties": { "ssl.use": "true", "ssl.mode": "required" }
      }
    }
  }
}
```

关键字段：`name`、`provider`、`driver`、`folder`、`configuration.{host,port,database,user,url,properties}`。
`port` 为字符串。`configuration` 在个别版本可能是序列化字符串，解析时容错。

### 2.3 credentials-config.json（加密）

- **算法**：AES-128-CBC，PKCS7 padding
- **密钥**：16 字节硬编码常量 `LOCAL_KEY_CACHE` = hex `babb4a9f774ab853c96c2d653dfe544a`
  （来源 DBeaver 源码 `BaseProjectImpl.LOCAL_KEY_CACHE`，公开常量）
- **文件布局**：前 16 字节 = IV，其余 = 密文
- **解密后 JSON**：
  ```json
  { "<connId>": { "#connection": { "user": "root", "password": "s3cret" } } }
  ```

### 2.4 格式回退

`LoadCredentials` 按顺序尝试，首个成功即用，全失败返回空 map（不阻断导入，仅缺密码）：
1. 整文件 AES-CBC 解密（DBeaver 21+，主流）
2. 纯 JSON 直读（极旧版 / master-password 关闭明文落盘）
3. Base64 解码后 JSON 解析

---

## 3. 项目布局（新增/修改）

| 文件 | 职责 | 创建/修改 |
|---|---|---|
| `source/dbeaver_import.pas` | 纯逻辑单元（无 LCL）：AES-128-CBC 解密（纯 Pascal）+ PKCS7、`fpjson` 解析、provider→NetType 映射、JDBC url 解析、`Import` 编排。依赖 `dbconnection`（用 `TConnectionParameters`/`AppSettings`） | 创建 |
| `source/dbeaver_import_dlg.pas` + `.lfm` | `TfrmDBeaverImport`（`TExtForm`）：文件选择、选项、结果摘要、Import 按钮 | 创建 |
| `source/main.pas` + `source/main.lfm` | 新增 `actImportDBeaverSessions` action + File 菜单项 + 会话管理器 `popupMore` 菜单项 | 修改 |
| `tests/test_dbeaver_import.lpr` | 纯逻辑单测：AES 往返、provider→NetType、JDBC 解析、字段映射、端到端 Import（临时目录构造 workspace） | 创建 |
| `source/const.inc` | 如需新图标索引常量则加（尽量复用现有 `ICONINDEX_*`） | 视情况修改 |

### 模块边界

- `dbeaver_import.pas`：核心解析/解密/映射逻辑，仅依赖 `dbconnection` + FCL（`fpjson`、`base64`、`SysUtils`）。不依赖 LCL，可被 `tests/test_dbeaver_import.lpr` 独立单测。
- `dbeaver_import_dlg.pas`：UI 编排，依赖 `dbeaver_import` + `connections`（刷新会话树）+ `apphelpers`。
- 现有会话管理器/主窗口行为零改动，仅新增菜单入口。

---

## 4. dbeaver_import.pas 设计

### 4.1 类型

```pascal
type
  TDBeaverCredentials = record
    User, Password: string;
  end;

  TDBeaverDataSource = record
    Id, Provider, Driver, Name, Folder: string;
    Configuration: TJSONObject;   // fpjson，按需取字段
  end;

  // 单条导入结果（用于摘要展示）
  TDBeaverImportEntry = record
    Name, Engine, Host: string;
    Port: Integer;
    Status: (isImported, isSkipped, isNeedsPassword);
    Reason: string;               // skipped 原因 / needs-password 提示
  end;

  TDBeaverImportResult = record
    Imported, Skipped, NeedsPassword: Integer;
    Entries: array of TDBeaverImportEntry;
    CredentialsDecrypted: Boolean; // 是否成功解出凭据文件
  end;
```

### 4.2 公开函数

```pascal
// 探测 DBeaver .dbeaver 目录；explicit 非空则直接用。
function DBeaverFindWorkspace(const Explicit: string): string;

// 解析 <ws>/data-sources.json → 连接列表（含 folder 信息）。
function DBeaverLoadDataSources(const Workspace: string;
  out DataSources: TArray<TDBeaverDataSource>; out Folders: TJSONObject): Boolean;

// 解密 <ws>/credentials-config.json → map[connId]credentials。失败返回空。
function DBeaverLoadCredentials(const Workspace: string;
  out Creds: TDictionary<string,TDBeaverCredentials>; out Decrypted: Boolean): Boolean;

// 主入口：读取 + 映射 + 写入 HeidiSQL 会话注册表。TryPasswords 控制是否尝试解密凭据。
function DBeaverImport(const Workspace: string; TryPasswords: Boolean;
  out Result: TDBeaverImportResult): Boolean;
```

### 4.3 provider → NetType 映射

按 `provider`+`driver` 拼接小写后子串匹配（容错变体）：

| 命中子串 | HeidiSQL NetType | 引擎 |
|---|---|---|
| `mysql` / `mariadb` | `ntMySQL_TCPIP`（有 SSH 时 `ntMySQL_SSHtunnel`） | MySQL/MariaDB |
| `postgres` | `ntPgSQL_TCPIP`（有 SSH 时 `ntPgSQL_SSHtunnel`） | PostgreSQL |
| `sqlserver` / `mssql` | `ntMSSQL_TCPIP` | MS SQL Server |
| `sqlite` | `ntSQLite` | SQLite |
| `interbase` / `firebird` | `ntInterbase_TCPIP` | Interbase/Firebird |
| `redis` | `ntRedis_TCPIP` | Redis |
| 其他 | — | 跳过（isSkipped） |

### 4.4 字段映射（DBeaver → TConnectionParameters）

| `TConnectionParameters` 属性 | 来源 |
|---|---|
| `SessionPath` | 文件夹链 + `ValidFilename(name)`；同名冲突追加后缀 |
| `NetType` | §4.3 |
| `Hostname` | `configuration.host`；空则从 `url` JDBC 解析 |
| `Port` | `configuration.port` 字符串→int；空则按引擎默认（mysql 3306 / pg 5432 / mssql 1433 / redis 6379 / firebird 3050） |
| `Username` | credentials.user 优先，空回退 `configuration.user` |
| `Password` | credentials.password（解密成功时）；否则空 + `LoginPrompt := True` |
| `AllDatabasesStr` | `configuration.database`（redis 为 db 索引，仍写入此字段无副作用） |
| `WantSSL` + SSL 字段 | `configuration.properties` 中 `ssl.use`/`ssl.mode`：`required`/`verify-ca`/`verify-full` → `WantSSL=True` + `SSLVerification` 对应 |
| `Comment` | `DBeaver: <provider>/<driver>` 便于追溯 |
| `SSH*`（best-effort） | `properties` 中 `ssh.host`/`ssh.port`/`ssh.user`/`ssh.key.path` 存在时搬运；因 HeidiSQL SSH 走外部 plink/ssh exe，仅填字段不自动切到 SSHtunnel NetType（避免误连），由用户在会话管理器里确认 |

> SSH 说明：DBeaver 内置 SSH，HeidiSQL 走外部进程隧道，两者模型不同。v1 只搬运 SSH host/user/port/key 字段供用户参考，不自动启用 `SSHActive`，避免导入即误触发隧道。完整 SSH 隧道导入列为后续扩展。

### 4.5 冲突与文件夹处理

- **文件夹**：DBeaver `folders` → HeidiSQL 文件夹会话（`IsFolder=True`）。文件夹可嵌套，按 `SessionPath` 用 `/` 拼接保留层级。先建文件夹会话，再建连接会话挂到对应父路径。
- **同名冲突**：写入前用 `AppSettings.SessionPathExists` 检测；存在则给 `SessionName` 追加 ` (2)`、` (3)` 直到唯一。绝不覆盖。

### 4.6 解密实现要点（纯 Pascal AES-128-CBC）

- 自带 AES-128 解密（S-box、InvSubBytes/InvShiftRows/InvMixColumns、AddRoundKey、逆列混淆），仅实现解密路径（导入只需解密）。
- CBC：`plain[i] = AES_decrypt(ct[i]) xor ct[i-1]`，`ct[-1] = IV`。
- PKCS7 去填充：取末字节 n（1..16），校验末 n 字节全等于 n，截断。
- 密钥常量：`localKey: array[0..15] of Byte = ($ba,$bb,$4a,$9f,$77,$4a,$b8,$53,$c9,$6c,$2d,$65,$3d,$fe,$54,$4a);`
- 无外部依赖，跨 widgetset 一致。

---

## 5. UI 流程（TfrmDBeaverImport）

```
用户点 "Import DBeaver sessions…"
  → 打开 TfrmDBeaverImport 对话框
     - editDataSources: EditButton（文件选择，默认 DBeaverFindWorkspace 自动探测）
     - editCredentials: EditButton（文件选择，默认同目录 credentials-config.json；可空）
     - chkImportPasswords: TCheckBox（默认勾选）
     - memoResult: TMemo（只读，展示导入摘要）
     - btnImport / btnClose
  → btnImport:
     1. workspace = editDataSources 所在目录（或显式 workspace）
     2. DBeaverLoadDataSources + (chkImportPasswords ? DBeaverLoadCredentials : 空)
     3. DBeaverImport → 写入注册表
     4. if Assigned(connform) then connform.RefreshSessions(nil)
     5. memoResult 填摘要：Imported N / Skipped M / NeedsPassword K + 逐条列表
     6. MessageDialog 提示完成
```

对话框复用 `TExtForm`、`EditButton` + `TExtFileOpenDialog`（与 `loaddata.pas` 等一致）。

---

## 6. 错误处理

| 场景 | 处理 |
|---|---|
| workspace 未找到 / data-sources.json 缺失 | 对话框报错，不导入 |
| data-sources.json 解析失败 | 对话框报错，不导入 |
| credentials 文件缺失 | 正常导入，所有连接 isNeedsPassword |
| 解密失败 | 回退纯 JSON → base64；全失败则空，isNeedsPassword |
| port 非数字 | 跳过该字段用引擎默认 |
| provider 不可映射 | isSkipped，记 reason |
| 同名会话 | 自动加后缀，不覆盖 |
| 写注册表异常 | 捕获，对话框报错，已写入的保留 |

任何路径都不抛未捕获异常到 UI。

---

## 7. 测试策略

`tests/test_dbeaver_import.lpr`（独立控制台程序，沿用 `test_redis_proto.lpr` 模式，不依赖 FPCUnit）：

- **AES 往返**：测试内用已知密钥+随机 IV 加密一段凭据 JSON，调用解密，断言解出正确 user/password。
- **格式回退**：同一明文 JSON 分别以纯文本、base64 写入，断言两种回退都能解出。
- **provider→NetType**：`mysql8`→ntMySQL_TCPIP、`postgres-jdbc`→ntPgSQL_TCPIP、`sqlserver`→ntMSSQL_TCPIP、`sqlite`→ntSQLite、`firebird`→ntInterbase_TCPIP、`redis-ce`→ntRedis_TCPIP、`oracle`→跳过。
- **JDBC url 解析**：`jdbc:postgresql://h:5432/db?x=1` → host/port/database。
- **字段映射**：构造含 host/port/database/user + credentials 的 DataSource，断言映射到 `TConnectionParameters` 各字段。
- **冲突后缀**：模拟已存在同名会话，断言新会话加 ` (2)`。
- **端到端 Import**：临时目录写 `data-sources.json` + 加密 `credentials-config.json`，调用 `DBeaverImport`，断言注册表出现导入的会话（用 `AppSettings.SessionPathExists` 校验）。

> 端到端测试会写真实 `AppSettings` 注册表；用 `AppSettings.StorePath`/`RestorePath` 或临时会话路径隔离，避免污染用户配置。

---

## 8. 安全说明

- DBeaver 的 AES 密钥是**公开硬编码**于 DBeaver 源码的常量，非秘密。本工具复用该密钥解密本机用户自己的凭据，不构成密钥泄露。
- 解密后的明文密码经 HeidiSQL 既有 `encrypt()` 存入会话注册表（与手工保存的会话一致），不引入新的明文落盘点。
- 不做：master password 模式、传输加密、密码二次加密存储。

---

## 9. 交付边界

本设计完成后直接进入实现：新增 `dbeaver_import.pas` + `dbeaver_import_dlg.*` + `main` 菜单入口 +
`tests/test_dbeaver_import.lpr`，并在 Qt6 Release 下构建通过。后续扩展（旧版 XML、master-password、
完整 SSH 隧道导入、连通性校验）不在本次范围。
