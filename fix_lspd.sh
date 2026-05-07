#!/system/bin/sh
# Fix NeoZygisk + LSPosed v2 for late KSU module loading
# Root cause: KernelSU loads zygisk_file type but kernel can't map it,
# so NeoZygisk's sepolicy rules are broken. We stay permissive to work around.
ZYGISKDIR="/data/adb/modules/zygisksu"
MODDIR="/data/adb/modules/zygisk_lsposed"
LOGDIR="/data/adb/lspd/log"
KSUD=/data/adb/ksu/bin/ksud

echo "[1] kill stale lspd, ptrace monitor, zygiskd..."
for PID in $(ps -A -o PID,NAME 2>/dev/null | grep -E 'lspd|zygisk-ptrace|zygiskd' | awk '{print $1}'); do
    kill -9 $PID 2>/dev/null && echo "  killed $PID"
done
sleep 1

echo "[1.5] ensure NeoZygisk/LSPosed sepolicy types are loaded..."
_CHK=/data/local/tmp/sepol_chk_$$
touch "$_CHK"
if chcon u:object_r:zygisk_file:s0 "$_CHK" 2>/dev/null; then
    rm -f "$_CHK"
    echo "  zygisk_file type exists in policy"
else
    rm -f "$_CHK"
    echo "  zygisk_file NOT in policy — loading rules..."
    LOADED=0
    for SEPOL in /data/adb/modules/*/sepolicy.rule; do
        [ -f "$SEPOL" ] || continue
        if "$KSUD" sepolicy --apply "$SEPOL" 2>/dev/null; then
            echo "  applied $SEPOL"
            LOADED=$((LOADED + 1))
        fi
    done
    if [ "$LOADED" -eq 0 ]; then
        echo "  ksud sepolicy --apply unavailable; running post-fs-data (sync, max 20s)..."
        timeout 20 "$KSUD" post-fs-data 2>&1 | tail -10
        for PID in $(ps -A -o PID,NAME 2>/dev/null \
                     | grep -E 'lspd|zygisk-ptrace|zygiskd' | awk '{print $1}'); do
            kill -9 $PID 2>/dev/null && echo "  killed ksud-spawned $PID"
        done
        sleep 1
    fi
fi

echo "[2] patch linker config in init mount namespace..."
nsenter -t 1 -m -- sh /data/local/tmp/patch_linker.sh
sleep 1

echo "[3] set permissive mode (zygisk_file type unmapped — enforcing breaks socket comm)..."
setenforce 0 2>/dev/null
echo "  SELinux: $(getenforce 2>/dev/null || echo unknown)"

echo "[4] run post-fs-data.sh (creates libzygisk.so + starts ptrace monitor)..."
sh "$ZYGISKDIR/post-fs-data.sh"
sleep 2
PTRACE_PID=$(ps -A -o PID,NAME 2>/dev/null | grep zygisk-ptrace | awk '{print $1}' | head -1)
echo "  ptrace monitor PID: ${PTRACE_PID:-(not running!)}"
[ -z "$PTRACE_PID" ] && { echo "ERROR: monitor not running"; exit 1; }

echo "[5] record current state..."
ZPID=$(ps -A -o PID,NAME 2>/dev/null | grep 'zygote64$' | awk '{print $1}' | head -1)
OLD_SS=$(ps -A -o PID,NAME 2>/dev/null | grep 'system_server' | awk '{print $1}' | head -1)
BOOTCP=$(cat /proc/$ZPID/environ 2>/dev/null | tr '\0' '\n' | grep '^BOOTCLASSPATH=' | head -1)
echo "  zygote64=$ZPID  old_SS=$OLD_SS"
[ -z "$BOOTCP" ] && { echo "ERROR: no BOOTCLASSPATH"; exit 1; }

echo "[6] clean lspd state..."
rm -f /data/adb/lspd/monitor /data/adb/lspd/lock 2>/dev/null

echo "[7] start LSPosed v2 daemon in init mount namespace..."
setsid nsenter -t 1 -m -- /system/bin/sh -c "
    export $BOOTCP
    export PATH=/system/bin:/vendor/bin:/data/adb/ksu/bin
    cd $MODDIR
    exec $MODDIR/daemon
" </dev/null >/dev/null 2>&1 &
sleep 4
LSPD=$(ps -A -o PID,NAME 2>/dev/null | grep 'lspd' | awk '{print $1}' | head -1)
echo "  lspd PID=${LSPD:-(not visible yet)}"

PTRACE_PID=$(ps -A -o PID,NAME 2>/dev/null | grep zygisk-ptrace | awk '{print $1}' | head -1)
[ -z "$PTRACE_PID" ] && { echo "ERROR: monitor died before zygote kill"; exit 1; }

echo "[8] kill zygote64 (monitor injects into new zygote)..."
kill -9 $ZPID

echo "[9] wait for old system_server to die..."
for i in $(seq 1 15); do
    sleep 1
    kill -0 $OLD_SS 2>/dev/null || { echo "  old SS died (${i}s)"; break; }
done

echo "[10] wait for new system_server..."
NEW_SS=""
for i in $(seq 1 30); do
    sleep 1
    SSPID=$(ps -A -o PID,NAME 2>/dev/null | grep 'system_server' | awk '{print $1}' | head -1)
    if [ -n "$SSPID" ] && [ "$SSPID" != "$OLD_SS" ]; then
        NEW_SS=$SSPID
        echo "  new SS PID=$NEW_SS (${i}s)"
        break
    fi
done
[ -z "$NEW_SS" ] && { echo "ERROR: system_server did not restart"; exit 1; }

ZPID2=$(ps -A -o PID,NAME 2>/dev/null | grep 'zygote64$' | awk '{print $1}' | head -1)
echo "  zygote maps check:"
if grep -q "libzygisk\|neozygisk" /proc/$ZPID2/maps 2>/dev/null; then
    echo "    libzygisk.so LOADED in zygote"
else
    echo "    libzygisk.so NOT in zygote maps — injection failed"
fi
if grep -q "zygisk-module\|lsposed" /proc/$NEW_SS/maps 2>/dev/null; then
    echo "    zygisk-module LOADED in system_server"
else
    echo "    zygisk-module NOT in system_server maps"
fi

echo "[11] wait for LSPosed bridge binder (max 60s)..."
BRIDGE_OK=""
for i in $(seq 1 60); do
    sleep 1
    LATEST=$(ls -t $LOGDIR/verbose_*.log 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        BRIDGE_OK=$(grep -l "binder received" "$LATEST" 2>/dev/null)
        [ -n "$BRIDGE_OK" ] && { echo "  bridge established (${i}s)"; break; }
    fi
    [ $((i % 15)) -eq 0 ] && echo "  still waiting (${i}s)..."
done

echo "[12] force-restart LSPosed Manager for detection..."
am force-stop org.lsposed.manager 2>/dev/null
sleep 2
am start -n org.lsposed.manager/.ui.activity.MainActivity 2>/dev/null
echo "  Manager relaunched"

echo "[13] final status..."
echo "  SELinux:       $(getenforce 2>/dev/null)"
echo "  lspd:          $(ps -A -o PID,NAME 2>/dev/null | grep lspd | awk '{print $1}')"
echo "  zygote64:      $(ps -A -o PID,NAME 2>/dev/null | grep 'zygote64$' | awk '{print $1}')"
echo "  system_server: $(ps -A -o PID,NAME 2>/dev/null | grep system_server | awk '{print $1}')"
echo "  ptrace monitor:$(ps -A -o PID,NAME 2>/dev/null | grep zygisk-ptrace | awk '{print $1}')"
echo "  zygiskd64:     $(ps -A -o PID,NAME 2>/dev/null | grep zygiskd | awk '{print $1}')"
echo "  lspd monitor:  $(cat /data/adb/lspd/monitor 2>/dev/null)"
LATEST=$(ls -t $LOGDIR/verbose_*.log 2>/dev/null | head -1)
if [ -n "$LATEST" ]; then
    echo "  verbose log tail (10):"
    tail -10 "$LATEST" | awk '{print "    "$0}'
fi

[ -n "$BRIDGE_OK" ] && echo "=== SUCCESS ===" || echo "=== bridge not confirmed — check logs ==="
echo "NOTE: SELinux left permissive (zygisk_file type unmapped in kernel policy)"
echo "DONE"
