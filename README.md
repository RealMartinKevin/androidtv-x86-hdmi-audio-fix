# Android-x86 HDMI 音频修复脚本

修复 x86 架构 Android 设备（android-x86 / Bliss OS / Prime OS 等）的 HDMI 无声问题。

> 注意仓库名里的 “AndroidTV” 有误导性：本脚本针对的是**在 PC / 迷你主机上安装的 x86 版 Android**，
> 不是市面上的 ARM 电视盒子 / 电视棒。判断方法见下方「适用范围」。

---

## 先确认适用范围

脚本依赖 `alsa_amixer` / `alsa_aplay` 这两个命令（android-x86 编译 alsa-utils 时加的前缀）。
在设备上执行：

```sh
command -v alsa_amixer alsa_aplay
```

- **都有输出** → 是 android-x86 系，可以用本脚本。
- **两个都没有** → 是 ARM 盒子（用的是 tinyalsa 的 `tinymix` / `tinyplay`），本脚本不适用，
  跑起来会直接报错退出。

其它前提：

- 设备已 root（`adb root` 后 `id -u` 返回 0）。
- `/system`（或 system-as-root 的 `/`）能被 `mount -o remount,rw` 挂成可写。
  从 ISO 或只读 `system.img` 启动的live 环境无法写入，脚本会明确报错。

---

## 它修的到底是什么问题

HDMI 无声常见两种根因，本脚本分别对应处理：

**根因 A：audio HAL 打开的设备和实际 HDMI PCM 节点不一致。**
Intel / AMD 的 HDA 控制器上，不同 HDMI pin 各有一个 PCM 设备，真实能出声的往往是
`pcmC0D7p` / `D8p` / `D9p` / `D10p`，而 android-x86 的 audio HAL 是编译期写死打开
`card0 dev0` 或 `dev3` 的，打开错了自然没声音。

脚本的做法是把真实节点软链接到 HAL 期望的槽位上：

```sh
ln -sf /dev/snd/pcmC0D7p /dev/snd/pcmC0D3p
```

这招成立的原因是：**ALSA 靠打开节点的 minor 号识别 card / device，与路径名无关**，
所以 `pcmC0D3p` 指向 `pcmC0D7p` 的 inode 时，HAL 拿到的确实是 card0 device7。

**根因 B：HDMI pin 的 IEC958（S/PDIF）输出开关被静音。**
表现为系统里 HDMI 显示已连接、画面正常，就是没有声音。脚本对 `IEC958,0` ~ `IEC958,7`
逐个执行 `alsa_amixer set ... on` 打开数字输出。

绝大多数「画面有、声音无」的情况是根因 B，不需要动 `/dev`。

---

## 快速开始

```bash
adb push hdmi_fix_v2.sh   /data/local/tmp/
adb push hdmi_fix_restore.sh /data/local/tmp/
adb push sample.wav       /data/local/tmp/

# Windows 换行符会导致 /system/bin/sh 报错，先转成 LF
adb shell "sed -i 's/\r$//' /data/local/tmp/hdmi_fix_v2.sh"
adb shell "sed -i 's/\r$//' /data/local/tmp/hdmi_fix_restore.sh"
adb shell "chmod +x /data/local/tmp/hdmi_fix_v2.sh /data/local/tmp/hdmi_fix_restore.sh"

adb root
adb shell "/data/local/tmp/hdmi_fix_v2.sh"
adb reboot
```

交互过程中会逐个播放测试音频（每个 3 秒），记住**哪个设备号响的**，输入它即可。

---

## 三种运行模式

| 命令 | 作用 |
|---|---|
| `sh hdmi_fix_v2.sh` | 交互式安装：探测声卡 → 试听 → 保存配置 → 写入开机脚本 |
| `sh hdmi_fix_v2.sh --status` | **只诊断，不改任何东西**。建议出问题时先跑这个 |
| `sh hdmi_fix_v2.sh --apply` | 按已保存配置立即生效，不写 init.sh。**HDMI 热插拔后跑这个** |

`--status` 会输出：声卡列表、ELD 连接状态、PCM 节点与名称、IEC958 control、
已保存配置、init.sh 里的修复片段、SELinux 状态。

### 建议的排查顺序

1. `sh hdmi_fix_v2.sh --status`，看第 2 节 ELD：
   `monitor_present 1` + `eld_valid 1` 才说明内核确实看到了显示器。如果这里就是 0，
   说明问题在显示链路（线、口、功放）而不是音频路由，本脚本帮不上。
2. 看第 5 节 IEC958，确认哪个 control 是 `[off]`。
3. 再跑安装模式，让它帮你把设备号试出来。

---

## 相对旧版做了什么改动

- **不再执行 `setenforce 0`**。旧版每次开机永久关闭 SELinux，属于无必要的安全降级（android-x86
  默认就是 permissive）。本版不碰 SELinux；如某台机器确实需要，请评估风险后自行添加。
- **接管主输出槽位 `C0D0` 前先检查 ELD**。`C0D0` 通常是板载 / 模拟输出，无条件劫持会把板载
  音频顶掉。现在只有检测到活跃 HDMI 显示器时才接管，且安装时默认不接管（需显式回答 y）。
