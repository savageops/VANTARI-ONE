#!/usr/bin/env bash
# Reference pressure loop — delta-detection script (roadmap P1-19).
#
# Compares the current state of .refs/ references against the last recorded
# state in .docs/research/_ref-state.json. If a reference has changed (new
# commits, modified files), the script reports the delta so the team can
# decide whether to re-harvest.
#
# Usage: bash scripts/ref-pressure.sh
# Output: human-readable delta report to stdout

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
REFS_DIR="$REPO_ROOT/.refs"
STATE_FILE="$REPO_ROOT/.docs/research/_ref-state.json"

if [ ! -d "$REFS_DIR" ]; then
    echo "No .refs/ directory found. Nothing to check."
    exit 0
fi

echo "=== Reference Pressure Loop ==="
echo "Checking .refs/ for drift since last harvest..."
echo ""

changed=0
total=0

for ref_dir in "$REFS_DIR"/*/; do
    [ -d "$ref_dir" ] || continue
    ref_name=$(basename "$ref_dir")
    total=$((total + 1))

    # Get the current HEAD commit hash.
    current_hash=$(cd "$ref_dir" && git rev-parse HEAD 2>/dev/null || echo "non-git")

    # Get the recorded hash from the state file (if it exists).
    recorded_hash=$(grep "\"$ref_name\"" "$STATE_FILE" 2>/dev/null | grep -o '"hash":"[^"]*"' | cut -d'"' -f4 || echo "unrecorded")

    if [ "$current_hash" != "$recorded_hash" ]; then
        changed=$((changed + 1))
        echo "  DELTA: $ref_name"
        echo "    recorded: $recorded_hash"
        echo "    current:  $current_hash"

        # Show the number of new commits.
        if [ "$recorded_hash" != "unrecorded" ] && [ "$current_hash" != "non-git" ]; then
            new_commits=$(cd "$ref_dir" && git rev-list "$recorded_hash..HEAD" --count 2>/dev/null || echo "?")
            echo "    new commits: $new_commits"
        fi
        echo ""
    else
        echo "  OK: $ref_name (no change)"
    fi
done

echo ""
echo "=== Summary: $changed of $total references have drifted ==="

if [ "$changed" -gt 0 ]; then
    echo ""
    echo "Action required: re-harvest drifted references."
    echo "For each DELTA reference:"
    echo "  1. Study new commits for primitives worth borrowing"
    echo "  2. Apply the VANTARI compression test (fewer concepts, stronger guarantees)"
    echo "  3. Record accepted primitives in the changelog"
    echo "  4. Record rejected primitives in _rejected-primitives.md with rationale"
    echo "  5. Update _ref-state.json with the new hash"
fi
