#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run_tests.sh - Reordering Menus test runner
#
# Runs every suite against the REAL installed KOReader runtime (its bundled
# luajit + frontend), from KOReader's own directory so setupkoenv.lua and the
# frontend module paths resolve exactly like production.
#
# Usage:
#   ./run_tests.sh              # quick tier  (every suite, default knobs)
#   TIER=nightly ./run_tests.sh # nightly tier (state machines: 100x500)
#   ./run_tests.sh tests/test_menusorter_differential_fuzz.lua
#   SEED=42 ITERATIONS=100 ./run_tests.sh tests/test_menusorter_differential_fuzz.lua
#
# Environment:
#   KOREADER_DIR   override the KOReader installation
#                  (default: /Applications/KOReader.app/Contents/koreader)
#   PLUGIN_DIR     override the plugin repo (default: script's parent dir)
#   TIER           quick | ci | nightly | soak   (default: quick)
#   SEED / ITERATIONS / SM_SEEDS / SM_STEPS   per-suite knobs
#   SM_SEED_LIST   explicit seed list replayed by both state machines
#                  ("7919,15838,..." — overrides the tier's seed count)
#
# P0-A: randomized suites print an EFFECTIVE_CONFIG line; this runner parses
# it and FAILS the whole run if the executed configuration does not match the
# requested one. A requested nightly that silently ran quick is impossible.
# ---------------------------------------------------------------------------

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${PLUGIN_DIR:-$SCRIPT_DIR}"
KOREADER_DIR="${KOREADER_DIR:-/Applications/KOReader.app/Contents/koreader}"

if [ ! -x "$KOREADER_DIR/luajit" ]; then
    echo "ERROR: no luajit at $KOREADER_DIR/luajit" >&2
    echo "Set KOREADER_DIR to a KOReader installation." >&2
    exit 2
fi

TIER="${TIER:-quick}"
case "$TIER" in
    # P5: quick/local-PR is an EXPLICIT 8x80 (not suite-internal defaults),
    # so every machine runs the same PR floor and the banner gate can verify it.
    quick)   export SM_SEEDS="${SM_SEEDS:-8}" SM_STEPS="${SM_STEPS:-80}"
             export ITERATIONS="${ITERATIONS:-300}" DF_SEEDS="${DF_SEEDS:-8}" DF_STEPS="${DF_STEPS:-40}" ;;
    ci)      export SM_SEEDS="${SM_SEEDS:-20}" SM_STEPS="${SM_STEPS:-200}"
             export ITERATIONS="${ITERATIONS:-2000}" DF_SEEDS="${DF_SEEDS:-20}" DF_STEPS="${DF_STEPS:-60}" ;;
    nightly) export SM_SEEDS="${SM_SEEDS:-100}" SM_STEPS="${SM_STEPS:-500}"
             export ITERATIONS="${ITERATIONS:-2000}" DF_SEEDS="${DF_SEEDS:-40}" DF_STEPS="${DF_STEPS:-80}" ;;
    soak)    export SM_SEEDS="${SM_SEEDS:-500}" SM_STEPS="${SM_STEPS:-1000}"
             export ITERATIONS="${ITERATIONS:-20000}" DF_SEEDS="${DF_SEEDS:-100}" DF_STEPS="${DF_STEPS:-120}" ;;
    *) echo "Unknown TIER '$TIER' (quick|ci|nightly|soak)" >&2; exit 2 ;;
esac

# P1/P0-C: on nightly runs, replay every previously-failing promoted fixture's
# seed in addition to fresh random seeds.
SEED_BANK_FILE="$PLUGIN_DIR/tests/fixtures/regression/seed_bank.txt"
if [ "$TIER" != "quick" ] && [ -s "$SEED_BANK_FILE" ]; then
    BANK=$(sort -u "$SEED_BANK_FILE" | paste -sd, -)
    if [ -n "$BANK" ]; then
        export SM_SEED_LIST="${SM_SEED_LIST:+$SM_SEED_LIST,}$BANK"
    fi
fi

cd "$KOREADER_DIR"
export PLUGIN_DIR="$PLUGIN_DIR"

