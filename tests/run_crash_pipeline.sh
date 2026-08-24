#!/bin/bash
# Crash-pipeline driver: run the crash stage, then the recovery stage, in
# genuinely separate processes (os.exit kills the interpreter mid-pipeline).
cd /Applications/KOReader.app/Contents/koreader || exit 1
CRASH_STAGE=-1 ./luajit /Users/nr/Development/ReorderingMenus/tests/test_crash_pipeline.lua > /tmp/cp_a.out 2>&1
a=$?
CRASH_STAGE=0  ./luajit /Users/nr/Development/ReorderingMenus/tests/test_crash_pipeline.lua > /tmp/cp_b.out 2>&1
b=$?
echo "crash-process exit=$a recovery exit=$b"
grep -E "FAIL|passed|intent_parent" /tmp/cp_b.out
[ $a -eq 42 ] && [ $b -eq 0 ] && echo "CRASH-PIPELINE OK" || echo "CRASH-PIPELINE FAILED"
