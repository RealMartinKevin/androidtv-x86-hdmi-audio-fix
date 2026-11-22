#!/bin/bash
# ============================================================================
# hdmi_fix_v2.sh 的离线回归测试
#
# 为什么需要它
#   这个脚本的目标环境是 android-x86 设备，日常拿不到机器。
#   但除「alsa_amixer 在真实硬件上的行为」之外，其余逻辑（选卡、设备枚举、
#   ELD 判定、软链接、init.sh 幂等写入）都能在任意 Linux 上验证：
#   把脚本里的绝对路径替换成假文件树，用桩程序替掉 alsa_amixer / alsa_aplay /
#   mount / id，再交给真实的 mksh 跑完整流程。
#
# 用法
#   bash tests/e2e.sh
#   MKSH=/path/to/mksh bash tests/e2e.sh    # 指定解释器
#
# 可选依赖（缺失时自动跳过对应检查，不算失败）
#   - mksh        设备上真正的 /system/bin/sh，强烈建议装
#   - shellcheck  静态检查
#   - dash        额外的 POSIX 严格语法检查
#
# 注意：被测的是「路径替换副本」，生产脚本不会被修改。
# ============================================================================

set -u

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK="${TMPDIR:-/tmp}/atv-hdmi-e2e.$$"
MKSH="${MKSH:-$(command -v mksh 2>/dev/null || true)}"
SHELLCHECK="${SHELLCHECK:-$(command -v shellcheck 2>/dev/null || true)}"
DASH="${DASH:-$(command -v dash 2>/dev/null || true)}"

