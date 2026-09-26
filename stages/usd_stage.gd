# usd_stage -- usd.elf (Cut U): an OpenUSD .usdz package (Pixal3D's answer,
# Stage 7) opened from bytes inside the sandbox; meshes and materials cross
# the host as packed arrays (rule 6), util/usd_nodes.gd makes Godot nodes of
# them. CPU only, every call a plain vmcall on the calling thread: a Pixal3D
# package opens in tens of ms (gates/U-usd).
#
#   open_package(bytes)   the whole .usdz as one PackedByteArray (pushed in
#                         CHUNK pieces past the 16 MiB syscall view)
#   document()            {open, up, mpu, meshes: [...], materials: [...]}
#   mesh(i) / material(i) one mesh / material, arrays fetched in slices
#   close()
#
# Sizes (gates/U-usd/README.md, the ladder): memory_max MEM_MB is 1.25x the
# smallest rung that opened and extracted the largest Pixal3D package seen
# (14.9 MB, texture_size 2048); execution_timeout TIMEOUT_UNITS covers the
# largest call seen (instret) with the same margin.
#
# One document per Sandbox (gates/U-usd, finding 1): the fifth big package
# opened in one Sandbox at memory_max 160 or 320 killed Godot (signal 11 in
# the vmcall, no guest exception, heap 2 MB after every close), while 40
# opens at 1024 and 12 at 512 did not; the mechanism is not understood, so
# open_package frees the Sandbox and loads usd.elf again (~0.4 s) for every
# document after the first. The loop's INFER opens one package a run.
# The MCP wrappers at the end each have a main.gd delegate (rule 8).
extends "res://stages/stage_base.gd"

const UsdNodes := preload("res://util/usd_nodes.gd")
const REQUIRED := ["usd_init", "usd_open", "usd_push", "usd_open_staged", "usd_close", "usd_mesh_count",
		"usd_material_count", "usd_texture_count", "usd_mesh_info", "usd_mesh_points_slice", "usd_mesh_normals_slice",
		"usd_mesh_uvs_slice", "usd_mesh_indices_slice", "usd_mesh_transform", "usd_material", "usd_texture_info",
		"usd_texture_slice", "usd_blake3", "usd_curve_count", "usd_curve_info", "usd_curve_points", "usd_layer_data",
		"usd_write_curves"]
const MEM_MB := 240 # gates/U-usd ladder: floor 192 MiB (real-t2048.usdz) x 1.25
const TIMEOUT_UNITS := 400 # gates/U-usd: 306 units for the 14.9 MB open, x 1.25
const ALLOCATIONS_MAX := 1000000
const CHUNK := 8 << 20 # bytes per usd_push
const SLICE_ITEMS := 1 << 20 # points / triangles per slice (12 MiB of floats or ints)
const SLICE_BYTES := 8 << 20 # texture bytes per slice
const DEFAULT_PACKAGE := "res://../gates/U-usd/inputs/stub-quad.usdz"

# Set before add_child to size a ladder rung (gates/U-usd); the defaults are the measured ones.
var mem_mb := MEM_MB
var timeout_units := TIMEOUT_UNITS
var last_open := "" # the guest's open line
var last_open_us := 0 # host-timed, the whole push + open (not the reload)
var last_load_us := 0 # host-timed reload of usd.elf before this open (0 for the first)
var docs_opened := 0 # documents opened in this stage's life (reloads = docs_opened - 1)
var doc_up := "Y"
var doc_mpu := 1.0

func _ready() -> void:
	ensure()

# Opens the sandbox now (a SceneTree script's _initialize adds the node before
# the root is ready, so _ready would only run on the first frame). Idempotent.
func ensure() -> bool:
	stage_name = "usd"
	return open_sandbox("res://usd.elf", mem_mb, 4096, timeout_units,
			{"allocations_max": ALLOCATIONS_MAX, "binary_translation_bg_compilation": false}, PackedStringArray(REQUIRED))

func _s(fn: String, args: Array = []) -> String:
	return str(call_now(fn, args))

func _i(fn: String, args: Array = []) -> int:
	var r = call_now(fn, args)
	return int(r) if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT else -1

# --- pipeline calls ---------------------------------------------------------------------

func init() -> String:
	return _s("usd_init")

