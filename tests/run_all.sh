#!/usr/bin/env bash
# tests/run_all.sh - Thin wrapper forwarding to the authoritative test runner.
# Kept for CLI ergonomics; all test execution, hermetic environment setup,
# and suite discovery are managed by run_tests.sh.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

exec "$REPO_ROOT/run_tests.sh" "$@"
