#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build_release.sh — Reordering Menus release builder
#
# Produces a release ZIP from TRACKED git content ONLY (git archive of HEAD),
# so a developer's dirty/untracked working tree can never leak into — or
# silently substitute for — a release.
#
# Fail-closed checks:
#   1. every REQUIRED_RUNTIME file is tracked in git (untracked => FAIL)
#   2. every tracked file is classified in the manifest (unknown => FAIL)
#   3. nothing matching DEV_ONLY_PATTERNS would enter the archive
#   4. every runtime module is referenced by an exact require() literal in
#      the tracked tree (catches stale require strings / manifest drift)
#
# Layout: archive root IS the plugin directory (<Plugin>.koplugin/), which is
# what a KOReader install expects next to other *.koplugin directories.
# File order and metadata are normalized for reproducible listings.
#
# Usage:
#   ./build_release.sh                  # -> dist/reorderingmenus-<version>.zip
#   ./build_release.sh -o /tmp/out.zip  # explicit output path
#   VERIFY=1 ./build_release.sh         # additionally run the clean-install
#                                       # smoke test (tests/test_release_install_smoke.lua)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
MANIFEST="packaging/release-manifest.conf"

command -v git >/dev/null || { echo "FAIL: git not found" >&2; exit 2; }
command -v zip >/dev/null  || { echo "FAIL: zip not found" >&2;  exit 2; }
[ -f "$MANIFEST" ] || { echo "FAIL: manifest missing: $MANIFEST" >&2; exit 2; }

# shellcheck source=packaging/release-manifest.conf
source "$MANIFEST"

PLUGIN_NAME="ReorderingMenus.koplugin"
VERSION="$(git describe --tags --abbrev=0 2>/dev/null || git rev-parse --short=12 HEAD)"

fail() { echo "BUILD FAILED: $*" >&2; exit 1; }

TRACKED="$(git ls-files | sort)"

# --- 1. required runtime must be tracked ------------------------------------
for f in $REQUIRED_RUNTIME; do
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 || \
        fail "required runtime file NOT tracked in git: $f"
done

# --- 2. every tracked file must be classified --------------------------------
# NOTE: patterns are fed through a here-doc, NEVER an unquoted for-list:
# `for pat in $DEV_ONLY_PATTERNS` would pathname-expand globs like tests/*
# against the current directory, turning patterns into concrete paths.
match_pattern() {  # match_pattern <string> <pattern> -> exit 0 on match
    # shellcheck disable=SC2254
    case "$1" in
        $2) return 0 ;;
    esac
    return 1
}

classify() {  # prints REQUIRED | OPTIONAL | DEV_ONLY | UNKNOWN for $1
    local f="$1"
    local c pat
    for c in $REQUIRED_RUNTIME; do [ "$f" = "$c" ] && { echo REQUIRED; return; }; done
    for c in $OPTIONAL_DISTRIBUTABLE; do [ "$f" = "$c" ] && { echo OPTIONAL; return; }; done
    while IFS= read -r pat; do
        [ -n "$pat" ] || continue
        if match_pattern "$f" "$pat"; then echo DEV_ONLY; return; fi
    done <<EOF
$DEV_ONLY_PATTERNS
EOF
    echo UNKNOWN
}

UNKNOWN_LIST=""
for f in $TRACKED; do
    cls="$(classify "$f")"
    if [ "$cls" = "UNKNOWN" ]; then
        UNKNOWN_LIST="$UNKNOWN_LIST $f"
    fi
done
if [ -n "$UNKNOWN_LIST" ]; then
    echo "BUILD FAILED: tracked file(s) missing from packaging/release-manifest.conf:" >&2
    for f in $UNKNOWN_LIST; do echo "  - $f" >&2; done
    exit 1
fi

# --- 3. forbidden files must not ship ----------------------------------------
SHIPPING="$REQUIRED_RUNTIME $OPTIONAL_DISTRIBUTABLE"
for f in $SHIPPING; do
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 || continue   # optional & untracked: skip
    case "$f" in
        tests/*|docs/*|patches/*|packaging/*|.commandcode/*|scripts/*)
            fail "shippable file inside a development-only directory: $f" ;;
    esac
done

# --- 4. require-literal sanity against the tracked tree ----------------------
STAGE="$(mktemp -d)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$STAGE" "$SCRATCH"' EXIT
mkdir -p "$STAGE/$PLUGIN_NAME" "$SCRATCH/head"
git archive HEAD | tar -x -C "$SCRATCH/head"

for f in $REQUIRED_RUNTIME; do
    base="${f%.lua}"
    case "$base" in main|_meta) continue ;; esac   # loader-contract names
    grep -rqF "require(\"$base\")" "$SCRATCH/head" || \
        fail "module '$base' never referenced by any tracked require() — stale require string or wrong manifest entry?"
done

# --- stage ONLY the shipping set from the HEAD extraction ---------------------
for f in $REQUIRED_RUNTIME; do
    [ -f "$SCRATCH/head/$f" ] || fail "required runtime file missing from HEAD archive: $f"
    cp -p "$SCRATCH/head/$f" "$STAGE/$PLUGIN_NAME/$f"
done
for f in $OPTIONAL_DISTRIBUTABLE; do
    if [ -f "$SCRATCH/head/$f" ]; then
        mkdir -p "$STAGE/$PLUGIN_NAME/$(dirname "$f")"
        cp -p "$SCRATCH/head/$f" "$STAGE/$PLUGIN_NAME/$f"
    fi
done

# --- deterministic archive ----------------------------------------------------
# normalize metadata on files AND directories, then zip an explicitly SORTED
# file list (readdir order is arbitrary) so identical commits produce
# byte-identical archives.
find "$STAGE/$PLUGIN_NAME" -exec touch -t 198504121200.00 {} +
find "$STAGE/$PLUGIN_NAME" -type d -exec chmod 755 {} +
find "$STAGE/$PLUGIN_NAME" -type f -exec chmod 644 {} +

OUT="${RELEASE_OUT:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) OUT="${2:-}"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n "$OUT" ] || OUT="dist/reorderingmenus-${VERSION}.zip"
case "$OUT" in /*) ;; *) OUT="$SCRIPT_DIR/$OUT" ;; esac
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"

FILELIST="$(cd "$STAGE" && find "$PLUGIN_NAME" ! -type d | LC_ALL=C sort)"
(cd "$STAGE" && zip -q -X "$OUT" $FILELIST)

echo "-------------------------------------------------------------------"
echo "Release contents ($OUT):"
unzip -l "$OUT"
echo "-------------------------------------------------------------------"
echo "OK: built $OUT from $(git rev-parse HEAD)"
echo "    required runtime: $(echo $REQUIRED_RUNTIME | wc -w | tr -d ' ') files, optional shipped: $(unzip -l "$OUT" | grep -c '\.\(png\|md\)$' || true)"
