# HeidiSQL Lazarus/FreePascal port
[![Build Status](https://github.com/HeidiSQL/HeidiSQL/actions/workflows/lazarus.yaml/badge.svg?branch=lazarus)](https://github.com/HeidiSQL/HeidiSQL/actions)
[![Supports Windows](https://img.shields.io/badge/support-Windows-blue?logo=Windows)](https://github.com/HeidiSQL/HeidiSQL/releases/latest)
[![Supports Linux](https://img.shields.io/badge/support-Linux-yellow?logo=Linux)](https://github.com/HeidiSQL/HeidiSQL/releases/latest)
[![Supports macOS](https://img.shields.io/badge/support-macOS-black?logo=macOS)](https://github.com/HeidiSQL/HeidiSQL/releases/latest)
[![License](https://img.shields.io/github/license/HeidiSQL/HeidiSQL?logo=github)](https://github.com/HeidiSQL/HeidiSQL/blob/main/LICENSE)
[![Latest Release](https://img.shields.io/github/v/release/HeidiSQL/HeidiSQL?label=latest%20release&logo=github)](https://github.com/HeidiSQL/HeidiSQL/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/HeidiSQL/HeidiSQL/total?logo=github)](https://github.com/HeidiSQL/HeidiSQL/releases)


This is the code base for compiling HeidiSQL on Linux and macOS. From v13 onwards, the Windows version
will be compiled from here.

Since February 2025 I am migrating the sources from the master branch, using Lazarus and FreePascal. I
left away some Windows-only stuff which won't ever work on other platforms, such as some Windows message
handlings, and ADO driver usage. Therefore, support for MS SQL is being redeveloped via FreeTDS
(formerly ADO), but is not yet fully mature.  

Ansgar

![HeidiSQL GTK2 running on Ubuntu Linux 22.04](https://www.heidisql.com/images/screenshots/linux_version_datagrid.png)

---

## 本 fork 新增功能

本仓库是 [HeidiSQL/HeidiSQL](https://github.com/HeidiSQL/HeidiSQL) `lazarus` 分支的 fork
（`leejoker/HeidiSQL`），在上游 Lazarus/FPC 移植的基础上补充了以下能力：

### 1. Redis 支持

将 Redis 接入既有的 `TDBConnection` 体系，可像关系型数据库一样浏览、查询和编辑 Redis 数据：

- **RESP 协议客户端**（`source/redisclient.pas`）：自实现 RESP 编解码，复用统一的
  `Query`/`GetResults` 接口；引擎元数据由 `source/dbstructures.redis.pas` 提供。
- **数据网格浏览**：键按命名空间分组展示于数据库树；字符串/Hash/List/Set/ZSet 等
  类型以网格形式呈现，键列不创建编辑器，Redis 键默认打开 Data 标签页。
- **网格内编辑**：`SaveModifications`/`InsertRow`/`DeleteRow` 等 `TDBQuery` 编辑方法
  被虚化并由 Redis 重写，支持增删改 Hash field、List 元素、Set/ZSet 成员等。
- **大值懒加载 + JSON 格式化 + 图片预览**：大 value 按需加载；JSON 使用 fpjson 格式化
  （不依赖外部 jq）；图片类型提供预览与 Images/Raw 切换。
- **键右键菜单**：重命名、设置/取消 TTL、查看 TTL、复制键名、新建键
  （`source/redis_newkey.pas` 新建键对话框）。
- **信息栏**：显示当前键的 `TYPE` / `SIZE` / `TTL` / `MEMORY USAGE`。

设计文档见 `docs/superpowers/specs/2026-09-20-redis-support-design.md` 与
`2026-09-21-redis-editing-design.md`；冒烟测试清单见 `docs/redis-editing-smoke-test.md`；
协议层测试见 `tests/test_redis_proto.lpr`。

### 2. DBeaver 会话导入

一键把 DBeaver 保存的连接配置（`data-sources.json` + 凭据文件）导入 HeidiSQL 会话管理器，
入口在会话管理器 `More >` 弹出菜单与主菜单 `File > Import DBeaver sessions ...`：

- `source/dbeaver_import.pas`：解析 DBeaver 的 connections 数据源，转换为
  `TDBeaverImportEntry`。
- `source/dbeaver_import_dlg.pas`：导入对话框（`TExtForm` 子类），逐条勾选并映射到
  对应的 `TNetType` 引擎。
- 单元测试见 `tests/test_dbeaver_import.lpr`。

设计文档见 `docs/superpowers/specs/2026-09-23-dbeaver-import-gui-design.md`（TUI 版设计已随
`db-tui` 模块迁至其仓库 `docs/specs/` 下）。

### 3. Win64 交叉编译脚本

`scripts/cross-build-win64.sh`：在 Linux 上直接交叉编译出 `out/win64/heidisql.exe`
（绕过 Makefile `build-win64` target 未传 `--ws/--cpu/--os` 参数的问题），
支持 `--debug` 开关。用法：

```bash
./scripts/cross-build-win64.sh [--debug]
```

---

### Building
Install Lazarus 4.4 and FreePascal. Then load the `.lpi` file in the root directory in the Lazarus IDE.
Alternatively, use `/usr/bin/lazbuild heidisql.lpi` on the command line.

### Icons8 copyright
Icons added in January 2019 are copyright by [Icons8](https://icons8.com). Used with a special permission
from Icons8 given to Ansgar for this project only. Do not copy them for anything else other than building
HeidiSQL.

[![Lazarus logo.](https://www.heidisql.com/images/powered-by-lazarus.png)](https://www.lazarus-ide.org/)

