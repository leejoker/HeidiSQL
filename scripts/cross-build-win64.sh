#!/usr/bin/env bash
# cross-build-win64.sh — 从 Linux 交叉编译 HeidiSQL Win64 目标
#
# 用法: ./scripts/cross-build-win64.sh [--debug]
#
# 产出: out/win64/heidisql.exe
#
# 依赖:
#   - /data/fpc_tools/fpc  (FPC 3.2.2, 含 ppccrossx64 + x86_64-win64 单元)
#   - /data/fpc_tools/lazarus (Lazarus 4.x, lazbuild + win32 LCL 接口)
#
# Makefile 的 build-win64 target 未传交叉编译参数（--ws/--cpu/--os），
# 导致在 Linux 上产出 Linux 二进制然后 mv heidisql.exe 失败。
# 本脚本绕过 Makefile，直接用正确参数调 lazbuild。
set -euo pipefail

# ── 路径 ──────────────────────────────────────────────────────────
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FPC_DIR="/data/fpc_tools/fpc"
LAZARUS_DIR="/data/fpc_tools/lazarus"
LAZ_CONFIG="/data/fpc_tools/config_lazarus"
LPI="$PROJECT_ROOT/heidisql.lpi"

export PATH="$FPC_DIR/bin/x86_64-linux:$LAZARUS_DIR:$PATH"

# ── 参数 ──────────────────────────────────────────────────────────
BUILD_MODE="Release"
if [[ "${1:-}" == "--debug" ]]; then
    BUILD_MODE="Debug"
fi

# ── 编译 ──────────────────────────────────────────────────────────
echo "=== 交叉编译 Win64 ($BUILD_MODE)"

"$LAZARUS_DIR/lazbuild" \
    --primary-config-path="$LAZ_CONFIG" \
    -B \
    --bm="$BUILD_MODE" \
    --ws=win32 \
    --cpu=x86_64 \
    --os=win64 \
    "$LPI"

# ── 部署 ──────────────────────────────────────────────────────────
OUT_DIR="$PROJECT_ROOT/out/win64"
mkdir -p "$OUT_DIR"

SRC="$PROJECT_ROOT/out/heidisql.exe"
DST="$OUT_DIR/heidisql.exe"

if [[ ! -f "$SRC" ]]; then
    echo "错误: 编译产出 $SRC 不存在" >&2
    exit 1
fi

mv -v "$SRC" "$DST"
echo "=== 完成: $DST ($(du -h "$DST" | cut -f1))"
