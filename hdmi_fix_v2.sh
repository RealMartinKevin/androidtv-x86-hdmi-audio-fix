#!/system/bin/sh
# ============================================================================
# Android-x86 HDMI 声音修复脚本  v3.0
# 作者: Martin Kevin  https://space.bilibili.com/375774434
# 许可: Apache-2.0
#
# 适用平台
#   android-x86 / Bliss OS / Prime OS 等「在 PC / 迷你主机上装 Android」的系统。
#   判断依据：系统里存在 alsa_amixer / alsa_aplay（android-x86 编译 alsa-utils
#   时加的前缀）。ARM 电视盒子用的是 tinyalsa（tinymix / tinyplay），本脚本
#   不适用，会直接报错退出。
#
# 用法
#   sh /data/local/tmp/hdmi_fix_v2.sh            交互式安装（推荐首次使用）
#   sh /data/local/tmp/hdmi_fix_v2.sh --apply    不交互，按已保存配置立即生效
#                                                （热插拔 HDMI 后重新执行这个）
#   sh /data/local/tmp/hdmi_fix_v2.sh --status    只诊断，不改动任何东西
#
# 相对旧版的关键改动
#   1. 不再自动执行 setenforce 0（永久关闭 SELinux 属于安全降级，无必要）
#   2. 接管主输出槽位 C0D0 前先检查 ELD，HDMI 没接显示器就不动它，
#      避免把板载 / 模拟输出顶掉
#   3. 声卡探测不再用 HDA|Intel|AMD 这类会误中模拟声卡的关键词，
#      改为优先看 ELD，其次看卡 ID 里是否含 HDMI / DisplayPort
#   4. init.sh 中的修复片段可整块替换、可整块删除，并保留原始备份
# ============================================================================

SAMPLE="/data/local/tmp/sample.wav"
CONF="/data/local/tmp/hdmi_audio.conf"
INIT_SCRIPT="/system/etc/init.sh"
DEBUG_LOG="/data/local/tmp/hdmi_debug.log"
TAG_START="# --- HDMI_FIX_START ---"
TAG_END="# --- HDMI_FIX_END ---"

# ---------------------------------------------------------------------------
# 基础工具
# ---------------------------------------------------------------------------

die() {
    echo "错误: $*" >&2
    exit 1
}

need_root() {
    [ "$(id -u 2>/dev/null)" = "0" ] || die "需要 root 权限，当前 uid=$(id -u 2>/dev/null)。请先 adb root。"
}

need_tools() {
    command -v alsa_amixer >/dev/null 2>&1 || \
        die "找不到 alsa_amixer。这大概率不是 android-x86 设备（ARM 盒子是 tinyalsa，无此命令）。"
    command -v alsa_aplay >/dev/null 2>&1 || \
        die "找不到 alsa_aplay，无法试听测试音频。"
}

remount_rw() {
    # Android 8 之前 /system 独立挂载；9+ 是 system-as-root，需要挂根分区
    mount -o remount,rw /system 2>/dev/null && return 0
    mount -o remount,rw / 2>/dev/null && return 0
    return 1
}

remount_ro() {
    mount -o remount,ro /system 2>/dev/null
    mount -o remount,ro / 2>/dev/null
    return 0
}

# ---------------------------------------------------------------------------
# 探测
# ---------------------------------------------------------------------------

# 当前是否有 HDMI 显示器处于活动连接状态。
# 判据：任一 eld 文件同时满足 monitor_present=1 与 eld_valid=1。
# 这是区分「真的接了 HDMI」和「什么都没接」最可靠的内核侧信号。
eld_active() {
    for _f in /proc/asound/card*/eld#*; do
        [ -f "$_f" ] || continue
        grep -q 'monitor_present[[:space:]]*1' "$_f" 2>/dev/null || continue
        grep -q 'eld_valid[[:space:]]*1' "$_f" 2>/dev/null || continue
        return 0
    done
    return 1
}