suites=()
if [ $# -gt 0 ]; then
    for a in "$@"; do
        case "$a" in
            /*) suites+=("$a") ;;                      # absolute path: use as-is
            *)  suites+=("$PLUGIN_DIR/$a") ;;          # relative: resolve vs plugin dir
        esac
    done
else
    for f in "$PLUGIN_DIR"/tests/test_*.lua; do suites+=("$f"); done
fi

pass=0 fail=0 failed_list=""
start_ts=$(date +%s)
for f in "${suites[@]}"; do
    name="$(basename "$f")"
    truncated=0
    # ---- Hermetic per-suite state home ---------------------------------
    # DataStorage honors KO_HOME; pointing it at a throwaway directory gives
    # every suite an isolated settings area. Without this, all suites (and
    # any OTHER agent session running suites in parallel) share
    # $KOREADER_DIR/settings: one session's wipe/quarantine deletes another
    # session's canonical intent mid-run, producing phantom corruption
    # warnings, missing-file crashes, and order-dependent failures.
    suite_home="$(mktemp -d "${TMPDIR:-/tmp}/rm_kohome.XXXXXX")"
    mkdir -p "$suite_home/settings"
    export KO_HOME="$suite_home"
    if [ "$name" = "test_crash_pipeline.lua" ]; then
        # Multi-stage suite: stage -1 hard-exits (simulated crash) and the
        # recovery stage must run as a separate process, exactly like a real
        # crash+restart. Running the file bare would always report failure.
        bash "$PLUGIN_DIR/tests/run_crash_pipeline.sh" > "/tmp/rm_test_$name.log" 2>&1
        suite_rc=$?
    elif KO_HOME="$suite_home" ./luajit "$f" > "/tmp/rm_test_$name.log" 2>&1; then
        suite_rc=0
    else
        suite_rc=1
    fi

    # ---- truncated-output guard (BEFORE config checks) ----------------------
    # A log with no final summary line means the run died mid-execution
    # (bootstrap crash, OOM kill). Retry once, then let the checks below judge.
    CONFIG_REQUIRED=" test_state_machine.lua test_state_machine_verbs.lua test_differential_fuzz.lua test_menusorter_differential_fuzz.lua test_gen1_determinism.lua "
    if [[ "$CONFIG_REQUIRED" == *" $name "* ]] \
       && ! grep -qE '([0-9]+ passed, [0-9]+ failed)|([0-9]+ iterations, [0-9]+ failures)|([0-9]+ checks passed, [0-9]+ failed)|(round-trip equivalence)' "/tmp/rm_test_$name.log"; then
        ./luajit "$f" > "/tmp/rm_test_$name.log" 2>&1 || true
        grep -qE '([0-9]+ passed, [0-9]+ failed)|([0-9]+ iterations, [0-9]+ failures)|([0-9]+ checks passed, [0-9]+ failed)|(round-trip equivalence)' "/tmp/rm_test_$name.log" || \
            truncated=1
    fi

    # ---- P0-A: effective-config verification -------------------------------
    # Every randomized/fuzz suite prints EFFECTIVE_CONFIG suite=<file> <k>=<v>.
    # If the suite requested a specific knob value but reports something else,
    # treat the suite as failed regardless of green output. Suites in
    # CONFIG_REQUIRED print NO banner at all -> automatic failure.
    #
    # Knob families are SUITE-SPECIFIC: the state machines consume SM_SEEDS/
    # SM_STEPS, the native-order fuzz consumes DF_SEEDS/DF_STEPS, and the
    # MenuSorter fuzz consumes ITERATIONS. Comparing one family's expectation
    # against another suite's banner made green suites fail by construction
    # (e.g. quick tier: DF_STEPS=40 vs SM_STEPS=80). Only the family a suite
    # actually consumes is checked here.
    cfg_fail=""
    if grep -q '^EFFECTIVE_CONFIG ' "/tmp/rm_test_$name.log"; then
        reported_seeds="$(sed -n 's/^EFFECTIVE_CONFIG .* seeds=\([0-9]*\) .*/\1/p' "/tmp/rm_test_$name.log" | tail -1)"
        reported_steps="$(sed -n 's/^EFFECTIVE_CONFIG .* steps=\([0-9]*\).*/\1/p' "/tmp/rm_test_$name.log" | tail -1)"
        reported_iters="$(sed -n 's/^EFFECTIVE_CONFIG .* iterations=\([0-9]*\).*/\1/p' "/tmp/rm_test_$name.log" | tail -1)"
        reported_seedlist="$(sed -n 's/^EFFECTIVE_CONFIG .* seed_list=\(.*\)$/\1/p' "/tmp/rm_test_$name.log" | tail -1)"

        case "$name" in
            test_state_machine.lua|test_state_machine_verbs.lua)
                # Seed-list overrides the count check by design (bank replay).
                if [ -z "${SM_SEED_LIST:-}" ] && [ -n "${SM_SEEDS:-}" ]; then
                    [ "$reported_seeds" != "$SM_SEEDS" ] && \
                        cfg_fail="seeds requested=$SM_SEEDS effective=${reported_seeds:-<none>}"
                fi
                if [ -n "${SM_STEPS:-}" ]; then
                    [ "$reported_steps" != "$SM_STEPS" ] && \
                        cfg_fail="$cfg_fail steps requested=$SM_STEPS effective=${reported_steps:-<none>}"
                fi
                ;;
            test_differential_fuzz.lua)
                [ -n "${DF_SEEDS:-}" ] && [ "$reported_seeds" != "$DF_SEEDS" ] && \
                    cfg_fail="$cfg_fail df_seeds requested=$DF_SEEDS effective=${reported_seeds:-<none>}"
                [ -n "${DF_STEPS:-}" ] && [ "$reported_steps" != "$DF_STEPS" ] && \
                    cfg_fail="$cfg_fail df_steps requested=$DF_STEPS effective=${reported_steps:-<none>}"
                ;;
            test_menusorter_differential_fuzz.lua)
                [ -n "${ITERATIONS:-}" ] && [ "$reported_iters" != "$ITERATIONS" ] && \
                    cfg_fail="$cfg_fail iterations requested=$ITERATIONS effective=${reported_iters:-<none>}"
                ;;
        esac

        # A requested seed bank must appear in the reported seed_list.
        if [ -n "${SM_SEED_LIST:-}" ] && grep -q 'seed_list=' "/tmp/rm_test_$name.log"; then
            IFS=',' read -ra want_seeds <<< "$SM_SEED_LIST"
            for ws in "${want_seeds[@]}"; do
                if ! grep -q "seed_list=.*${ws}\([+,]\|$\)" "/tmp/rm_test_$name.log" 2>/dev/null \
                   && ! echo "$reported_seedlist" | tr '+' '\n' | grep -qx "$ws"; then
                    cfg_fail="$cfg_fail seed_bank missing seed=$ws"
                    break
                fi
            done
        fi
    elif [[ "$CONFIG_REQUIRED" == *" $name "* ]]; then
        cfg_fail="no EFFECTIVE_CONFIG banner (suite silently ignored its knobs?)"
    fi

    [ "$truncated" -eq 1 ] && cfg_fail="$cfg_fail truncated output: no summary line even after retry"

    if [ "$suite_rc" -eq 0 ] && [ -z "$cfg_fail" ]; then
        pass=$((pass+1))
        printf '  [PASS] %s\n' "$name"
    else
        fail=$((fail+1)); failed_list="$failed_list $name"
        printf '  [FAIL] %s  (log: /tmp/rm_test_%s.log)\n' "$name" "$name"
        [ -n "$cfg_fail" ] && printf '         CONFIG MISMATCH:%s\n' "$cfg_fail"
        grep -m3 '^\s*\[FAIL\]' "/tmp/rm_test_$name.log" | sed 's/^/         /'
    fi
    rm -rf "$suite_home"
    unset KO_HOME
done
elapsed=$(( $(date +%s) - start_ts ))

echo "-------------------------------------------------------------------"
echo "Suites: $pass passed, $fail failed (${elapsed}s) [tier=$TIER]"
if [ $fail -gt 0 ]; then
    echo "Failed:$failed_list"
    exit 1
fi
exit 0
