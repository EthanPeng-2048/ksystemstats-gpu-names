# ksystemstats-gpu-names

让 KDE 系统监视器（plasma-systemmonitor）显示**真实显卡名称**，而不是 `GPU 1 / GPU 2 / GPU 3`。

> 适用：Plasma **6.6.x**（Ubuntu 26.04、Kubuntu、Debian 等定版本发行版）。
> Plasma **6.7.0 及以上已自带该修复**，不需要本仓库。

## 问题

- 系统监视器里每块 GPU 只有 `GPU 1`、`GPU 2`、`GPU 3` 这种编号，看不出哪块是独显、哪块是核显；
- 这个编号**每次重启还可能变**：同一台机器上，重启前后 `GPU 1` 可能从独显变成核显，
  于是页面里手写的中文标题（"独立显卡/核芯显卡"）全部错位；
- 这类编号不是 KDE 自己排的，而是**直接取自 `/dev/dri/cardN` 的 N**。而 `cardN` 是内核按驱动
  注册顺序分配的，开机早期还有 `simpledrm` 占用 minor 0 再释放，所以它天然会漂
  （排查过程与证据见 [docs/evidence.md](docs/evidence.md)）。

## 根因

Plasma 6.6.x 的 `ksystemstats` GPU 插件里，显示名是**写死的**：

```cpp
auto drmNumber = std::atoi(udev_device_get_sysnum(drmDevice));
auto gpuName   = i18nc("GPU %1", drmNumber + 1);   // 标签 = cardN + 1，不含任何设备信息
```

设备名其实一直都有：udev 数据库里有 `ID_MODEL_FROM_DATABASE`（systemd 的 pci hwdb 提供）。
6.6.x 里唯一能显示真名的是 NVIDIA 独显——它的 `name` 传感器由后端经 nvidia-smi/NVML 填值；
核显没有这个来源，于是永远只剩 `GPU n`。

上游 **2026-03-27 的 commit 62f949813a**（`ksystemstats: show gpu names in plasma-systemmonitor
instead of numbers for better usability`，随 **Plasma 6.7.0** 发布）把这里改成了：
按 PCI 设备枚举 + `KSysGuard::gpuName()` 从 udev 数据库读型号名，读不到才回退 `GPU n`。

## 本仓库做了什么

把那两个改动**回移到 6.6.6**，只替换一个插件文件（`ksystemstats_plugin_gpu.so`），
KDE 其余组件、系统包版本、Qt/KF6 版本一律不动：

| 文件 | 作用 |
| --- | --- |
| `patches/01-gpu-names-linuxbackend.patch` | 语义改动：PCI 枚举 + 从 hwdb 读型号名（上游逻辑回移）+ 按 PCI 路径排序固定编号 |
| `patches/02-build-tweaks.patch` | 仅构建需要：KSysGuard 版本要求放宽到 6.6.5、只构建 GPU 插件 |

比上游多做了一步：**枚举结果按 PCI 路径排序**。上游 6.7 的编号来自枚举顺序（理论上仍可能变），
这里让 `gpu0/gpu1` 与固定 PCI 地址绑定，重启后不会漂。

本机实测（Ubuntu 26.04 / Plasma 6.6.6 / GTX 850M + HD 4600）：

```
打补丁前：gpu/gpu1 标签="GPU 2"、gpu/gpu2 标签="GPU 3"（且编号随重启在 card0/card1/card2 间漂）
打补丁后：gpu0 标签=GM107M [GeForce GTX 850M]
          gpu1 标签=4th Gen Core Processor Integrated Graphics Controller
```

## 安装

```bash
git clone https://github.com/EthanPeng-2048/ksystemstats-gpu-names.git
cd ksystemstats-gpu-names
bash install.sh          # 会提示输入 sudo 密码
```

脚本流程：检查版本 → 安装编译依赖 → 下载 ksystemstats 6.6.6 源码 → 打补丁 → 只编译 GPU 插件 →
用 `dpkg-divert` 安装（`apt` 升级、`apt install --reinstall` 都不会覆盖）→ 提示重开系统监视器。

编译依赖（脚本自动装）：

```
build-essential cmake ninja-build extra-cmake-modules
qt6-base-dev qt6-declarative-dev
libkf6coreaddons-dev libkf6i18n-dev libkf6config-dev
libksysguard-dev libsensors-dev libudev-dev
```

## 验证

```bash
python3 tools/show-gpu-sensors.py
```

打印每块 GPU 的标签与 `name` 传感器值：打了补丁标签是硬件型号，没打补丁就是 `GPU n`。

## 卸载 / 还原

```bash
bash uninstall.sh
```

等价于：

```bash
sudo dpkg-divert --remove --rename \
  /usr/lib/x86_64-linux-gnu/qt6/plugins/ksystemstats/ksystemstats_plugin_gpu.so
systemctl --user stop plasma-ksystemstats.service   # 下次打开系统监视器会自动重启
```

## 注意

- 打补丁后编号固定为 `gpu0` = 独显、`gpu1` = 核显（按 PCI 拓扑排序）。旧页面里引用
  `gpu/gpu2` 的部件会失效，改成 `gpu0`；同时建议删掉页面里手写的自定义标题，
  真实设备名会自动显示（`Face-XXXX][SensorLabels]` 那一段）。
- 仅在 **Ubuntu 26.04 + Plasma 6.6.6 + Qt 6.10.2 + KF6 6.24 + KSysGuard 6.6.5** 上验证过。
  其他 6.6.x 大致可用，但如果源码有差异补丁可能打不上（脚本会先 `--dry-run` 检查并报错）。
- 不想打补丁的话，`sudo apt install nvtop` 也能按设备名同时显示核显和独显。

## 许可

补丁是 KDE `ksystemstats` 源码的衍生修改，沿用上游许可：
`GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL`（文本见 `LICENSES/`）。
本仓库的脚本与文档使用同一许可。

## 致谢

- 上游修复作者：Bernhard Friedreich <friesoft@gmail.com>（commit `62f949813a`）
- KDE `ksystemstats`、`libksysguard` 项目
