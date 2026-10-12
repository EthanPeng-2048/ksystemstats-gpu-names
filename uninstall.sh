#!/usr/bin/env bash
#
# SPDX-FileCopyrightText: 2026 EthanPeng-2048
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
#
# 还原发行版自带的 ksystemstats GPU 插件。

set -euo pipefail

PLUGIN_FILE="/usr/lib/x86_64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so"

[[ $EUID -ne 0 ]] || { echo "不要用 root 运行（需要 systemctl --user）。" >&2; exit 1; }

if ! dpkg-divert --list "${PLUGIN_FILE}" | grep -q .; then
    echo "没有找到 diversion，说明当前不是本补丁安装的状态。"
    exit 0
fi

systemctl --user stop plasma-ksystemstats.service 2>/dev/null || true
sudo dpkg-divert --remove --rename "${PLUGIN_FILE}"
echo "已还原为发行版原文件。"
echo "下次打开系统监视器时 plasma-ksystemstats 会自动重启并加载原插件。"
