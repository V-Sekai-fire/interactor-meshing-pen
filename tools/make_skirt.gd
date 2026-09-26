# Generate the scripted-skirt stroke fixture as OpenUSD, headless (no XR, no RD):
# read the FoxGirl body and 15-joint skeleton fixtures, make the 6-stroke
# scripted skirt (xr/pen_source_scripted.gd), and write it through usd.elf
# (util/strokes_usd.gd). The fixture feeds tools/gate_replay.gd --strokes.
#
#   godot --headless --path . --xr-mode off --script tools/make_skirt.gd -- \
#       --out=res://tools/strokes/skirt.usda
extends SceneTree

const UsdStage := preload("res://stages/usd_stage.gd")
const StrokesUsd := preload("res://util/strokes_usd.gd")
const InferStage := preload("res://stages/infer_stage.gd")
const PenSource := preload("res://xr/pen_source_scripted.gd")

func _die(msg: String) -> void:
	print("RESULT: FAIL " + msg)
	quit(1)

func _initialize() -> void:
	var out := "res://tools/strokes/skirt.usda"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var infer := InferStage.new()
	root.add_child(infer)
	var body := infer.body_fixture()
	if str(body.get("error", "")) != "":
		return _die("body fixture: " + str(body.error))
	var rig := infer.rig_fixture()
	if str(rig.get("error", "")) != "":
		return _die("rig fixture: " + str(rig.error))
	var src := PenSource.make(body.vertices, rig.joints, {})
	if str(src.get("error", "")) != "":
		return _die("pen source: " + str(src.error))
	var stage = UsdStage.new()
	root.add_child(stage)
	stage.ensure()
	if stage.sandbox == null:
		return _die("usd.elf did not load: " + str(stage.reason))
	stage.init()
	var w := StrokesUsd.to_usda(stage, src.strokes, {"source": "scripted skirt (pen_source_scripted)", "gate": "2263"})
	if w.has("error"):
		return _die("to_usda: " + w.error)
	var abs_out := ProjectSettings.globalize_path(out) if out.begins_with("res://") else out
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
	var f := FileAccess.open(abs_out, FileAccess.WRITE)
	if f == null:
		return _die("cannot write " + abs_out)
	f.store_string(w.text)
	f.close()
	print("RESULT: PASS wrote %d strokes -> %s" % [src.strokes.size(), abs_out])
	quit(0)
