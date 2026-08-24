#!/bin/bash
cd /Applications/KOReader.app/Contents/koreader
for i in 1 2 3 4 5; do
  ./luajit /Users/nr/Development/ReorderingMenus/tests/test_generation_precedence.lua > /tmp/nrun$i.txt 2>&1
  echo "run$i: $(grep 'passed' /tmp/nrun$i.txt)"
  grep FAIL /tmp/nrun$i.txt | head -4
done