# The guest's line: "ok layer=usdz prims=P meshes=M ..." or "ERR: ..." / "FAIL: ...".
func open_package(bytes: PackedByteArray) -> String:
	if sandbox == null:
		return "FAIL: usd missing (%s)" % reason
	last_load_us = 0
	if docs_opened > 0:
		# finding 1: a fresh Sandbox for every document after the first
		var t := Time.get_ticks_usec()
		if busy():
			return busy_text()
		sandbox.free()
		sandbox = null
		if not ensure():
			return "FAIL: usd.elf did not reload (%s)" % reason
		last_load_us = Time.get_ticks_usec() - t
	docs_opened += 1
	var t0 := Time.get_ticks_usec()
	var r := ""
	if bytes.size() <= CHUNK:
		r = _s("usd_open", [bytes])
	else:
		var at := 0
		while at < bytes.size():
			var n: int = mini(CHUNK, bytes.size() - at)
			var p := _s("usd_push", [bytes.slice(at, at + n)])
			if not p.begins_with("staged="):
				return "FAIL: usd_push at %d: %s" % [at, p]
			at += n
		r = _s("usd_open_staged")
	last_open_us = Time.get_ticks_usec() - t0
	last_open = r
	doc_up = _field(r, "up", "Y")
	doc_mpu = float(_field(r, "mpu", "1"))
	return r

func open_file(path: String) -> String:
	var g := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(g):
		return "FAIL: no file %s" % path
	return open_package(FileAccess.get_file_as_bytes(g))

func close() -> String:
	return _s("usd_close")

func count() -> int:
	return _i("usd_mesh_count")

func material_count() -> int:
	return _i("usd_material_count")

func texture_count() -> int:
	return _i("usd_texture_count")

func curve_count() -> int:
	return _i("usd_curve_count")

# One stroke of the open document: {name, boundary, points: PackedVector3Array,
# blake3_points} or {error}.
func curve(i: int) -> Dictionary:
	var info = call_now("usd_curve_info", [i])
	if typeof(info) != TYPE_DICTIONARY:
		return {"error": str(info)}
	var f = call_now("usd_curve_points", [i])
	if typeof(f) != TYPE_PACKED_FLOAT32_ARRAY:
		return {"error": str(f)}
	var pts := PackedVector3Array()
	pts.resize(f.size() / 3)
	for k in pts.size():
		pts[k] = Vector3(f[3 * k], f[3 * k + 1], f[3 * k + 2])
	return {"name": str(info.name), "boundary": bool(info.boundary), "points": pts,
			"blake3_points": str(info.blake3_points)}

func layer_data() -> Dictionary:
	var d = call_now("usd_layer_data")
	return d if typeof(d) == TYPE_DICTIONARY else {"error": str(d)}

# The .usda text for these strokes, or "ERR: ..." / "FAIL: ...".
func write_curves(points: PackedFloat32Array, counts: PackedInt32Array, boundary: PackedInt32Array,
		names: PackedStringArray, meta: Dictionary) -> String:
	var kv := PackedStringArray()
	for k in meta:
		kv.append("%s=%s" % [k, str(meta[k])])
	return _s("usd_write_curves", [points, counts, boundary, "\n".join(names), "\n".join(kv)])

static func _field(line: String, key: String, def: String) -> String:
	var k := " %s=" % key
	var at := line.find(k)
	if at < 0:
		return def
	var v := line.substr(at + k.length())
	var sp := v.find(" ")
	return v if sp < 0 else v.substr(0, sp)

