#!/system/bin/sh
# ============================================================================
# Android-x86 HDMI 声音修复 —— 撤销脚本
# 配套 hdmi_fix_v2.sh v3.0
#
# 作用
#   1. 删除 /system/etc/init.sh 中被 START/END 标签包围的修复片段
#   2. 删除 /data/local/tmp/hdmi_audio.conf
#   3. 不还原 SELinux（旧版脚本关掉的 SELinux 需要手动处理，见下方提示）
#   4. /dev 下的软链接不需要处理，重启后自动消失
# ============================================================================

INIT_SCRIPT="/system/etc/init.sh"
CONF="/data/local/tmp/hdmi_audio.conf"
TAG_START="# --- HDMI_FIX_START ---"
TAG_END="# --- HDMI_FIX_END ---"

die() { echo "错误: $*" >&2; exit 1; }

[ "$(id -u 2>/dev/null)" = "0" ] || die "需要 root 权限，请先 adb root。"
[ -f "$INIT_SCRIPT" ] || die "找不到 $INIT_SCRIPT"

if ! grep -q "$TAG_START" "$INIT_SCRIPT" 2>/dev/null; then
    echo "init.sh 中没有找到修复片段，无需删除。"
    [ -f "$CONF" ] && rm -f "$CONF" && echo "已删除 $CONF"
    exit 0
fi

mount -o remount,rw /system 2>/dev/null || mount -o remount,rw / 2>/dev/null || \
    die "无法把 /system 或 / 重新挂载为可写"

echo "删除前的片段："
sed -n "/$TAG_START/,/$TAG_END/p" "$INIT_SCRIPT" | sed 's/^/    /'

# 先留一份当前版本的备份，避免误删后无从追溯
cp "$INIT_SCRIPT" "/data/local/tmp/init.sh.before-restore" 2>/dev/null

sed -i "/$TAG_START/,/$TAG_END/d" "$INIT_SCRIPT"

if grep -q "$TAG_START" "$INIT_SCRIPT" 2>/dev/null; then
    echo "删除失败，请手工编辑 $INIT_SCRIPT"
else
    echo "已从 $INIT_SCRIPT 删除修复片段（备份: /data/local/tmp/init.sh.before-restore）"
fi

[ -f "$CONF" ] && rm -f "$CONF" && echo "已删除 $CONF"

mount -o remount,ro /system 2>/dev/null
mount -o remount,ro / 2>/dev/null

echo ""
echo "完成。重启后 /dev 下的软链接会自动消失。"
echo ""
echo "如果你之前跑过 v1/v2 的旧脚本（会写入 setenforce 0），请检查："
echo "    grep -n setenforce $INIT_SCRIPT"
echo "如有残留请手动删除那行，然后重启确认 getenforce 恢复为 Enforcing。"
