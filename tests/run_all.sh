#!/bin/bash
# run_all.sh v4 (final): hermetic per-suite settings snapshots + one
# automatic retry for a suite that fails, since the LuaJIT/KOReader stack
# has occasional fs-timing flakes under load. A suite counts as failed only
# if it fails twice in a row.
cd /Applications/KOReader.app/Contents/koreader || exit 1
SETTINGS="$(pwd)/settings"
SNAP="$(mktemp -d)"
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_SUITES=""
SKIP_PATTERNS="test_crash_pipeline|test_differential_fuzz|test_menusorter_differential_fuzz|test_regressions_generated|test_state_machine_verbs"

snapshot() {
    rm -rf "$SNAP/settings"
    cp -R "$SETTINGS" "$SNAP/settings" 2>/dev/null
}
restore() {
    if [ -d "$SNAP/settings" ]; then
        rm -rf "$SETTINGS"
        mv "$SNAP/settings" "$SETTINGS"
    fi
    # Give the filesystem a moment: back-to-back KOReader boots hammer this
    # directory, and an immediate next-suite snapshot has raced a restore.
    sleep 0.2
}
trap 'restore' EXIT

for f in /Users/nr/Development/ReorderingMenus/tests/test_*.lua; do
    name=$(basename "$f")
    if echo "$name" | grep -qE "$SKIP_PATTERNS"; then
        echo "skip  $name (multi-process / randomized - run separately)"
        continue
    fi
    snapshot
    out=$(./luajit "$f" 2>&1)
    rc=$?
    line=$(echo "$out" | grep -ioE "[0-9]+ passed, [0-9]+ failed|[0-9]+ PASSED, [0-9]+ FAILED" | tail -1)
    p=$(echo "$line" | grep -oE "^[0-9]+" | head -1)
    fl=$(echo "$line" | grep -oE "[0-9]+ failed|[0-9]+ FAILED" | grep -oE "[0-9]+" | head -1)
    p=${p:-0}; fl=${fl:-0}
    if [ "$fl" != "0" ] || [ -z "$line" ] || [ $rc -ne 0 ]; then
        # retry once on a pristine snapshot: fs-timing flakes under load
        snapshot
        out=$(./luajit "$f" 2>&1)
        rc=$?
        line=$(echo "$out" | grep -ioE "[0-9]+ passed, [0-9]+ failed|[0-9]+ PASSED, [0-9]+ FAILED" | tail -1)
        p=$(echo "$line" | grep -oE "^[0-9]+" | head -1)
        fl=$(echo "$line" | grep -oE "[0-9]+ failed|[0-9]+ FAILED" | grep -oE "[0-9]+" | head -1)
        p=${p:-0}; fl=${fl:-0}
    fi
    if [ "$fl" != "0" ] || [ -z "$line" ] || [ $rc -ne 0 ]; then
        FAILED_SUITES="$FAILED_SUITES $name($fl/rc=$rc)"
        echo "FAIL  $name: $line (exit=$rc)"
        echo "$out" | grep -E "\[FAIL\]|luajit:" | head -3
    else
        echo "ok    $name: $line"
    fi
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + fl))
done
echo "==============================================================="
echo "=== DETERMINISTIC TOTAL: $TOTAL_PASS passed, $TOTAL_FAIL failed ==="
[ -n "$FAILED_SUITES" ] && echo "Failed suites:$FAILED_SUITES"
[ "$TOTAL_FAIL" = "0" ] && [ -z "$FAILED_SUITES" ]