PASS=0
FAIL=0
SKIP=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
sk()   { SKIP=$((SKIP+1)); printf '  [SKIP] %s\n' "$1"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1（期望 '$3'，实际 '$2'）"; fi; }

for f in hdmi_fix_v2.sh hdmi_fix_restore.sh; do
    [ -f "$REPO/$f" ] || { echo "找不到 $REPO/$f"; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/scripts"
trap 'rm -rf "$WORK"' EXIT

cp "$REPO/hdmi_fix_v2.sh"              "$WORK/scripts/main.sh"
cp "$REPO/hdmi_fix_restore.sh"         "$WORK/scripts/restore.sh"
cp "$REPO/fix"                         "$WORK/scripts/wrap_fix.sh"
cp "$REPO/hdmi_audio_test.sh(chs_eng)" "$WORK/scripts/wrap_chs_eng.sh"

echo "REPO = $REPO"
echo "mksh = ${MKSH:-（无）}"
echo ""

# ---------------------------------------------------------------- 假文件树
build_fake() {
    F="$WORK/fake$1"
    rm -rf "$F"
    mkdir -p "$F/proc/asound/card0" "$F/dev/snd" "$F/tmp" "$F/bin"

    cat > "$F/proc/asound/cards" <<'EOC'
 0 [PCH            ]: HDA-Intel - HDA Intel PCH
                      HDA Intel PCH at 0xdff20000 irq 128
EOC
    echo "PCH" > "$F/proc/asound/card0/id"
    printf 'monitor_present\t\t1\neld_valid\t\t1\nmonitor_name\t\tSAM-S27R75\nconnection_type\t\tHDMI\n' \
        > "$F/proc/asound/card0/eld#0.0"

    for d in 0 3 7 8; do mkdir -p "$F/proc/asound/card0/pcm${d}p"; done
    echo "id: ALC269 Analog" > "$F/proc/asound/card0/pcm0p/info"
    echo "id: HDMI 0"        > "$F/proc/asound/card0/pcm3p/info"
    echo "id: HDMI 1"        > "$F/proc/asound/card0/pcm7p/info"
    echo "id: HDMI 2"        > "$F/proc/asound/card0/pcm8p/info"

    for d in 0 3 7 8; do : > "$F/dev/snd/pcmC0D${d}p"; done
    : > "$F/tmp/sample.wav"

    printf '#!/system/bin/sh\n# android-x86 自带的 init.sh 内容\nmount -t tmpfs none /mnt\n' > "$F/init.sh"

    # 桩：只承认 IEC958,0..2 存在，用来验证「计数」而不是「静默成功」
    cat > "$F/bin/alsa_amixer" <<'EOS'
#!/bin/sh
case "$3" in
    IEC958,0|IEC958,1|IEC958,2) exit 0 ;;
    *) exit 1 ;;
esac
EOS
    printf '#!/bin/sh\nexit 0\n'          > "$F/bin/alsa_aplay"
    printf '#!/bin/sh\nexit 0\n'          > "$F/bin/mount"
    printf '#!/bin/sh\necho 0\n'          > "$F/bin/id"
    printf '#!/bin/sh\nexit 0\n'          > "$F/bin/sleep"
    printf '#!/bin/sh\necho Permissive\n' > "$F/bin/getenforce"
    chmod +x "$F/bin"/*
    echo "$F"
}

# 生成路径替换后的副本；有 mksh 时把 shebang 指向它，确保用真解释器解析
make_copy() {
    F="$1"; SRC="$2"; DST="$3"
    sed -e "s#/proc/asound#$F/proc/asound#g" \
        -e "s#/dev/snd#$F/dev/snd#g" \
        -e "s#/data/local/tmp#$F/tmp#g" \
        -e "s#/system/etc/init.sh#$F/init.sh#g" \
        "$SRC" > "$DST"
    if [ -n "$MKSH" ]; then
        sed -i "1s#.*#\#!$MKSH#" "$DST"
    fi
}

run_it() {
    F="$1"; shift
    PATH="$F/bin:$PATH" "$@" 2>&1
}

SH="${MKSH:-sh}"

# ---------------------------------------------------------------- 静态检查
echo "=========== 静态检查 ==========="
for f in main restore wrap_fix wrap_chs_eng; do
    if [ -n "$DASH" ] && "$DASH" -n "$WORK/scripts/$f.sh" 2>"$WORK/n.err"; then
        ok "dash -n $f.sh"
    elif [ -n "$DASH" ]; then
        no "dash -n $f.sh"; sed 's/^/        /' "$WORK/n.err"
    else
        sk "dash -n $f.sh（未安装 dash）"
    fi
done

if [ -n "$MKSH" ]; then
    for f in main restore wrap_fix wrap_chs_eng; do
        if "$MKSH" -n "$WORK/scripts/$f.sh" 2>"$WORK/n.err"; then
            ok "mksh -n $f.sh"
        else
            no "mksh -n $f.sh"; sed 's/^/        /' "$WORK/n.err"
        fi
    done
else
    sk "mksh -n（未安装 mksh，装了才能验设备上的真解释器）"
fi

if [ -n "$SHELLCHECK" ]; then
    c=$("$SHELLCHECK" -s sh -S warning -f gcc "$WORK/scripts/main.sh" 2>&1 | wc -l)
    chk "shellcheck main.sh 警告数" "$c" "0"
    c=$("$SHELLCHECK" -s sh -S warning -f gcc "$WORK/scripts/restore.sh" 2>&1 | wc -l)
    chk "shellcheck restore.sh 警告数" "$c" "0"
else
    sk "shellcheck（未安装）"
fi

# ---------------------------------------------------------------- 场景 A
echo ""
echo "=========== 场景 A：首次安装，选 device 7，接管主输出 ==========="
F=$(build_fake A)
make_copy "$F" "$REPO/hdmi_fix_v2.sh" "$WORK/a.sh"
printf '1\n7\ny\n' | run_it "$F" "$SH" "$WORK/a.sh" > "$WORK/a.log" 2>&1
grep -q '已打开 3 个 IEC958' "$WORK/a.log" && ok "IEC958 只统计真实存在的 control" || no "IEC958 计数"
chk "探测声卡"   "$(sed -n 's/.*探测到 HDMI 声卡: //p' "$WORK/a.log")" "0"
chk "配置写入"   "$(tr '\n' ' ' < "$F/tmp/hdmi_audio.conf" 2>/dev/null)" "CARD=0 DEV=7 HIJACK_PRIMARY=1 "
chk "C0D3 软链接" "$(readlink "$F/dev/snd/pcmC0D3p" 2>/dev/null)" "$F/dev/snd/pcmC0D7p"
chk "C0D0 软链接" "$(readlink "$F/dev/snd/pcmC0D0p" 2>/dev/null)" "$F/dev/snd/pcmC0D7p"
chk "原 C0D0 已备份" "$([ -f "$F/dev/snd/pcmC0D0p.bak" ] && echo yes)" "yes"
grep -q 'HDMI_FIX_START' "$F/init.sh" && ok "init.sh 已写入片段" || no "init.sh 未写入"
chk "init.sh 中 _DEV" "$(grep -c '^_DEV=7$' "$F/init.sh")" "1"
chk "init.sh 不含 setenforce" "$(grep -c setenforce "$F/init.sh")" "0"
chk "init.sh 保留原有内容" "$(grep -c 'android-x86 自带的' "$F/init.sh")" "1"
sed -n '/HDMI_FIX_START/,/HDMI_FIX_END/p' "$F/init.sh" > "$WORK/blk.sh"
if "$SH" -n "$WORK/blk.sh" 2>"$WORK/b.err"; then ok "生成的 init 片段语法正确"
else no "生成的 init 片段语法错误"; sed 's/^/        /' "$WORK/b.err"; fi

# ---------------------------------------------------------------- 场景 B
echo ""
echo "=========== 场景 B：重复安装，确认幂等 ==========="
bak_before=$(ls "$F/dev/snd"/*.bak 2>/dev/null | wc -l)
printf '1\n7\ny\ny\n' | run_it "$F" "$SH" "$WORK/a.sh" > "$WORK/b.log" 2>&1
chk "START 标签数量" "$(grep -c 'HDMI_FIX_START ---' "$F/init.sh")" "1"
chk "END 标签数量"   "$(grep -c 'HDMI_FIX_END ---' "$F/init.sh")" "1"
chk "软链接未嵌套"   "$(readlink "$F/dev/snd/pcmC0D3p")" "$F/dev/snd/pcmC0D7p"
chk "init.sh 原内容未重复" "$(grep -c 'android-x86 自带的' "$F/init.sh")" "1"
chk "重复安装不新增 .bak" "$(( $(ls "$F/dev/snd"/*.bak 2>/dev/null | wc -l) - bak_before ))" "0"
chk "软链接解析后仍指向 D7" "$(readlink -f "$F/dev/snd/pcmC0D3p")" "$(readlink -f "$F/dev/snd/pcmC0D7p")"

# ---------------------------------------------------------------- 场景 C
echo ""
echo "=========== 场景 C：--apply（热插拔后补救） ==========="
rm -f "$F/dev/snd/pcmC0D3p" "$F/dev/snd/pcmC0D0p"
before=$(grep -c 'HDMI_FIX_START ---' "$F/init.sh")
run_it "$F" "$SH" "$WORK/a.sh" --apply > "$WORK/c.log" 2>&1
chk "C0D3 重新建立"     "$(readlink "$F/dev/snd/pcmC0D3p" 2>/dev/null)" "$F/dev/snd/pcmC0D7p"
chk "--apply 不改 init.sh" "$(grep -c 'HDMI_FIX_START ---' "$F/init.sh")" "$before"

# ---------------------------------------------------------------- 场景 D
echo ""
echo "=========== 场景 D：--status 只诊断 ==========="
run_it "$F" "$SH" "$WORK/a.sh" --status > "$WORK/d.log" 2>&1
chk "--status 退出码" "$?" "0"
for sec in "声卡列表" "ELD 状态" "PCM 播放节点" "IEC958" "SELinux"; do
    grep -q "$sec" "$WORK/d.log" && ok "--status 含「$sec」" || no "--status 缺「$sec」"
done
grep -q 'SAM-S27R75' "$WORK/d.log" && ok "--status 读到 ELD 显示器名" || no "--status 未读到 ELD 名"

# ---------------------------------------------------------------- 场景 E
echo ""
echo "=========== 场景 E：ELD 无效时不劫持 C0D0 ==========="
F=$(build_fake E)
make_copy "$F" "$REPO/hdmi_fix_v2.sh" "$WORK/e.sh"
printf 'monitor_present\t\t0\neld_valid\t\t0\n' > "$F/proc/asound/card0/eld#0.0"
printf '1\n7\ny\n' | run_it "$F" "$SH" "$WORK/e.sh" > "$WORK/e.log" 2>&1
chk "C0D3 仍建立"   "$(readlink "$F/dev/snd/pcmC0D3p" 2>/dev/null)" "$F/dev/snd/pcmC0D7p"
chk "C0D0 未被劫持" "$([ -L "$F/dev/snd/pcmC0D0p" ] && echo hijacked || echo untouched)" "untouched"
grep -q '跳过主输出槽位' "$WORK/e.log" && ok "有跳过提示" || no "无跳过提示"

# ---------------------------------------------------------------- 场景 F
echo ""
echo "=========== 场景 F：双声卡，HDMI 在 card1（旧版会选错卡） ==========="
F="$WORK/fakeF"; rm -rf "$F"
mkdir -p "$F/proc/asound/card0" "$F/proc/asound/card1" "$F/dev/snd" "$F/tmp" "$F/bin"
cat > "$F/proc/asound/cards" <<'EOC'
 0 [PCH            ]: HDA-Intel - HDA Intel PCH
                      HDA Intel PCH at 0xdff20000 irq 128
 1 [HDMI           ]: HDA-Intel - HDA ATI HDMI
                      HDA ATI HDMI at 0xdff60000 irq 129
EOC
echo "PCH"  > "$F/proc/asound/card0/id"
echo "HDMI" > "$F/proc/asound/card1/id"
printf 'monitor_present\t\t1\neld_valid\t\t1\n' > "$F/proc/asound/card1/eld#3.0"
mkdir -p "$F/proc/asound/card0/pcm0p" "$F/proc/asound/card1/pcm3p" "$F/proc/asound/card1/pcm7p"
echo "id: ALC269 Analog" > "$F/proc/asound/card0/pcm0p/info"
echo "id: HDMI 0"        > "$F/proc/asound/card1/pcm3p/info"
echo "id: HDMI 1"        > "$F/proc/asound/card1/pcm7p/info"
: > "$F/dev/snd/pcmC0D0p"
: > "$F/dev/snd/pcmC1D3p"
: > "$F/dev/snd/pcmC1D7p"
: > "$F/tmp/sample.wav"
printf '#!/system/bin/sh\n# init\n' > "$F/init.sh"
for s in alsa_aplay mount sleep; do printf '#!/bin/sh\nexit 0\n' > "$F/bin/$s"; done
printf '#!/bin/sh\nexit 0\n'          > "$F/bin/alsa_amixer"
printf '#!/bin/sh\necho 0\n'          > "$F/bin/id"
printf '#!/bin/sh\necho Permissive\n' > "$F/bin/getenforce"
chmod +x "$F/bin"/*
make_copy "$F" "$REPO/hdmi_fix_v2.sh" "$WORK/f.sh"
printf '1\n7\ny\n' | run_it "$F" "$SH" "$WORK/f.sh" > "$WORK/f.log" 2>&1
chk "选中 card1 而非 card0"  "$(sed -n 's/.*探测到 HDMI 声卡: //p' "$WORK/f.log")" "1"
chk "C0D3 指向 card1 的 D7"  "$(readlink "$F/dev/snd/pcmC0D3p" 2>/dev/null)" "$F/dev/snd/pcmC1D7p"
chk "C0D0 按用户确认接管"    "$([ -L "$F/dev/snd/pcmC0D0p" ] && echo hijacked || echo untouched)" "hijacked"

# ---------------------------------------------------------------- 场景 G
echo ""
echo "=========== 场景 G：撤销脚本 ==========="
F=$(build_fake G)
make_copy "$F" "$REPO/hdmi_fix_v2.sh"      "$WORK/g.sh"
make_copy "$F" "$REPO/hdmi_fix_restore.sh" "$WORK/g_restore.sh"
printf '1\n7\ny\n' | run_it "$F" "$SH" "$WORK/g.sh" > /dev/null 2>&1
run_it "$F" "$SH" "$WORK/g_restore.sh" > "$WORK/g.log" 2>&1
chk "片段已删除" "$(grep -c 'HDMI_FIX_START' "$F/init.sh")" "0"
chk "原内容保留" "$(grep -c 'android-x86 自带的' "$F/init.sh")" "1"
chk "配置已删"   "$([ -f "$F/tmp/hdmi_audio.conf" ] && echo exists || echo gone)" "gone"

# ---------------------------------------------------------------- 汇总
echo ""
echo "================================"
printf '通过 %d  失败 %d  跳过 %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