func _floats(fn: String, i: int, n_items: int, stride: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var at := 0
	while at < n_items:
		var n: int = mini(SLICE_ITEMS, n_items - at)
		var r = call_now(fn, [i, at, n])
		if typeof(r) != TYPE_PACKED_FLOAT32_ARRAY or r.size() != n * stride:
			push_warning("usd: %s(%d, %d, %d) -> %s" % [fn, i, at, n, str(r).left(200)])
			return PackedFloat32Array()
		out.append_array(r)
		at += n
	return out

func _ints(fn: String, i: int, n_items: int, stride: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var at := 0
	while at < n_items:
		var n: int = mini(SLICE_ITEMS, n_items - at)
		var r = call_now(fn, [i, at, n])
		if typeof(r) != TYPE_PACKED_INT32_ARRAY or r.size() != n * stride:
			push_warning("usd: %s(%d, %d, %d) -> %s" % [fn, i, at, n, str(r).left(200)])
			return PackedInt32Array()
		out.append_array(r)
		at += n
	return out

# A texture's bytes as they are in the package (PNG / JPEG), in slices.
func texture(i: int) -> PackedByteArray:
	var info = call_now("usd_texture_info", [i])
	if typeof(info) != TYPE_DICTIONARY:
		return PackedByteArray()
	var size: int = int(info.size)
	var out := PackedByteArray()
	var at := 0
	while at < size:
		var n: int = mini(SLICE_BYTES, size - at)
		var r = call_now("usd_texture_slice", [i, at, n])
		if typeof(r) != TYPE_PACKED_BYTE_ARRAY or r.size() != n:
			push_warning("usd: usd_texture_slice(%d, %d, %d) -> %s" % [i, at, n, str(r).left(200)])
			return PackedByteArray()
		out.append_array(r)
		at += n
	return out

# usd_mesh_info plus the arrays: points / normals / uvs (PackedFloat32Array,
# 3 / 3 / 2 a point), indices (PackedInt32Array, 3 a triangle, USD's
# right-handed order), xform (16 floats). {error} when i is out of range.
func mesh(i: int) -> Dictionary:
	var info = call_now("usd_mesh_info", [i])
	if typeof(info) != TYPE_DICTIONARY:
		return {"error": str(info)}
	var m: Dictionary = info.duplicate()
	var n: int = int(m.points)
	m["points"] = _floats("usd_mesh_points_slice", i, n, 3)
	m["point_count"] = n
	m["normals"] = _floats("usd_mesh_normals_slice", i, n, 3) if m.has_normals else PackedFloat32Array()
	m["uvs"] = _floats("usd_mesh_uvs_slice", i, n, 2) if m.has_uvs else PackedFloat32Array()
	m["indices"] = _ints("usd_mesh_indices_slice", i, int(m.triangles), 3)
	return m

# usd_material plus every texture it uses as <input>_bytes (the guest sends
# diffuse_bytes itself when it fits the 16 MiB view).
func material(i: int) -> Dictionary:
	var d = call_now("usd_material", [i])
	if typeof(d) != TYPE_DICTIONARY:
		return {"error": str(d)}
	var m: Dictionary = d.duplicate()
	var cache := {}
	for k in ["diffuse", "metallic", "roughness", "opacity", "normal"]:
		var t: int = int(m.get(k + "_texture", -1))
		if t < 0 or m.has(k + "_bytes"):
			continue
		if not cache.has(t):
			cache[t] = texture(t)
		m[k + "_bytes"] = cache[t]
	return m

# Everything of the open document, for util/usd_nodes.gd and the pipeline.
func document() -> Dictionary:
	var meshes := []
	for i in count():
		meshes.append(mesh(i))
	var mats := []
	for i in material_count():
		mats.append(material(i))
	return {"open": last_open, "up": doc_up, "mpu": doc_mpu, "meshes": meshes, "materials": mats}

# --- MCP wrappers (rule 8; main.gd delegates to each) ---------------------------------
# Big arrays answer as a summary line, not the array.

static func _sum_f(a, stride: int) -> String:
	if typeof(a) != TYPE_PACKED_FLOAT32_ARRAY:
		return str(a)
	var head := []
	for k in mini(a.size(), 2 * stride):
		head.append("%.6g" % a[k])
	return "n=%d items=%d first=[%s]" % [a.size(), a.size() / stride, ", ".join(head)]

static func _sum_i(a, stride: int) -> String:
	if typeof(a) != TYPE_PACKED_INT32_ARRAY:
		return str(a)
	var head := []
	for k in mini(a.size(), 2 * stride):
		head.append(str(a[k]))
	return "n=%d items=%d first=[%s]" % [a.size(), a.size() / stride, ", ".join(head)]

static func _sum_b(a) -> String:
	if typeof(a) != TYPE_PACKED_BYTE_ARRAY:
		return str(a)
	return "bytes=%d head=%s" % [a.size(), a.slice(0, mini(a.size(), 8)).hex_encode()]

func usd_init() -> String: return init()
func usd_open(path: String = DEFAULT_PACKAGE) -> String:
	var r := open_file(path)
	return "host_us=%d %s" % [last_open_us, r]
func usd_push(path: String = DEFAULT_PACKAGE) -> String:
	var g := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(g):
		return "FAIL: no file %s" % path
	return _s("usd_push", [FileAccess.get_file_as_bytes(g)])
func usd_open_staged() -> String: return _s("usd_open_staged")
func usd_blake3(path: String = DEFAULT_PACKAGE) -> String:
	var g := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(g):
		return "FAIL: no file %s" % path
	return _s("usd_blake3", [FileAccess.get_file_as_bytes(g)])
func usd_close() -> String: return close()
func usd_curve_count() -> int: return curve_count()
func usd_curve_info(i: int = 0) -> String: return str(call_now("usd_curve_info", [i]))
func usd_curve_points(i: int = 0) -> String: return _sum_f(call_now("usd_curve_points", [i]), 3)
func usd_layer_data() -> String: return str(layer_data())
func usd_write_curves() -> String:
	return write_curves(PackedFloat32Array([0, 1, 0, 0.1, 1, 0, 0.1, 1.1, 0]), PackedInt32Array([3]),
			PackedInt32Array([0]), PackedStringArray(["demo"]), {"source": "usd_write_curves()"})
func usd_mesh_count() -> int: return count()
func usd_material_count() -> int: return material_count()
func usd_texture_count() -> int: return texture_count()
func usd_mesh_info(i: int = 0) -> String: return str(call_now("usd_mesh_info", [i]))
func usd_mesh_points(i: int = 0) -> String: return _sum_f(call_now("usd_mesh_points", [i]), 3)
func usd_mesh_points_slice(i: int = 0, from: int = 0, count_: int = 4) -> String:
	return _sum_f(call_now("usd_mesh_points_slice", [i, from, count_]), 3)
func usd_mesh_normals(i: int = 0) -> String: return _sum_f(call_now("usd_mesh_normals", [i]), 3)
func usd_mesh_normals_slice(i: int = 0, from: int = 0, count_: int = 4) -> String:
	return _sum_f(call_now("usd_mesh_normals_slice", [i, from, count_]), 3)
func usd_mesh_uvs(i: int = 0) -> String: return _sum_f(call_now("usd_mesh_uvs", [i]), 2)
func usd_mesh_uvs_slice(i: int = 0, from: int = 0, count_: int = 4) -> String:
	return _sum_f(call_now("usd_mesh_uvs_slice", [i, from, count_]), 2)
func usd_mesh_indices(i: int = 0) -> String: return _sum_i(call_now("usd_mesh_indices", [i]), 3)
func usd_mesh_indices_slice(i: int = 0, from: int = 0, count_: int = 4) -> String:
	return _sum_i(call_now("usd_mesh_indices_slice", [i, from, count_]), 3)
func usd_mesh_transform(i: int = 0) -> String: return _sum_f(call_now("usd_mesh_transform", [i]), 16)
func usd_material(i: int = 0) -> String:
	var d = call_now("usd_material", [i])
	if typeof(d) != TYPE_DICTIONARY:
		return str(d)
	var m: Dictionary = d.duplicate()
	if m.has("diffuse_bytes"):
		m["diffuse_bytes"] = _sum_b(m.diffuse_bytes)
	return str(m)
func usd_texture_info(i: int = 0) -> String: return str(call_now("usd_texture_info", [i]))
func usd_texture(i: int = 0) -> String: return _sum_b(call_now("usd_texture", [i]))
func usd_texture_slice(i: int = 0, from: int = 0, count_: int = 16) -> String:
	return _sum_b(call_now("usd_texture_slice", [i, from, count_]))

# The open document as a Node3D under this stage (replacing the last one):
# "ok meshes=N materials=M" with the surfaces' sizes.
func usd_scene() -> String:
	var old := get_node_or_null("Scene")
	if old != null:
		old.free()
	var doc := document()
	var n := UsdNodes.to_node(doc)
	n.name = "Scene"
	add_child(n)
	var parts := []
	for c in n.get_children():
		if c is MeshInstance3D and c.mesh != null:
			parts.append("%s:%d verts" % [c.name, c.mesh.surface_get_array_len(0)])
	return "ok meshes=%d materials=%d [%s]" % [doc.meshes.size(), doc.materials.size(), ", ".join(parts)]
