#!/usr/bin/env bash
# Compatibility entrypoint. The root runner is the sole tier/configuration
# authority, so this wrapper cannot drift in paths, seed counts, or validation.
set -u
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIER="${1:-quick}"
export TIER
exec "$PROJECT/run_tests.sh" \
    tests/test_state_machine_verbs.lua tests/test_state_machine.lua
