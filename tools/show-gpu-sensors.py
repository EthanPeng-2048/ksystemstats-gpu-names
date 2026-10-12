#!/usr/bin/env python3
#
# SPDX-FileCopyrightText: 2026 EthanPeng-2048
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
#
# 打印 ksystemstats 当前暴露的 GPU 传感器：标签 + 设备名。
# 未打补丁时标签形如 "GPU 2"（= cardN+1）；打了本仓库补丁后是硬件型号名。
#
# 用法: python3 tools/show-gpu-sensors.py

import json
import subprocess
import sys

SERVICE = "org.kde.ksystemstats1"
OBJECT = "/org/kde/ksystemstats1"
IFACE = "org.kde.ksystemstats1"


def call(method, *args):
    cmd = ["busctl", "--user", "call", "--json=short", SERVICE, OBJECT, IFACE, method]
    if args:
        cmd += ["as", str(len(args)), *args]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        print(f"调用 ksystemstats 失败：{proc.stderr.strip() or '无输出'}", file=sys.stderr)
        print("提示：打开一次“系统监视器”会激活 plasma-ksystemstats 服务。", file=sys.stderr)
        sys.exit(1)
    return json.loads(proc.stdout)["data"][0]


def main():
    sensors = call("allSensors")
    name_ids = sorted(k for k in sensors if k.startswith("gpu/gpu") and k.endswith("/name"))
    if not name_ids:
        print("没有发现 GPU 传感器（驱动或 ksystemstats 插件可能未加载）。")
        return

    values = {k: v["data"] for k, v in call("sensorData", *name_ids)}
    generic = 0
    print(f"GPU 传感器数量: {len(name_ids)}\n")
    for sid in name_ids:
        node = sid.rsplit("/", 1)[0]               # gpu/gpuN
        label = sensors[node][0]
        name = values.get(sid, "")
        if label == name and label.startswith("GPU "):
            generic += 1
        print(f"  {node:<10} 标签={label}")
        print(f"  {'':<10} name 传感器值={name}")
    print()
    if generic:
        print(f"结论：有 {generic} 块 GPU 的标签是 “GPU n” 这种占位名 → 说明尚未打本补丁。")
    else:
        print("结论：标签都是真实设备名 → 补丁已生效（或 Plasma ≥ 6.7）。")


if __name__ == "__main__":
    main()
