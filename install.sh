#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 EthanPeng-2048
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
#
# 让 KDE 系统监视器显示真实显卡名称，而不是 GPU 1/2/3。
# 做法：把上游 ksystemstats 6.7.0 的"读设备名 + 按 PCI 枚举"改动回移到 6.6.6，
#       只替换 GPU 插件这一个文件，其余 KDE 组件与包版本不动。
#
# 用法：
#   bash install.sh [--no-deps] [--dry-run]
#     --no-deps   跳过安装编译依赖（自己已装好时用）
#     --dry-run   只做检查与编译，不安装到系统

set -euo pipefail

SRC_VERSION="6.6.6"
TARBALL_URL="https://invent.kde.org/plasma/ksystemstats/-/archive/v${SRC_VERSION}/ksystemstats-v${SRC_VERSION}.tar.gz"
PLUGIN_DIR="/usr/lib/x86_64-linux-gnu/qt6/plugins/ksystemstats"
PLUGIN_FILE="${PLUGIN_DIR}/ksystemstats_plugin_gpu.so"
DIVERT_SUFFIX=".distrib"
BUILD_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/ksystemstats-gpu-names"
SRC_DIR="${BUILD_ROOT}/ksystemstats-v${SRC_VERSION}"
BUILD_DIR="${BUILD_ROOT}/build"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DEV_PACKAGES=(
    build-essential cmake ninja-build
    extra-cmake-modules
    qt6-base-dev qt6-declarative-dev
    libkf6coreaddons-dev libkf6i18n-dev libkf6config-dev
    libksysguard-dev libsensors-dev libudev-dev
)

SKIP_DEPS=0
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --no-deps) SKIP_DEPS=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数: $arg（见 --help）" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { printf '\033[31m错误: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -ne 0 ]] || die "不要用 root 运行：最后一步需要 systemctl --user。"
command -v apt-get >/dev/null || die "本脚本面向 Ubuntu/Debian。"
for p in "${SCRIPT_DIR}"/patches/*.patch; do
    [[ -f "$p" ]] || die "缺少补丁文件（patches/*.patch），请在仓库根目录运行。"
done

installed="$(dpkg-query -W -f='${Version}' ksystemstats 2>/dev/null || echo '未知')"
step "当前 ksystemstats 版本: ${installed}"
case "$installed" in
    6.6.*) ;;
    6.7.*|6.8.*|6.9.*|[7-9].*)
        die "你已经是 ${installed}，上游从 6.7.0 起自带该修复，不需要本补丁。" ;;
    *) printf '警告: 补丁是按 6.6.6 写的，你的版本是 %s，可能打不上。\n' "$installed" ;;
esac

if [[ $SKIP_DEPS -eq 0 && $DRY_RUN -eq 0 ]]; then
    step "1/6 安装编译依赖（会提示输入 sudo 密码）"
    sudo apt-get install -y --no-install-recommends "${DEV_PACKAGES[@]}"
else
    step "1/6 跳过依赖安装"
fi

step "2/6 准备源码"
mkdir -p "${BUILD_ROOT}"
if [[ ! -f "${SRC_DIR}/CMakeLists.txt" ]]; then
    curl -fSL --retry 3 -o "${BUILD_ROOT}/ksystemstats-v${SRC_VERSION}.tar.gz" "${TARBALL_URL}"
    tar xzf "${BUILD_ROOT}/ksystemstats-v${SRC_VERSION}.tar.gz" -C "${BUILD_ROOT}"
fi
echo "源码: ${SRC_DIR}"

step "3/6 打补丁"
cd "${SRC_DIR}"
if [[ -f .patched ]]; then
    echo "已打过补丁，跳过。"
else
    for p in "${SCRIPT_DIR}"/patches/*.patch; do
        echo "-- $(basename "$p")"
        patch -p1 --dry-run < "$p" >/dev/null || die "$(basename "$p") 打不上（源码版本不符？）"
        patch -p1 < "$p"
    done
    touch .patched
fi

step "4/6 配置并编译（只编译 ksystemstats_plugin_gpu）"
cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SKIP_RPATH=ON \
    -DBUILD_TESTING=OFF
cmake --build "${BUILD_DIR}" --target ksystemstats_plugin_gpu

NEW_PLUGIN="${BUILD_DIR}/bin/ksystemstats_plugin_gpu.so"
[[ -f "${NEW_PLUGIN}" ]] || die "编译产物不存在: ${NEW_PLUGIN}"
echo "产物: ${NEW_PLUGIN}"

if [[ $DRY_RUN -eq 1 ]]; then
    step "dry-run：到此为止，未安装任何文件"
    exit 0
fi

step "5/6 安装插件（dpkg-divert 保护，apt 升级不会覆盖）"
[[ -f "${PLUGIN_FILE}${DIVERT_SUFFIX}" || -f "${PLUGIN_FILE}" ]] \
    || die "${PLUGIN_FILE} 不存在，系统里没装 ksystemstats 插件？"
systemctl --user stop plasma-ksystemstats.service 2>/dev/null || true
if dpkg-divert --list "${PLUGIN_FILE}" | grep -q .; then
    echo "已存在 diversion，直接覆盖插件文件。"
else
    sudo dpkg-divert --add --rename --divert "${PLUGIN_FILE}${DIVERT_SUFFIX}" "${PLUGIN_FILE}"
    echo "发行版原文件已备份为 ${PLUGIN_FILE}${DIVERT_SUFFIX}"
fi
sudo install -m 644 -o root -g root "${NEW_PLUGIN}" "${PLUGIN_FILE}"

step "6/6 完成"
echo "现在打开系统监视器（plasma-systemmonitor）即可看到真实显卡名。"
echo "对照检查可运行: python3 ${SCRIPT_DIR}/tools/show-gpu-sensors.py"
echo
echo "还原发行版原文件: bash ${SCRIPT_DIR}/uninstall.sh"