# 定位 HDMI 声卡号。三级回退：
#   1) ELD 里 monitor_present=1 的卡  —— 最准
#   2) 卡 ID 含 hdmi / displayport / dp-  —— 次准（不含 HDA/Intel，避免误中模拟卡）
#   3) 0  —— 兜底
detect_card() {
    for _d in /proc/asound/card*; do
        [ -d "$_d" ] || continue
        _idx=$(basename "$_d" | sed 's/^card//')
        for _f in "$_d"/eld#*; do
            [ -f "$_f" ] || continue
            if grep -q 'monitor_present[[:space:]]*1' "$_f" 2>/dev/null; then
                echo "$_idx"
                return 0
            fi
        done
    done
    for _f in /proc/asound/card*/id; do
        [ -f "$_f" ] || continue
        if grep -Eqi 'hdmi|displayport|dp-' "$_f" 2>/dev/null; then
            basename "$(dirname "$_f")" | sed 's/^card//'
            return 0
        fi
    done
    echo 0
}

# 列出某块声卡上所有可播放的 PCM 设备号（从设备节点反查，比硬编码可靠）
list_pcm_devs() {
    ls /dev/snd/pcmC"$1"D*p 2>/dev/null \
        | sed -n 's#^.*/pcmC[0-9]*D\([0-9]*\)p$#\1#p' \
        | sort -n | uniq
}

# 取 PCM 设备的名字，便于用户分辨哪个是 HDMI
dev_info() {
    _info="/proc/asound/card$1/pcm$2p/info"
    [ -f "$_info" ] || { echo ""; return 0; }
    sed -n 's/^id: //p' "$_info" 2>/dev/null | head -n1
}

# ---------------------------------------------------------------------------
# 应用修复
# ---------------------------------------------------------------------------

# 打开数字输出开关。失败的 control 直接跳过不刷屏，但会统计成功数量，
# 为 0 时给出明确提示而不是静默「成功」。
unmute_iec958() {
    _card=$1
    _n=0
    for _ch in 0 1 2 3 4 5 6 7; do
        if alsa_amixer -c"$_card" set 'IEC958',"$_ch" on >/dev/null 2>&1; then
            _n=$((_n + 1))
        fi
    done
    echo "  已打开 $_n 个 IEC958 数字输出开关"
    if [ "$_n" -eq 0 ]; then
        echo "  提示: 该声卡没有名为 IEC958 的 control，HDMI 静音可能由别的 control 控制。"
        echo "        请用 --status 查看全部 control，或在设备上执行:"
        echo "        alsa_amixer -c$_card contents | grep -i -A3 'iec958\\|hdmi'"
    fi
}

# 把 src 软链接到 dst。
# 原理: ALSA 靠打开节点的 minor 号识别 card/device，与路径名无关，
#       所以让 pcmC0D3p 指向 pcmC0D7p 的 inode 是有效的。
link_one() {
    _src=$1
    _dst=$2
    if [ -L "$_dst" ]; then
        if [ "$(readlink "$_dst")" = "$_src" ]; then
            echo "  $_dst 已指向 $_src"
            return 0
        fi
        rm -f "$_dst"
    elif [ -e "$_dst" ]; then
        mv "$_dst" "${_dst}.bak" 2>/dev/null || {
            echo "  无法移动 $_dst，跳过"
            return 1
        }
    fi
    ln -sf "$_src" "$_dst" && echo "  $_dst -> $_src"
}

# card dev hijack
link_nodes() {
    _card=$1
    _dev=$2
    _hijack=$3
    _src="/dev/snd/pcmC${_card}D${_dev}p"

    if [ ! -e "$_src" ]; then
        echo "  目标节点 $_src 不存在，设备号可能填错了，跳过软链接"
        return 1
    fi

    # C0D3 是 AudioFlinger 的 HDMI 专用出口，始终对接
    link_one "$_src" /dev/snd/pcmC0D3p

    if [ "$_hijack" = "1" ]; then
        if eld_active; then
            link_one "$_src" /dev/snd/pcmC0D0p
        else
            echo "  跳过主输出槽位 C0D0：当前没有活跃的 HDMI 显示（ELD 无效）"
            echo "        HDMI 插上后重新执行 --apply 即可接管"
        fi
    fi
}

# ---------------------------------------------------------------------------
# init.sh 持久化
# ---------------------------------------------------------------------------

