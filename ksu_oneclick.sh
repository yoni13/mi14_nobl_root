#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE_TMP="/data/local/tmp"
KSUD="/data/adb/ksu/bin/ksud"

KO="$SCRIPT_DIR/android14-6.1_kernelsu.ko"
PATCHED="$SCRIPT_DIR/kernelsu_patched.ko"
KSUD_BIN="$SCRIPT_DIR/ksud-aarch64-linux-android"
PATCHER="$SCRIPT_DIR/patch_ksu_module.py"
KALLSYMS="$SCRIPT_DIR/kallsyms.txt"

log() { echo "[*] $1"; }
err() { echo "[!] $1"; }

svc_run() {
    local script="$1" logfile="$2" timeout="$3"
    adb shell "/system/bin/service call miui.mqsas.IMQSNative 21 \
        i32 1 s16 'sh' i32 1 \
        s16 '$script' \
        s16 '$logfile' i32 $timeout"
}

svc_rm() {
    adb shell "/system/bin/service call miui.mqsas.IMQSNative 21 \
        i32 1 s16 'rm' i32 1 \
        s16 '-f $1' \
        s16 '/dev/null' i32 5" >/dev/null 2>&1 || true
    sleep 1
}

wait_for_file() {
    local path="$1" max_secs="$2"
    for i in $(seq 1 "$max_secs"); do
        adb shell "[ -f '$path' ]" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

echo "═══════════════════════════════════════════════"
echo "  KernelSU 一键加载 v2"
echo "  每次开机后运行此脚本"
echo "═══════════════════════════════════════════════"
echo

log "rebooting to bootloader for selinux=permissive injection..."
adb reboot bootloader
until fastboot devices | grep -q fastboot; do sleep 1; done
fastboot oem set-gpu-preemption 0 androidboot.selinux=permissive
fastboot continue
log "waiting for adb..."
adb wait-for-device
log "waiting for android boot..."
until adb shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do sleep 1; done
log "waiting for /data..."
until adb shell '[ -d /data/data ]' 2>/dev/null; do sleep 1; done

log "推送文件到设备..."
adb push "$SCRIPT_DIR/ksu_step1.sh" "$DEVICE_TMP/ksu_step1.sh" >/dev/null
adb push "$SCRIPT_DIR/ksu_step2.sh" "$DEVICE_TMP/ksu_step2.sh" >/dev/null
log "文件已推送"
echo

# ─── Step 1: pull kallsyms ───
log "[1/5] 拉取 kallsyms..."
rm -f "$KALLSYMS" "$PATCHED"
svc_rm "$DEVICE_TMP/kallsyms.txt"

svc_run "$DEVICE_TMP/ksu_step1.sh" "$DEVICE_TMP/ksu_step1.log" 60

log "等待 kallsyms..."
if ! wait_for_file "$DEVICE_TMP/kallsyms.txt" 30; then
    err "kallsyms 未出现"
    exit 1
fi
adb pull "$DEVICE_TMP/kallsyms.txt" "$KALLSYMS" >/dev/null
log "kallsyms 已拉取 ($(wc -l < "$KALLSYMS") 行)"
echo

# ─── Step 2: patch on host ───
log "[2/5] 补丁内核模块..."
python3 "$PATCHER" "$KO" "$KALLSYMS" "$PATCHED" || { err "补丁失败"; exit 1; }
[ -f "$PATCHED" ] || { err "补丁文件未生成"; exit 1; }
log "补丁完成"
echo

# ─── Step 3: insmod via mqsas (before KSU enforces SELinux) ───
log "[3/5] insmod 内核模块..."
adb push "$PATCHED" "$DEVICE_TMP/kernelsu_patched.ko" >/dev/null
svc_rm "$DEVICE_TMP/ksu_result.txt"

svc_run "$DEVICE_TMP/ksu_step2.sh" "$DEVICE_TMP/ksu_result.txt" 30

log "等待 insmod 完成..."
if ! wait_for_file "$DEVICE_TMP/ksu_result.txt" 20; then
    err "step2 超时"
    exit 1
fi

# KSU now enforces SELinux — use su for everything from here
sleep 2
if ! adb shell "su -c 'id'" 2>/dev/null | grep -q "uid=0"; then
    err "KSU su 不可用，insmod 可能失败"
    adb shell "su -c 'cat $DEVICE_TMP/ksu_result.txt'" 2>/dev/null || true
    exit 1
fi
log "KSU root 可用"
echo

# ─── Step 4: deploy ksud + run boot stages via su ───
log "[4/5] 部署 ksud + 执行启动阶段..."

# Update ksud binary if our version differs
adb shell "su -c 'cp $DEVICE_TMP/ksud-aarch64 /data/adb/ksud && chmod 755 /data/adb/ksud'" 2>/dev/null || true
adb push "$KSUD_BIN" "$DEVICE_TMP/ksud-aarch64" >/dev/null

adb shell "su -c '$KSUD post-fs-data </dev/null >/dev/null 2>&1 &'"
sleep 5

# Remove magisk compat symlink to prevent Manager false conflict report
adb shell "su -c 'rm -f /data/adb/ksu/bin/magisk'" 2>/dev/null || true

adb shell "su -c '$KSUD services </dev/null >/dev/null 2>&1 &'"
sleep 5
adb shell "su -c '$KSUD boot-completed </dev/null >/dev/null 2>&1 &'"
sleep 3
log "ksud 启动阶段完成"
echo

# ─── Step 5: trigger Manager recognition ───
log "[5/5] 触发 KernelSU Manager 识别..."
adb install -r "$SCRIPT_DIR/ksu_manager.apk" 2>&1 | tail -2
sleep 3
log "Manager 安装完成"
echo

# ─── LSPosed fix ───
log "运行 fix_lspd.sh..."
adb push "$SCRIPT_DIR/fix_lspd.sh"     "$DEVICE_TMP/fix_lspd.sh"     >/dev/null
adb push "$SCRIPT_DIR/patch_linker.sh" "$DEVICE_TMP/patch_linker.sh" >/dev/null
adb shell "su -c 'sh $DEVICE_TMP/fix_lspd.sh > $DEVICE_TMP/lspd_fix_out.txt 2>&1'" &
LSPD_PID=$!

log "等待 LSPosed 修复 (最多 180s)..."
if wait_for_file "$DEVICE_TMP/lspd_fix_out.txt" 180; then
    wait $LSPD_PID 2>/dev/null || true
    echo
    echo "══════════ LSPosed 修复结果 ══════════"
    adb shell "su -c 'cat $DEVICE_TMP/lspd_fix_out.txt'"
else
    err "fix_lspd.sh 超时"
    kill $LSPD_PID 2>/dev/null || true
fi

echo
echo "═══════════════════════════════════════════════"
echo "  完成！打开 KernelSU Manager 检查状态"
echo "═══════════════════════════════════════════════"
echo
read -r -p "按回车键继续..."
