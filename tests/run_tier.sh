#!/bin/bash
# run_tier.sh — tier runner for the ReorderingMenus state-machine suites.
#
# Usage: run_tier.sh quick|ci|nightly|soak
#
# Tiers (SM_SEEDS x SM_STEPS for the manager-verb SM; the legacy SM scales
# via SM_SEEDS/SM_STEPS too):
#   quick   :  6 x  60   (~seconds; pre-commit / PR)
#   ci      : 20 x 200   (normal CI)
#   nightly : 100 x 500
#   soak    : 500 x 1000
#
# Every failing seed is auto-shrunk and promoted to
# tests/fixtures/regression/, replayed forever by
# test_regressions_generated.lua.

set -u
KOREADER="/Applications/KOReader.app/Contents/koreader"
PROJECT="/Users/nr/Development/ReorderingMenus"

TIER="${1:-quick}"
case "$TIER" in
    quick)   SEEDS=6;   STEPS=60   ;;
    ci)      SEEDS=20;  STEPS=200  ;;
    nightly) SEEDS=100; STEPS=500  ;;
    soak)    SEEDS=500; STEPS=1000 ;;
    *) echo "unknown tier: $TIER (use quick|ci|nightly|soak)" >&2; exit 2 ;;
esac

export SM_SEEDS="$SEEDS" SM_STEPS="$STEPS"

echo "=== ReorderingMenus tier: $TIER (SM_SEEDS=$SEEDS SM_STEPS=$STEPS) ==="

FAILED_SUITES=0
run_suite() {
    local name="$1" path="$2"
    local start end
    start=$(date +%s)
    (cd "$KOREADER" && ./luajit "$path" > /tmp/rm_suite_out.txt 2>&1)
    local rc=$?
    end=$(date +%s)
    local summary
    summary=$(grep -E "passed," /tmp/rm_suite_out.txt | tail -1)
    echo "[$name] ${summary:-CRASH (exit $rc)}  ($((end - start))s)"
    if [ "$rc" -ne 0 ] || echo "$summary" | grep -qv "0 failed"; then
        FAILED_SUITES=$((FAILED_SUITES + 1))
        grep -E "FAIL" /tmp/rm_suite_out.txt | head -5
    fi
}

run_suite "manager-verb SM " "$PROJECT/tests/test_state_machine_verbs.lua"
run_suite "legacy SM       " "$PROJECT/tests/test_state_machine.lua"

if [ "$FAILED_SUITES" -eq 0 ]; then
    echo "=== $TIER: ALL GREEN ==="
else
    echo "=== $TIER: $FAILED_SUITES suite(s) failing; fixtures promoted for new failures ==="
fi
exit "$FAILED_SUITES"
