# curvenet_stage -- curvenet.elf (Cut 4): Cassie's pen -> curvenet -> mesh.
# The pipeline's AUTHOR state feeds it pen_begin_at / pen_point_at / pen_end_raw in the
# body-local frame; MESH calls mesh_build and reads the welded mesh and its
# boundary loops (util/mesh_wire.gd's format). CPU only.
#
# The MCP wrappers at the end are cut-4's main.gd ones (same names, same
# defaults); main.gd delegates to each (rule 8). The pipeline calls are separate
# so the scripted-pen wrappers (pen_begin / pen_point) keep their MCP shape.
extends "res://stages/stage_base.gd"

const MeshWire := preload("res://util/mesh_wire.gd")
const REQUIRED := ["cn_reset", "cn_set_param", "cn_set_body", "pen_begin", "pen_point", "pen_end", "patch_count",
		"curvenet_build", "curvenet_curves", "curvenet_knots", "mesh_build", "mesh_vertices", "mesh_indices",
		"mesh_boundary_loops"]

func _ready() -> void:
	stage_name = "curvenet"
	# A PMP remesh of a whole garment runs far past the default 8000 x 2^20
	# instructions (Gate 0F probe 5); 2^24 units is effectively unbounded.
	open_sandbox("res://curvenet.elf", 1024, 4096, 1 << 24, {}, PackedStringArray(REQUIRED))

func _cn_call(fn: String, args: Array = []) -> String:
	if sandbox == null:
		return "FAIL: no curvenet sandbox (%s)" % reason
	var t0 := Time.get_ticks_usec()
	var r = call_now(fn, args)
	return "host_us=%d %s" % [Time.get_ticks_usec() - t0, str(r)]

# --- pipeline calls (raw guest answers) ---------------------------------------------

func set_body(v: PackedFloat32Array, f: PackedInt32Array) -> String:
	return str(call_now("cn_set_body", [v, f]))

func reset() -> String:
	return str(call_now("cn_reset"))

func set_param(name: String, value: float) -> String:
	return str(call_now("cn_set_param", [name, value]))

func pen_begin_at(p: Vector3, pressure: float) -> int:
	var r = call_now("pen_begin", [p.x, p.y, p.z, pressure])
	return int(r) if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT else -1

func pen_point_at(id: int, p: Vector3, pressure: float) -> String:
	return str(call_now("pen_point", [id, p.x, p.y, p.z, pressure]))

func pen_end_raw(id: int) -> String:
	return str(call_now("pen_end", [id]))

func patches() -> int:
	var r = call_now("patch_count")
	return int(r) if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT else -1

func build_curvenet() -> String:
	return str(call_now("curvenet_build"))

func curves():
	return call_now("curvenet_curves")

func knots():
	return call_now("curvenet_knots")

# mesh_build on the worker thread (a remesh can take seconds); poll().
func start_mesh_build(target_edge_length: float, weld_eps: float) -> String:
	return start("mesh_build", [target_edge_length, weld_eps])

func mesh_arrays() -> Dictionary:
	var v = call_now("mesh_vertices")
	var f = call_now("mesh_indices")
	var l = call_now("mesh_boundary_loops")
	if typeof(v) != TYPE_PACKED_FLOAT32_ARRAY or typeof(f) != TYPE_PACKED_INT32_ARRAY or typeof(l) != TYPE_PACKED_INT32_ARRAY:
		return {"error": "mesh arrays: %s / %s / %s" % [type_string(typeof(v)), type_string(typeof(f)), type_string(typeof(l))]}
	return {"vertices": v, "triangles": f, "loops": MeshWire.loops(l)}

# --- MCP wrappers (cut-4's main.gd, moved here unchanged; rule 8) ---------------------
# Meshes, curves and knots cross as packed arrays in util/mesh_wire.gd's
# format. No GPU: every call is a plain vmcall; host_us times it. main.gd
# keeps a same-named delegate for each.

func cn_reset() -> String:
	return _cn_call("cn_reset")

func cn_set_param(name: String = "snap_radius", value: float = 0.03) -> String:
	return _cn_call("cn_set_param", [name, value])

func cn_get_param(name: String = "snap_radius") -> String:
	return _cn_call("cn_get_param", [name])

# The demo body: an r = 0.5 SphereMesh at the origin.
func cn_set_body_sphere(radius: float = 0.5) -> String:
	var b := MeshWire.sphere(radius)
	return _cn_call("cn_set_body", [b.vertices, b.triangles])

# One closed stroke at 30 degrees latitude, 1 cm off the demo sphere: it
# snaps onto the body and closes one patch. Resets the stage first.
func pen_demo_circle() -> String:
	var b := cn_set_body_sphere()
	var r := cn_reset()
	var s := MeshWire.circle_stroke(0.51, PI / 6.0, TAU, 64)
	return "%s | %s | %s" % [b, r, _cn_call("pen_stroke", [s])]

# The scripted pen source: pen_begin/pen_point/pen_end with no arguments
# replay one stroke sample by sample, as a tracked pen would deliver it. The
# stroke is pen_demo_circle's (30 degrees latitude, 1 cm off the demo sphere,
# closed); call cn_set_body_sphere and cn_reset first for a fresh stage.
var _pen_src := PackedFloat32Array()
var _pen_next := 0
var _pen_id := -1