write_init() {
    _card=$1
    _dev=$2
    _hijack=$3

    [ -f "$INIT_SCRIPT" ] || die "找不到 $INIT_SCRIPT，本机开机脚本不在预期位置，无法持久化。"

    remount_rw || die "无法把 /system 或 / 重新挂载为可写。若是从 ISO 或只读 system.img 启动，本方案不适用。"

    [ -f "${INIT_SCRIPT}.hdmifix.bak" ] || cp "$INIT_SCRIPT" "${INIT_SCRIPT}.hdmifix.bak" 2>/dev/null

    if grep -q "$TAG_START" "$INIT_SCRIPT" 2>/dev/null; then
        printf "%s" "  init.sh 里已存在修复片段，是否覆盖？(y/N): "
        read _ow
        case "$_ow" in
            y|Y) ;;
            *) echo "  已跳过写入"; remount_ro; return 1 ;;
        esac
        sed -i "/$TAG_START/,/$TAG_END/d" "$INIT_SCRIPT"
    fi

    cat >> "$INIT_SCRIPT" <<EOF

$TAG_START
# 由 hdmi_fix_v2.sh v3.0 生成，重复运行脚本会整块替换本段
# 手工删除时把 START 到 END 之间的行（含首尾两行）全部去掉即可
_CARD=$_card
_DEV=$_dev
_HIJACK_PRIMARY=$_hijack

_hdmi_eld_ok() {
    for _f in /proc/asound/card*/eld#*; do
        [ -f "\$_f" ] || continue
        grep -q 'monitor_present[[:space:]]*1' "\$_f" 2>/dev/null || continue
        grep -q 'eld_valid[[:space:]]*1' "\$_f" 2>/dev/null || continue
        return 0
    done
    return 1
}

_hdmi_link() {
    if [ -L "\$2" ]; then
        [ "\$(readlink "\$2")" = "\$1" ] && return 0
        rm -f "\$2"
    elif [ -e "\$2" ]; then
        mv "\$2" "\${2}.bak" 2>/dev/null
    fi
    ln -sf "\$1" "\$2"
}

# 打开数字输出开关
for _ch in 0 1 2 3 4 5 6 7; do
    alsa_amixer -c\$_CARD set 'IEC958',\$_ch on >/dev/null 2>&1
done

# 等待 PCM 节点就绪：init.sh 的执行时机有可能早于声卡驱动注册，
# 节点还没出现就做软链接会白做。最多等 5 秒，等不到就放弃（不阻塞开机更久）。
_i=0
while [ ! -e "/dev/snd/pcmC\${_CARD}D\${_DEV}p" ] && [ \$_i -lt 10 ]; do
    sleep 0.5 2>/dev/null || sleep 1
    _i=\$((_i + 1))
done

# HDMI 专用出口槽位，始终对接真实发声节点
[ -e /dev/snd/pcmC\${_CARD}D\${_DEV}p ] && _hdmi_link "/dev/snd/pcmC\${_CARD}D\${_DEV}p" /dev/snd/pcmC0D3p

# 主输出槽位只在 HDMI 真接着显示器时才接管，避免顶掉板载输出
if [ "\$_HIJACK_PRIMARY" = "1" ] && _hdmi_eld_ok; then
    [ -e /dev/snd/pcmC\${_CARD}D\${_DEV}p ] && _hdmi_link "/dev/snd/pcmC\${_CARD}D\${_DEV}p" /dev/snd/pcmC0D0p
fi

# 说明: 本段不修改 SELinux 的强制状态。旧版在这里额外把 SELinux 关成
# Permissive，已移除（android-x86 默认就是 Permissive，那行只有风险没有收益）。
# 若确认某台机器必须关闭，请自行评估风险后添加。
$TAG_END
EOF

    if grep -q "$TAG_START" "$INIT_SCRIPT" 2>/dev/null; then
        echo "  已写入 $INIT_SCRIPT"
    else
        echo "  写入似乎失败了，请检查 /system 是否真的可写"
        remount_ro
        return 1
    fi

    remount_ro
    return 0
}

# ---------------------------------------------------------------------------
# 诊断输出
# ---------------------------------------------------------------------------

