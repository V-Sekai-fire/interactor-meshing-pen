#!/usr/bin/env bash
# Every test of this fork, zero-shot: from a fresh clone, one command, no editor
# run, no prior import, no interactor-dress-on checkout (the ELFs are committed).
#   tools/test.sh            (GODOT=<binary> to pick the engine; default godot)
# Exit 0 only if every probe prints RESULT: PASS. Each run is capped at 300 s.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
LOG="$(mktemp -d)"
# GNU timeout: `timeout` on Linux, `gtimeout` (coreutils) on macOS.
TO="$(command -v timeout || command -v gtimeout)"

# The first run of a fresh clone must import (ELFs, scenes) before any script runs.
"$TO" 300 "$GODOT" --headless --path "$ROOT" --import >"$LOG/import.log" 2>&1

fail=0
for probe in tools/probe_load.gd; do
	"$TO" 300 "$GODOT" --headless --path "$ROOT" --xr-mode off --script "$probe" >"$LOG/run.log" 2>&1
	if grep -q "RESULT: PASS" "$LOG/run.log"; then
		echo "PASS $probe"
	else
		echo "FAIL $probe"; tail -20 "$LOG/run.log"; fail=1
	fi
done
exit $fail
