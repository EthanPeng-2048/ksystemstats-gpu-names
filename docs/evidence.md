# 排查记录：为什么 KDE 里的显卡编号会变

以下内容全部来自一台真实机器：**Ubuntu 26.04、Plasma 6.6.6、Intel HD 4600（Haswell）+ NVIDIA
GTX 850M（Optimus 按需模式）、内核 7.0.0-38**。

## 1. 现象

- `plasma-systemmonitor` 的 GPU 传感器只有 `GPU 1/2/3`，且重启后会换位；
- 用户自己写的中文标题（`独立显卡` / `核芯显卡`）随之错乱。

页面配置文件 `~/.local/share/plasma-systemmonitor/overview.page` 里同时存在三个编号：

```ini
[Face-106123406501568][SensorLabels]
gpu/gpu0/usage=独立显卡 使用率
gpu/gpu1/usage=核芯显卡 使用率
gpu/gpu2/usage=核心显卡 使用率

[Face-106123406501568][Sensors]
highPrioritySensorIds=["gpu/gpu1/usage","gpu/gpu0/usage"]
lowPrioritySensorIds=["gpu/gpu0/temperature"]
```

`gpu0` 的条目后来成了"丢失的传感器"——因为那次启动里根本没有 `card0`。

## 2. 编号来自 `/dev/dri/cardN`，而 cardN 本身不固定

内核 DRM 在注册设备时按"当前最小空闲号"分配 card/render 号，跟 PCI 地址无关。
本机一个启动周期里会注册三个 DRM 设备，于是编号取决于时序：

| 启动 | 内核日志 | 结果 |
| --- | --- | --- |
| 10-08 ~ 10-12 早（boot -4 ~ -1） | `simpledrm ... minor 0`、`i915 ... minor 1`、`nvidia-drm ... minor 0` | card0=NVIDIA、card1=Intel |
| 今天 20:55（boot 0） | `simpledrm ... minor 0`、`nvidia-drm ... minor 1`、`i915 ... minor 2` | card1=NVIDIA、card2=Intel（没有 card0） |

关键点：开机早期的 `simpledrm`（UEFI GOP 帧缓冲）先占住 minor 0，Intel 接管显示时它会注销并释放 0；
`nvidia-drm`（initramfs 里加载）和 `i915`（倾向异步 probe）谁先注册是竞争关系，于是
"nvidia 是拿释放出来的 0，还是拿 1"、"Intel 是 1 还是 2" 会随启动变化。
`/dev/dri/renderD128|129` 用同一套分配器，因此核显的 render 节点也会在 128/129 之间跳。

查询方式：

```bash
for d in /sys/class/drm/card*; do
  echo "$(basename $d) -> $(basename $(readlink -f $d/device)) $(basename $(readlink -f $d/device/driver))"
done
ls -l /dev/dri/by-path/          # 只有按 PCI 地址命名的 by-path 链接是稳定的
```

## 3. KDE 6.6.x 直接把 cardN 当成了显示编号

`ksystemstats` v6.6.6 `plugins/gpu/LinuxBackend.cpp`：

```cpp
udev_enumerate_add_match_property(enumerate, "DEVTYPE", "drm_minor");
udev_enumerate_add_match_subsystem(enumerate, "drm");
...
auto drmNumber = std::atoi(udev_device_get_sysnum(drmDevice));
auto gpuId     = QStringLiteral("gpu%1").arg(drmNumber);
auto gpuName   = i18nc("@title %1 is GPU number", "GPU %1", drmNumber + 1);
```

所以 `GPU 2` 的意思就是"`card1` 加一"，设备信息为零。用 DBus 能直接看到这一点：

```bash
busctl --user call --json=short org.kde.ksystemstats1 /org/kde/ksystemstats1 \
  org.kde.ksystemstats1 allSensors | python3 -c 'import json,sys; d=json.load(sys.stdin)["data"][0]; \
  [print(k, v[0]) for k in sorted(d) if k.startswith("gpu/gpu") and k.endswith("/name")]'
```

当时的输出（`gpuN` 就是 `cardN`）：

```
gpu/gpu1/name name='GPU 2 名称'          # card1 = NVIDIA
gpu/gpu2/name name='GPU 3 名称'          # card2 = Intel
```

而 `name` 传感器的**值**却是有内容的：

```bash
busctl --user call org.kde.ksystemstats1 /org/kde/ksystemstats1 org.kde.ksystemstats1 sensorData \
  as 2 "gpu/gpu1/name" "gpu/gpu2/name"
# gpu/gpu1/name = NVIDIA GeForce GTX 850M   （NVIDIA 后端经 NVML/nvidia-smi 填的）
# gpu/gpu2/name = GPU 3                     （核显没有名字来源，回退成标签本身）
```

## 4. 设备名一直都在 udev 数据库里

```bash
systemd-hwdb query 'pci:v000010DEd00001391sv00001028sd0000064Esd*bc03sc02i00*'
#   ID_MODEL_FROM_DATABASE=GM107M [GeForce GTX 850M]
systemd-hwdb query 'pci:v00008086d00000416sv00001028sd0000064Esd*bc03sc00i00*'
#   ID_MODEL_FROM_DATABASE=4th Gen Core Processor Integrated Graphics Controller
cat /run/udev/data/+pci:0000:01:00.0 | grep MODEL
#   E:ID_MODEL_FROM_DATABASE=GM107M [GeForce GTX 850M]
```

## 5. 上游怎么修的

`ksystemstats` commit `62f949813a`（2026-03-24 提交、2026-03-27 合入，随 6.7.0 发布，
作者 Bernhard Friedreich）：改成枚举 PCI 设备、用 `KSysGuard::gpuName(pciDevice, index)`
（`libksysguard` 的 `processcore/gpu_utils.cpp`，读 `ID_MODEL_FROM_DATABASE` /
`ID_VENDOR_FROM_DATABASE`，都没有才回退 `GPU n`）。

注意：Ubuntu 26.04 仓库和 `kubuntu-ppa/backports` 在 resolute 上都只提供 **6.6.6**，
没有 6.7，所以"升包"这条路走不通；而回移只需要改这一个插件。

## 6. 验证方法（不需要动系统）

构建出插件后，可以用用户命名空间 + 私有会话总线，在不安装的情况下验证插件行为：

```bash
mkdir -p /tmp/ourplugins/ksystemstats /tmp/emptyplug
cp <build>/bin/ksystemstats_plugin_gpu.so /tmp/ourplugins/ksystemstats/
unshare -Ur -m --propagation private sh -c '
  mount --bind /tmp/emptyplug /usr/lib/x86_64-linux-gnu/qt6/plugins/ksystemstats
  export QT_PLUGIN_PATH=/tmp/ourplugins
  exec dbus-run-session -- sh -c "
    /usr/bin/ksystemstats >/tmp/ks.log 2>&1 &
    sleep 3
    python3 tools/show-gpu-sensors.py
  "'
```

打补丁后的实际输出：

```
GPU 传感器数量: 2
  gpu/gpu0   标签=GM107M [GeForce GTX 850M]                            设备名=NVIDIA GeForce GTX 850M
  gpu/gpu1   标签=4th Gen Core Processor Integrated Graphics Controller  设备名=4th Gen Core Processor Integrated Graphics Controller
```

（`mount --bind` 空目录是为了挡住系统自带的旧插件，避免两个 GPU 插件的传感器 id 冲突。）
