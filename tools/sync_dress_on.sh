#!/usr/bin/env bash
# Copy the dress-on loop from an interactor-dress-on checkout into this project,
# at the same res:// paths it has there, so its scripts run here unedited:
#   main.gd, xr_main.tscn, xr/, stages/, util/, infer_host.gd, graph_dump.gd,
#   fixtures/foxgirl/ (.gdignore'd), the guest ELFs the pen path loads, and
#   addons/godot_sandbox.
#
#   tools/sync_dress_on.sh <path to interactor-dress-on>
#
# Re-run it to take a newer dress-on build; the copy is never edited here. The
# ELFs are dress-on's build.sh outputs (project/*.elf); an ELF that is missing
# is a reason the stage reports, not an error (stages/sandbox_util.gd).
set -euo pipefail

SRC="${1:?usage: tools/sync_dress_on.sh <interactor-dress-on checkout>}/project"
DST="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$SRC/main.gd" ] || { echo "sync_dress_on: no $SRC/main.gd"; exit 1; }

ELFS="curvenet.elf fit.elf drape.elf dress_on.elf rd_worker.elf"
FILES="main.gd infer_host.gd graph_dump.gd xr_main.tscn"
DIRS="xr stages util fixtures addons/godot_sandbox"

for d in $DIRS; do
	rm -rf "${DST:?}/$d"
	mkdir -p "$(dirname "$DST/$d")"
	cp -r "$SRC/$d" "$DST/$d"
done
for f in $FILES $ELFS; do
	for g in "$f" "$f.uid"; do
		[ -f "$SRC/$g" ] && cp "$SRC/$g" "$DST/$g"
	done
done
DRESS_ON_COMMIT="$(git -C "$SRC/.." rev-parse HEAD 2>/dev/null || echo unknown)"
echo "$DRESS_ON_COMMIT" > "$DST/DRESS_ON_COMMIT"
echo "sync_dress_on: copied from interactor-dress-on $DRESS_ON_COMMIT"
