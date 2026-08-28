#!/bin/bash
# S1b: hostile data-loader payloads, one watchdog-killed process per case.
# Complements tests/test_storage_safety.lua (which runs the fast rejects
# in-process): these cases would HANG the whole suite if a regression
# reintroduced them, so each runs in its own killable process.
#
# Usage: bash tests/run_storage_safety_hostile.sh [KOREADER_DIR]
set -u
KOREADER_DIR="${1:-/Applications/KOReader.app/Contents/koreader}"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KOREADER_DIR" || exit 2

pass=0; fail=0
run_case() {
    local case_name="$1"
    ./luajit "$PLUGIN_DIR/tests/lib/storage_safety_hostile.lua" "$case_name" \
        > "/tmp/rm_hostile_$case_name.out" 2>&1 &
    local pid=$!
    ( sleep 8; kill -9 "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid"; local status=$?
    kill "$watchdog" 2>/dev/null
    if grep -q '^RESULT OK' "/tmp/rm_hostile_$case_name.out"; then
        echo "ok   $case_name ($(grep -a '^RESULT' /tmp/rm_hostile_$case_name.out | head -1))"
        pass=$((pass + 1))
    else
        echo "FAIL $case_name (exit=$status, no RESULT OK line)"
        fail=$((fail + 1))
    fi
}

for c in infinite tailcall huge hugefn oversize; do
    run_case "$c"
done

echo "=== hostile: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
