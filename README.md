# AndroidTV x86 HDMI 音频修复脚本  
AndroidTV-x86 HDMI Audio Fix Script

本脚本用于修复 x86 架构安卓电视设备的 HDMI 音频问题。  
This script is designed to fix HDMI audio issues on x86 architecture Android TV devices.

---

## 系统要求 / Requirements

- x86 架构的安卓电视  
  Android TV running on x86 architecture
- 你的电脑上需安装 ADB (Android Debug Bridge) 工具  
  ADB (Android Debug Bridge) installed on your PC

---

## 快速指南 / Quick Guide

### 1. 推送脚本文件到设备 / Push the script to your device
将 `hdmi_audio_test.sh` 文件传输到设备：  
Transfer the `hdmi_audio_test.sh` file to your device:

```bash
adb push hdmi_audio_test.sh /data/local/tmp/
adb push sample.wav /data/local/tmp/

adb shell "sed -i 's/\r$//' /data/local/tmp/hdmi_audio_test.sh"

adb shell "chmod +x /data/local/tmp/hdmi_audio_test.sh"

adb shell "/data/local/tmp/hdmi_audio_test.sh"

adb reboot
