AndroidTV-x86 HDMI Audio Fix Script
This script is designed to fix HDMI audio issues on x86 architecture Android TV devices.

安卓电视 x86 HDMI 音频修复脚本
本脚本用于修复 x86 架构安卓电视设备的 HDMI 音频问题。

Requirements / 系统要求
Android TV running x86 architecture.

x86 架构的安卓电视。

ADB (Android Debug Bridge) installed on your PC.

你的电脑上需安装 ADB (Android Debug Bridge)。

Quick Guide / 快速指南
1. Push the script to your device / 推送脚本文件到设备
Use this command to transfer the hdmi_audio_test.sh file.
使用此命令传输 hdmi_audio_test.sh 文件。


adb push hdmi_audio_test.sh /data/local/tmp/
2. Remove Windows line endings (if any) / 去掉 Windows 换行符（如有）
This step is crucial if the script was downloaded on a Windows machine.
如果脚本是在 Windows 机器上下载的，此步骤至关重要。

adb shell "sed -i 's/\r$//' /data/local/tmp/hdmi_audio_test.sh"
3. Make the script executable / 赋予脚本执行权限
You need to grant execution permission before running the script.
在运行脚本前，你需要赋予它执行权限。


adb shell "chmod +x /data/local/tmp/hdmi_audio_test.sh"
4. Run the script and reboot / 运行脚本并重启
Execute the script and then restart the device to apply the changes.
执行脚本，然后重启设备以应用更改。


adb shell "/data/local/tmp/hdmi_audio_test.sh"
adb reboot

Notes / 注意事项
Backup your system before running the script.

运行脚本前请务必备份你的系统。

This script is for x86 Android TV builds only.

本脚本仅适用于 x86 架构的安卓电视。

Audio quality improvement may vary depending on the device.

问题改善效果可能因设备不同而异。