dump_status() {
    echo "=== 1. 声卡列表 (/proc/asound/cards) ==="
    cat /proc/asound/cards 2>/dev/null

    echo ""
    echo "=== 2. ELD 状态（判断 HDMI 是否真的接到显示器）==="
    _found=0
    for _f in /proc/asound/card*/eld#*; do
        [ -f "$_f" ] || continue
        _found=1
        echo "--- $_f"
        grep -E 'monitor_present|eld_valid|monitor_name|connection_type' "$_f" 2>/dev/null
    done
    [ "$_found" = "0" ] && echo "  没有 eld 文件：该声卡没有 HDMI/DP 输出，或驱动未导出 ELD"

    echo ""
    echo "=== 3. PCM 播放节点 ==="
    ls -l /dev/snd/pcm* 2>/dev/null

    echo ""
    echo "=== 4. 各 PCM 设备名称 ==="
    for _d in /proc/asound/card*; do
        [ -d "$_d" ] || continue
        _i=$(basename "$_d" | sed 's/^card//')
        for _p in "$_d"/pcm*p; do
            [ -e "$_p" ] || continue
            _n=$(basename "$_p" | sed 's/^pcm\([0-9]*\)p$/\1/')
            echo "  card$_i dev$_n : $(sed -n 's/^id: //p' "$_p"/info 2>/dev/null | head -n1)"
        done
    done

    echo ""
    echo "=== 5. IEC958 相关 control ==="
    for _d in /proc/asound/card*; do
        [ -d "$_d" ] || continue
        _i=$(basename "$_d" | sed 's/^card//')
        echo "--- card$_i"
        alsa_amixer -c"$_i" contents 2>/dev/null | grep -i -A2 'iec958' | head -n 40
    done

    echo ""
    echo "=== 6. 当前保存的配置 ==="
    if [ -f "$CONF" ]; then cat "$CONF"; else echo "  （尚无配置，未运行过安装）"; fi

    echo ""
    echo "=== 7. init.sh 中的修复片段 ==="
    if grep -q "$TAG_START" "$INIT_SCRIPT" 2>/dev/null; then
        sed -n "/$TAG_START/,/$TAG_END/p" "$INIT_SCRIPT"
    else
        echo "  （无，未持久化）"
    fi

    echo ""
    echo "=== 8. SELinux / 运行环境 ==="
    echo "  uid=$(id -u 2>/dev/null)  getenforce=$(getenforce 2>/dev/null || echo n/a)"
    echo "  $(uname -a 2>/dev/null)"
}

write_debug_log() {
    {
        echo "=== HDMI Fix Debug Log ==="
        echo "Date: $(date 2>/dev/null)"
        dump_status
    } > "$DEBUG_LOG" 2>&1
    echo "  诊断日志: $DEBUG_LOG"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

MODE="install"
case "$1" in
    --status) MODE="status" ;;
    --apply)  MODE="apply" ;;
    -h|--help)
        sed -n '3,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")       MODE="install" ;;
    *)        die "未知参数: $1（可用: --status / --apply / --help）" ;;
esac

if [ "$MODE" = "status" ]; then
    dump_status
    exit 0
fi

need_root
need_tools

# --- 已安装配置，立即生效（热插拔 HDMI 后用这个）---
if [ "$MODE" = "apply" ]; then
    [ -f "$CONF" ] || die "没有已保存的配置 $CONF，请先不带参数运行一次安装。"
    # shellcheck source=/dev/null
    . "$CONF"
    if [ -z "$CARD" ] || [ -z "$DEV" ]; then
        die "配置内容不完整: $CONF"
    fi
    echo "=== 按已保存配置立即生效 (CARD=$CARD DEV=$DEV) ==="
    unmute_iec958 "$CARD"
    link_nodes "$CARD" "$DEV" "${HIJACK_PRIMARY:-1}"
    echo "完成。若仍无声，可尝试重启 framework：stop && start（或直接重启）"
    exit 0
fi

# --- 交互式安装 ---
echo "请选择语言 / Choose language  (1-中文, 2-English): "
read LANG_CHOICE

if [ "$LANG_CHOICE" = "2" ]; then
    T_START="=== HDMI Audio Fix (installer) ==="
    T_NO_SAMPLE="Error: test audio file not found: $SAMPLE"
    T_PREPARE="Put a sample.wav into /data/local/tmp/ first."
    T_CARD="Detected HDMI card"
    T_ELD_YES="HDMI display detected (ELD valid)"
    T_ELD_NO="No active HDMI display (ELD invalid) - C0D0 will NOT be hijacked"
    T_TRY="=== Trying each playback PCM device, 3s each ==="
    T_PICK="Device number that produced sound (e.g. 7): "
    T_BAD="Error: not a valid device number."
    T_HIJACK="Also hijack primary output C0D0? Only needed if HDMI is your only display. (y/N): "
    T_SAVED="Config saved: $CONF"
    T_WRITE="=== Writing to $INIT_SCRIPT ==="
    T_DONE="Done. Reboot to take effect."
    T_FAIL="Not written, HDMI audio will work for this boot only."
