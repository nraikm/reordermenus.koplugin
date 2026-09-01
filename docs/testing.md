# Testing Guide

This is the maintained guide for running and extending the Reordering Menus
test suite. The executable suites are the source of truth.

## Prerequisites

Tests run against a real KOReader installation and its bundled LuaJIT. The
default path is:

```text
/Applications/KOReader.app/Contents/koreader
```

Set `KOREADER_DIR` when KOReader is installed elsewhere:

```bash
KOREADER_DIR=/path/to/koreader ./run_tests.sh
```

The runner creates an isolated `KO_HOME` for every suite, so tests do not use
or modify the developer's normal KOReader settings.

## Running Tests

Run the quick tier across every `tests/test_*.lua` suite plus the hostile
storage-safety harness:

```bash
./run_tests.sh
```

Run one or more targeted suites by passing paths relative to the repository:

```bash
./run_tests.sh tests/test_ui_flows.lua
./run_tests.sh tests/test_semantic_diff_unit.lua tests/test_materializer_determinism.lua
```

Logs are written to `/tmp/rm_test_<suite>.log`. A failed run prints the exact
log path.

## Test Tiers

The runner supports four scale profiles. They change the state-machine and
fuzzing knobs while running the same suite entrypoints.

| Tier | Intended use | Command |
|---|---|---|
| `quick` | Local feedback | `./run_tests.sh` |
| `ci` | Continuous integration | `TIER=ci ./run_tests.sh` |
| `nightly` | Broader randomized coverage | `TIER=nightly ./run_tests.sh` |
| `soak` | Extended stress run | `TIER=soak ./run_tests.sh` |

The randomized suites print an `EFFECTIVE_CONFIG` line. `run_tests.sh`
validates it and fails if a suite silently ignores the requested tier knobs.

`tests/run_tier.sh` is a compatibility wrapper for the two state-machine
suites; `run_tests.sh` remains the configuration authority.

## Seeds and Reproduction

Default tier schedules are deterministic. Generate a fresh state-machine seed
list and print it for later replay with:

```bash
TIER=nightly FRESH_SEEDS=1 ./run_tests.sh
```

Replay an explicit list with:

```bash
TIER=nightly SM_SEED_LIST=7919,15838 ./run_tests.sh
```

Individual randomized suites also accept their documented knobs, for example:

```bash
SEED=42 ITERATIONS=100 ./run_tests.sh tests/test_menusorter_differential_fuzz.lua
```

Always include the effective configuration and seed list when reporting a
randomized failure.

## Suite Layout

- `tests/test_*.lua` contains executable suites discovered by the root runner.
- `tests/lib/` contains shared worlds, shrinking, subprocess, and fault helpers.
- `tests/fixtures/historical/` contains legacy persistence inputs used by
  migration tests.
- `tests/fixtures/regression/` contains minimized expected-failure fixtures
  awaiting resolution.
- `tests/fixtures/promoted/` contains fixed histories that must remain green.
- `tests/probe_*.lua` contains diagnostic scripts and is not discovered by the
  default runner.

Some scenarios require process boundaries. The root runner invokes the crash
pipeline and hostile storage harness through their shell wrappers so their
exit behavior matches production recovery paths.

## Regression Fixture Policy

Promote a randomized failure only after it reproduces in a fresh process with
its complete seed prefix. Cluster failures by normalized operation sequence
and violated invariant, then retain the smallest history for each distinct
root cause.

Generated fixtures have explicit outcomes:

- `XFAIL`: the known failure still has the recorded signature.
- `XPASS`: the history now passes and needs deliberate conversion to a
  positive promoted fixture.
- `SIGCHANGED`: the history fails differently and must be investigated as a
  separate regression.

Move a fixed history to `tests/fixtures/promoted/` only after a deterministic
positive suite covers the corrected semantic boundary. Do not delete or retire
fixtures based only on corpus size.

Run both fixture suites directly when changing the state-machine model or
fixture handling:

```bash
./run_tests.sh tests/test_regressions_generated.lua tests/test_regressions_promoted.lua
```

## Mutation Tests

The mutation harness copies the working tree to a temporary directory, applies
one mutation at a time, and runs the designated killer suite without modifying
production source:

```bash
cd /Applications/KOReader.app/Contents/koreader
./luajit /path/to/ReorderingMenus/tests/mutation_test.lua
```

Use the actual KOReader path when it differs from the default.

## Release Verification

Build and verify the release archive with:

```bash
VERIFY=1 ./build_release.sh
```

Verification extracts the built ZIP into an isolated plugin directory and
rejects fallback module resolution from the development checkout.

## Adding or Changing Tests

- Name default-run suites `tests/test_<subject>.lua`.
- Keep tests hermetic; use the runner-provided `KO_HOME` and do not write to a
  real KOReader settings directory.
- Prefer stable IDs and semantic graph assertions over display labels or
  serialized formatting unless serialization is the contract under test.
- Give randomized failures a replayable seed and minimize the history before
  promoting a fixture.
- Add subprocess coverage when the behavior depends on crash, restart, module
  cache, or process-lifetime boundaries.
- Run targeted suites first, then the tier appropriate to the change.
