#!/system/bin/sh
# Android-x86 HDMI 声音修复脚本 (Martin Kevin https://space.bilibili.com/375774434)

SAMPLE="/data/local/tmp/sample.wav"
CONF="/data/local/tmp/hdmi_audio.conf"
INIT_SCRIPT="/system/etc/init.sh"

echo "=== HDMI 声音修复工具 ==="

# 确认 sample.wav 存在
if [ ! -f "$SAMPLE" ]; then
    echo "错误: 测试音频文件不存在: $SAMPLE"
    echo "请先准备一个 sample.wav 放到 /data/local/tmp/"
    exit 1
fi

# 默认 HDMI 声卡是 0
CARD=0

# 尝试加载上次配置
if [ -f "$CONF" ]; then
    . "$CONF"
    echo "已加载上次配置: CARD=$CARD DEV=$DEV"
    echo "正在播放测试音频..."
    alsa_amixer -c$CARD set 'IEC958',0 on
    alsa_amixer -c$CARD set 'IEC958',1 on
    alsa_amixer -c$CARD set 'IEC958',2 on
    alsa_amixer -c$CARD set 'IEC958',3 on
    alsa_aplay -Dplughw:${CARD},${DEV} "$SAMPLE"
    echo "测试完成"
    exit 0
fi

# 激活 HDMI 通道
for ch in 0 1 2 3; do
    alsa_amixer -c$CARD set 'IEC958',$ch on >/dev/null 2>&1
done

echo ""
echo "=== 遍历测试 HDMI PCM 设备 ==="
DEVICES="3 7 8 9 10"
for dev in $DEVICES; do
    echo ">>> 测试 plughw:${CARD},${dev} ..."
    alsa_aplay -Dplughw:${CARD},${dev} "$SAMPLE" >/dev/null 2>&1
    sleep 2
done

# 用户选择正确的设备号
echo ""
echo -n "请输入刚才有声音的 PCM 设备号 (例如 7): "
read DEV

# 保存配置
cat > "$CONF" <<EOF
CARD=$CARD
DEV=$DEV
EOF

echo "配置已保存到 $CONF"

# 永久修复: 修改 init.sh
echo ""
echo "=== 写入启动脚本 ($INIT_SCRIPT) ==="
mount -o remount,rw /system

# 备份
cp "$INIT_SCRIPT" "$INIT_SCRIPT.bak"

# 检查是否已经写入过
if ! grep -q "HDMI 声音修复" "$INIT_SCRIPT"; then
    cat >> "$INIT_SCRIPT" <<EOF

# HDMI 声音修复 (自动生成)
alsa_amixer -c$CARD set 'IEC958',0 on
alsa_amixer -c$CARD set 'IEC958',1 on
alsa_amixer -c$CARD set 'IEC958',2 on
alsa_amixer -c$CARD set 'IEC958',3 on

# 修复 PCM 软链接
if [ -e /dev/snd/pcmC${CARD}D3p ]; then
    mv /dev/snd/pcmC${CARD}D3p /dev/snd/pcmC${CARD}D3p.original
fi
ln -sf /dev/snd/pcmC${CARD}D${DEV}p /dev/snd/pcmC${CARD}D3p
EOF
    echo "修改完成，重启后 HDMI 声音应自动生效。"
else
    echo "启动脚本已经存在 HDMI 修复配置，跳过写入。"
fi