else
    T_START="=== HDMI 声音修复工具 (安装模式) ==="
    T_NO_SAMPLE="错误: 测试音频文件不存在: $SAMPLE"
    T_PREPARE="请先把 sample.wav 放到 /data/local/tmp/"
    T_CARD="探测到 HDMI 声卡"
    T_ELD_YES="已检测到 HDMI 显示器（ELD 有效）"
    T_ELD_NO="当前没有活跃的 HDMI 显示器（ELD 无效），本次不接管主输出槽位 C0D0"
    T_TRY="=== 逐个试听各播放设备，每个 3 秒 ==="
    T_PICK="请输入刚才有声音的设备号 (例如 7): "
    T_BAD="错误: 设备号不合法。"
    T_HIJACK="是否同时接管主输出槽位 C0D0？（仅当 HDMI 是唯一显示输出时才需要）(y/N): "
    T_SAVED="配置已保存: $CONF"
    T_WRITE="=== 写入 $INIT_SCRIPT ==="
    T_DONE="完成，重启后生效。"
    T_FAIL="未写入成功，本次修复只在当前开机有效。"
fi

echo "$T_START"
echo ""

if [ ! -f "$SAMPLE" ]; then
    echo "$T_NO_SAMPLE"
    echo "$T_PREPARE"
    exit 1
fi

# 1. 定位声卡
CARD=$(detect_card)
echo "$T_CARD: $CARD"
sed -n '1,20p' /proc/asound/cards 2>/dev/null | sed 's/^/    /'
if eld_active; then
    echo "  $T_ELD_YES"
else
    echo "  $T_ELD_NO"
fi
echo ""

# 2. 打开数字开关
unmute_iec958 "$CARD"
echo ""

# 3. 枚举并试听
DEVICES=$(list_pcm_devs "$CARD")
[ -n "$DEVICES" ] || die "card$CARD 上没有任何播放 PCM 设备，探测逻辑或驱动有问题，请用 --status 排查。"

echo "$T_TRY"
for dev in $DEVICES; do
    printf "  [%s] %s\n" "$dev" "$(dev_info "$CARD" "$dev")"
    alsa_aplay -Dplughw:"$CARD","$dev" "$SAMPLE" >/dev/null 2>&1 &
    _pid=$!
    sleep 3
    kill "$_pid" 2>/dev/null
    wait "$_pid" 2>/dev/null
done
echo ""

# 4. 用户选择
printf "%s" "$T_PICK"
read DEV
case "$DEV" in
    ''|*[!0-9]*)
        echo "$T_BAD"
        exit 1
        ;;
esac

if [ ! -e "/dev/snd/pcmC${CARD}D${DEV}p" ]; then
    echo "$T_BAD (card $CARD 上不存在 device $DEV)"
    exit 1
fi

cat > "$CONF" <<EOF
CARD=$CARD
DEV=$DEV
HIJACK_PRIMARY=0
EOF
echo "$T_SAVED"

# 5. 询问是否接管主输出（默认否，只在 HDMI 是唯一显示时才需要）
printf "%s" "$T_HIJACK"
read _hj
case "$_hj" in
    y|Y) HIJACK_PRIMARY=1 ;;
    *)   HIJACK_PRIMARY=0 ;;
esac
sed -i "s/^HIJACK_PRIMARY=.*/HIJACK_PRIMARY=$HIJACK_PRIMARY/" "$CONF" 2>/dev/null

# 6. 立即应用一次
echo ""
link_nodes "$CARD" "$DEV" "$HIJACK_PRIMARY"

# 7. 持久化
echo ""
echo "$T_WRITE"
if write_init "$CARD" "$DEV" "$HIJACK_PRIMARY"; then
    echo "$T_DONE"
else
    echo "$T_FAIL"
fi

write_debug_log
echo ""
echo "撤销方法: sh /data/local/tmp/hdmi_fix_restore.sh"
