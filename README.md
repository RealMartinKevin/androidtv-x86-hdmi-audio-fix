AndroidTV-x86 HDMI Audio Fix Script

## Requirements / 系统要求

- Android TV running x86 architecture / x86 架构的 Android TV
- ADB installed on your PC / PC 上需安装 ADB

---

## Quick Start / 快速开始

1. **Push the script to your device / 将脚本推送到设备**
> You can also use third-party GUI tools for easier operation.
> 你也可以使用开心电视助手等第三方 GUI 工具。

adb push hdmi_audio_test.sh /data/local/tmp/
Remove Windows line endings (if any) / 去掉 Windows 换行符（如有）

adb shell
sed -i 's/\r$//' /data/local/tmp/hdmi_audio_test.sh
Make the script executable / 赋予执行权限

chmod +x /data/local/tmp/hdmi_audio_test.sh
Run the script / 运行脚本

/data/local/tmp/hdmi_audio_test.sh
Reboot the device / 重启设备

reboot
Notes / 注意事项
Make sure to backup your system before running the script / 运行脚本前请备份系统

This script targets x86 Android TV builds / 脚本适用于 x86 架构 Android TV

Audio quality improvement may vary depending on the device / 问题改善效果可能因设备不同而异
