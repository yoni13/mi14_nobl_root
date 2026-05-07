#!/system/bin/sh
# Step 2: insmod only — ksud boot stages run from host via su after this
echo "=== 加载内核模块 ==="
if grep -q "kernelsu" /proc/modules 2>/dev/null; then
    echo "已加载，跳过"
    echo "ALREADY_LOADED"
else
    chmod 644 /data/local/tmp/kernelsu_patched.ko 2>/dev/null
    insmod /data/local/tmp/kernelsu_patched.ko
    RET=$?
    echo "insmod 返回码: $RET"
    if [ $RET -ne 0 ]; then
        echo "LOAD_FAILED"
        dmesg | grep -i "kernelsu\|Unknown symbol" | tail -10
        exit 1
    fi
fi
echo ""
echo "=== 最近 KernelSU 日志 ==="
dmesg | grep -i "KernelSU" | tail -5
echo ""
echo "INSMOD_DONE"
