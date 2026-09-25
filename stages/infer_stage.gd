# infer_stage -- placeholder for infer.elf (Cut 7: Pixal3D image -> mesh;
# Cut 4b: skin-tokens rig). Neither ELF exists yet, so this stage has only
# its fixtures, and the pipeline uses them only when --allow-fixture names
# infer / rig (the run is then labelled FIXTURE):
#
#   infer: the FoxGirl body, fixtures/foxgirl/avatar.obj (1.7 m, Godot frame)
#   rig:   FoxGirl's own skeleton, fixtures/foxgirl/skeleton.obj, through
#          util/skeleton15.gd (identity for this rig)
#
# When infer.elf lands, mesh_from_image / rig go here behind the same two
# calls, and the fixtures stay as the flat control.
extends "res://stages/stage_base.gd"

const ObjIO := preload("res://util/obj_io.gd")
const Skeleton15 := preload("res://util/skeleton15.gd")
const FIXTURE_DIR := "res://fixtures/foxgirl/"

func _ready() -> void:
	stage_name = "infer"
	open_sandbox("res://infer.elf", 4096, 4096, 0, {}, PackedStringArray(["mesh_from_image"]))

# {vertices, triangles, source} or {error}.
func body_fixture() -> Dictionary:
	var m := ObjIO.read(FIXTURE_DIR + "avatar.obj")
	if m.has("error"):
		return {"error": m.error}
	return {"vertices": m.v, "triangles": m.f, "source": "FIXTURE fixtures/foxgirl/avatar.obj"}

# {joints (45), bones (28), map, method, source} or {error}.
func rig_fixture() -> Dictionary:
	var m := ObjIO.read(FIXTURE_DIR + "skeleton.obj")
	if m.has("error"):
		return {"error": m.error}
	var a := Skeleton15.adapt({"positions": m.v, "bones": m.l})
	if a.error != "":
		return {"error": a.error}
	a["source"] = "FIXTURE fixtures/foxgirl/skeleton.obj (skeleton15 %s)" % a.method
	return a

# The curvenet fixture: cloth-fit's LCL skirt on its own source skeleton.
func garment_fixture() -> Dictionary:
	var g := ObjIO.read(FIXTURE_DIR + "garment.obj")
	var s := ObjIO.read(FIXTURE_DIR + "garment_skeleton.obj")
	var nf := ObjIO.read_ints(FIXTURE_DIR + "no-fit.txt")
	for m in [g, s, nf]:
		if m.has("error"):
			return {"error": m.error}
	var a := Skeleton15.adapt({"positions": s.v, "bones": s.l})
	if a.error != "":
		return {"error": "garment skeleton: " + a.error}
	return {"vertices": g.v, "triangles": g.f, "source_joints": a.joints, "nofit": nf.ints,
			"source": "FIXTURE fixtures/foxgirl/garment.obj (LCL_Skirt_DressEvening_003)"}

func fit_config_text() -> String:
	return FileAccess.get_file_as_string(FIXTURE_DIR + "fit_config.json")