- **声卡探测去掉了 `HDA` / `Intel` / `AMD` 关键词**。这些词几乎匹配任何 Intel 声卡，多控制器
  机器（card0 = 模拟，card1 = HDMI）上会选错卡。现在优先用 ELD 判定，其次看卡 ID 是否含
  `hdmi` / `displayport`。
- **设备号自动枚举**，不再硬编码 `3 7 8 9 10`，改为从 `/dev/snd/pcmC*D*p` 反查实际存在的设备。
- init.sh 里的片段用 `START` / `END` 标签包围，可整块替换、整块删除，并备份原始文件到
  `${INIT_SCRIPT}.hdmifix.bak`。
- 新增 `hdmi_fix_restore.sh` 撤销脚本。

---

## 撤销

```bash
adb root
adb shell "sh /data/local/tmp/hdmi_fix_restore.sh"
adb reboot
```

只删除标签包围的片段，不动 init.sh 里的其它内容。`/dev` 下的软链接重启后自动消失。
如果之前跑过旧版脚本，撤销后请检查 `grep -n setenforce /system/etc/init.sh` 是否有残留。

---

## 已知限制

- **不支持热插拔自动重应用**。开机时 HDMI 未连接、之后才插上，需要手动执行一次
  `--apply`。要全自动得加一个常驻轮询进程，代价大于收益，暂不提供。
- 固件升级 / 重刷后 `/system` 被还原，修复片段会丢失，需重跑一次。
- 只处理「HDMI 口无声」。Dolby / DTS 直通、采样率协商失败、电视侧 EDID 不支持等
  属于另外的问题域，不在此脚本范围内。
- 修改 `/system` 属于系统级改动。生产 / 非自用设备请不要使用。

---

## 文件说明

| 文件 | 说明 |
|---|---|
| `hdmi_fix_v2.sh` | **主脚本**，v3.0，唯一需要用的那个 |
| `hdmi_fix_restore.sh` | 撤销脚本 |
| `sample.wav` | 测试音频 |
| `tests/e2e.sh` | 离线回归测试，见下节 |
| `fix` | 已弃用，转发到 `hdmi_fix_v2.sh`，仅为兼容旧链接保留 |
| `hdmi_audio_test.sh(chs_eng)` | 已弃用，同上（旧的双语版本） |

---

## 离线回归测试

改动脚本后不必上真机就能验证大部分逻辑：

```bash
bash tests/e2e.sh
```

原理是把脚本里的绝对路径替换成假文件树（假的 `/proc/asound`、`/dev/snd`、
`init.sh`），再用桩程序替换 `alsa_amixer` / `alsa_aplay` / `mount` / `id`，
最后交给**真实的 mksh**（设备上的 `/system/bin/sh`）跑完整流程。

覆盖的场景：

| 场景 | 验证内容 |
|---|---|
| A | 首次安装：选卡、IEC958 计数、配置写入、软链接、init.sh 写入、片段语法 |
| B | 重复安装幂等：标签不重复、软链接不嵌套、不新增 `.bak` |
| C | `--apply` 只重建软链接，不碰 `init.sh` |
| D | `--status` 七个分节完整、能读到 ELD 显示器名 |
| E | ELD 无效时**不**劫持 `C0D0` |
| F | 双声卡场景选中 HDMI 卡（card1）而不是模拟卡（card0） |
| G | 撤销脚本删片段、保留原内容 |

可选依赖：`mksh`（强烈建议，装不到时该组检查会标记 SKIP 并用 `sh` 代替）、
`shellcheck`、`dash`。

**测不到的部分**：`alsa_amixer` 的真实 control 名、`/proc/asound/*/eld#*`
的实际字段、以及驱动层面的时序——这些只有真机能验。

---

## English

Fix HDMI audio on x86 Android (android-x86 / Bliss OS / Prime OS), **not** ARM TV boxes —
the scripts require `alsa_amixer` / `alsa_aplay`, which only android-x86 ships
(ARM boxes use tinyalsa: `tinymix` / `tinyplay`).

Two root causes are handled: (A) the audio HAL opens a hardcoded `card0 dev0/dev3` while the
real HDMI PCM node is `pcmC0D7p`/`D8p`/`D9p`/`D10p` — fixed with a symlink, valid because ALSA
identifies devices by inode minor, not path; (B) the HDMI pin's IEC958 switch is muted — fixed
with `alsa_amixer set 'IEC958',N on`.

Modes: no args = interactive install, `--status` = diagnose only, `--apply` = reapply saved
config (use after hot-plugging HDMI). Unlike older versions, this does **not** run
`setenforce 0`, and only hijacks the primary output `C0D0` when an active HDMI display is
detected via ELD.

`tests/e2e.sh` runs an offline regression suite: it rewrites the script's absolute paths
into a fake filesystem tree, stubs out `alsa_amixer` / `alsa_aplay` / `mount` / `id`, and
executes the full flow under real `mksh`. 45 assertions covering card selection, device
enumeration, ELD gating, symlink idempotency and init.sh rewriting.

License: Apache-2.0
