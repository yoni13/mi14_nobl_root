#!/system/bin/sh
# Patch /linkerconfig/ld.config.txt to allow dlopen from /data/adb/neozygisk/lib64.
# Patches namespace.default, namespace.com_android_art, and namespace.com_android_runtime
# since ART threads in zygote use com_android_art namespace, not namespace.default.
# Run via: nsenter -t 1 -m -- sh /data/local/tmp/patch_linker.sh
LINKER_CFG=/linkerconfig/ld.config.txt
NEOZYGISK_PATH="/data/adb/neozygisk/lib64"

if [ ! -f "$LINKER_CFG" ]; then
    echo "  ERROR: $LINKER_CFG not found"
    exit 1
fi

echo "  === relevant linker config sections ==="
grep -n "^\[system\]\|namespace\.\(default\|com_android_art\|com_android_runtime\)\.permitted\.paths" \
    "$LINKER_CFG" | head -40 | awk '{print "    "$0}'
echo "  ==="

# Remove any existing neozygisk entries from all sections.
if grep -qF "neozygisk" "$LINKER_CFG" 2>/dev/null; then
    TMP=/data/local/tmp/ld_cfg_clean.txt
    grep -vF "neozygisk" "$LINKER_CFG" > "$TMP" && cat "$TMP" > "$LINKER_CFG"
    rm -f "$TMP"
    echo "  removed stale neozygisk entries"
fi

# Insert a permitted.paths line after the first occurrence for a given namespace.
# Re-reads the file each call so line numbers stay correct after prior insertions.
patch_ns() {
    local NS="$1"
    local LINENUM
    LINENUM=$(grep -n "namespace\.${NS}\.permitted\.paths" "$LINKER_CFG" | head -1 | cut -d: -f1)
    if [ -z "$LINENUM" ]; then
        echo "  namespace.${NS}: no permitted.paths line found — skipping"
        return 0
    fi
    TMP=/data/local/tmp/ld_cfg_ns.txt
    head -n "$LINENUM" "$LINKER_CFG" > "$TMP"
    printf 'namespace.%s.permitted.paths += %s\n' "$NS" "$NEOZYGISK_PATH" >> "$TMP"
    tail -n "+$((LINENUM + 1))" "$LINKER_CFG" >> "$TMP"
    cat "$TMP" > "$LINKER_CFG"
    rm -f "$TMP"
    echo "  namespace.${NS}: inserted after line $LINENUM"
}

patch_ns "default"
patch_ns "com_android_art"
patch_ns "com_android_runtime"

echo "  verify: neozygisk appears $(grep -c neozygisk "$LINKER_CFG") time(s)"
grep -n "neozygisk" "$LINKER_CFG" | awk '{print "    "$0}'