# Loads the scripted stroke (samples + 1 samples, the last on the first) and
# sends its first sample; the guest's stroke id is kept for pen_point/pen_end.
func pen_begin(samples: int = 64, pressure: float = 0.5) -> String:
	if sandbox == null:
		return "FAIL: no curvenet sandbox (%s)" % reason
	_pen_src = MeshWire.circle_stroke(0.51, PI / 6.0, TAU, samples, pressure)
	_pen_next = 4
	var t0 := Time.get_ticks_usec()
	var r = call_now("pen_begin", [_pen_src[0], _pen_src[1], _pen_src[2], _pen_src[3]])
	_pen_id = int(r) if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT else -1
	return "host_us=%d id=%d samples=%d" % [Time.get_ticks_usec() - t0, _pen_id, _pen_src.size() / 4]

# The next `count` samples of the scripted stroke (0: all that remain).
func pen_point(count: int = 0) -> String:
	if sandbox == null:
		return "FAIL: no curvenet sandbox (%s)" % reason
	if _pen_id < 0 or _pen_next >= _pen_src.size():
		return "FAIL: no scripted stroke in progress (pen_begin first)"
	var end := _pen_src.size() if count <= 0 else mini(_pen_src.size(), _pen_next + 4 * count)
	var sent := 0
	var r = ""
	var t0 := Time.get_ticks_usec()
	while _pen_next < end:
		var i := _pen_next
		r = call_now("pen_point", [_pen_id, _pen_src[i], _pen_src[i + 1], _pen_src[i + 2], _pen_src[i + 3]])
		_pen_next += 4
		sent += 1
	return "host_us=%d sent=%d left=%d %s" % [Time.get_ticks_usec() - t0, sent,
			(_pen_src.size() - _pen_next) / 4, str(r)]

# id < 0: the scripted stroke's.
func pen_end(id: int = -1) -> String:
	var r := _cn_call("pen_end", [_pen_id if id < 0 else id])
	if id < 0:
		_pen_id = -1
	return r

func patch_count() -> String:
	return _cn_call("patch_count")

# Patch i over the wire: vertex and triangle counts (the buffers are
# mesh_wire's; mesh_array_mesh has the built mesh as an ArrayMesh).
func patch_vertices(i: int = 0) -> String:
	if sandbox == null:
		return "FAIL: no curvenet sandbox (%s)" % reason
	var v = call_now("patch_vertices", [i])
	if typeof(v) != TYPE_PACKED_FLOAT32_ARRAY:
		return str(v)
	return "patch %d: %d vertices" % [i, v.size() / 3]

func patch_indices(i: int = 0) -> String:
	if sandbox == null:
		return "FAIL: no curvenet sandbox (%s)" % reason
	var f = call_now("patch_indices", [i])
	if typeof(f) != TYPE_PACKED_INT32_ARRAY:
		return str(f)
	return "patch %d: %d triangles" % [i, f.size() / 3]

# The built mesh's source patch per triangle (-1 after a remesh).
func mesh_patch_ids() -> String:
	if sandbox == null:
		return "FAIL: no curvenet sandbox (%s)" % reason
	var ids = call_now("mesh_patch_ids")
	if typeof(ids) != TYPE_PACKED_INT32_ARRAY:
		return str(ids)
	var per := {}
	for p in ids:
		per[p] = per.get(p, 0) + 1
	return "%d triangles, per patch %s" % [ids.size(), str(per)]

func check_names() -> String:
	return _cn_call("check_names")

# Gate 4's checks in the guest, one line each. pen_sphere resets the stage
# and clears the body.
func curvenet_checks() -> String:
	return _cn_call("check_all")

func curvenet_check(name: String = "pen_sphere") -> String:
	return _cn_call("check", [name])

func curvenet_build() -> String:
	var r := _cn_call("curvenet_build")
	var c := MeshWire.curves(call_now("curvenet_curves")) if sandbox != null else []
	var k := MeshWire.knots(call_now("curvenet_knots")) if sandbox != null else []
	return "%s | wire: %d curves, %d knots" % [r, c.size(), k.size()]

# Merge + weld the active patches; target_edge_length > 0 PMP-remeshes.
func mesh_build(target_edge_length: float = 0.02, weld_eps: float = 1e-5) -> String:
	var r := _cn_call("mesh_build", [target_edge_length, weld_eps])
	if sandbox == null:
		return r
	var loops := MeshWire.loops(call_now("mesh_boundary_loops"))
	var v = call_now("mesh_vertices")
	return "%s | wire: %d vertices, %d boundary loops" % [r, v.size() / 3 if typeof(v) == TYPE_PACKED_FLOAT32_ARRAY else -1, loops.size()]

# The built mesh as an ArrayMesh (Godot winding), for a MeshInstance3D.
func mesh_array_mesh() -> ArrayMesh:
	if sandbox == null:
		return ArrayMesh.new()
	return MeshWire.to_array_mesh(call_now("mesh_vertices"), call_now("mesh_indices"))

# Mesh -> curvenet on a unit cube: 12 curves on 8 knots.
func curvenet_extract_demo() -> String:
	var c := MeshWire.cube()
	return _cn_call("curvenet_extract", [c.vertices, c.triangles, 200, 1e-3, 1e-2, 0.0])
