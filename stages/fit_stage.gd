# fit_stage -- fit.elf (Cut 6): cloth-fit's garment retargeting, one phase per
# vmcall. A phase runs for seconds to minutes, so fit_begin and fit_step go to
# the worker Thread (Gate 0F probe 7) and the pipeline polls between jobs;
# every other fit call answers BUSY meanwhile (one VM, one vmcall at a time).
#
# fit.elf is built by build.sh (BUILD_FIT=0 skips it) and is not committed, so
# it is optional: without it the stage has a reason instead of a sandbox.
#
# The MCP wrappers at the end are cut-6's main.gd ones (same names, same
# defaults); main.gd delegates to each (rule 8), and forwards the
# fit_config_overrides / fit_memory_mib / fit_elf / fit_execution_timeout
# properties Gate 6 sets on /root/Main.
extends "res://stages/stage_base.gd"

const ObjIO := preload("res://util/obj_io.gd")
const REQUIRED := ["fit_reset", "fit_set_body", "fit_set_skeletons", "fit_set_garment", "fit_set_config", "fit_begin",
		"fit_step", "fit_status", "fit_result_vertices", "fit_check_intersections"]

# The fit Sandbox's limits, applied when it is (re)created (fit_configure).
# memory_max in MiB, set before program= (a lower value later is ignored,
# Gate 0F probe 6); the guest heap is 0.8 x memory_max. Gate 6.P's ladder on
# foxgirl (phases 0+1): 352 passes, 320 kills the Godot process (segfault),
# 224-256 abort the vmcall (Protection fault in the malloc ecall); 440 is
# 1.25x that floor. The loop runs at 2048, where Gate 8's two FoxGirl fits ran
# (heap 99 MiB at the end); Gate 6 passes its own (--mem, default 2048).
const FIT_MEMORY_FLOOR_MIB := 352
var fit_memory_mib := 2048
var fit_elf := "res://fit.elf"
# execution_timeout counts 2^20-instruction units (Gate 0F probe 5; the default
# 8000 is ~8.4e9 instructions). Gate 6.P: the largest foxgirl phase retires
# 5.62e11 instructions (535,568 units, phase 3); 2,500,000 is 4.7x that, so one
# phase fits one vmcall and a runaway solve still stops (~1 h at ~0.75 G
# instructions/s). In Gate 8's loop phase 0 is the slowest (1150 s against
# phase 3's 602 s); scaled by that ratio it is ~1.0e6 units, 2.4x under.
var fit_execution_timeout := 2500000
# Top-level keys of the setup JSON replaced as text before fit_set_config
# (key -> JSON literal), e.g. {"fit_weight": "0"} for Gate 6's fit-gap control.
var fit_config_overrides := {}

var _last := "" # the last worker call's answer

func _ready() -> void:
	stage_name = "fit"
	_open()

# allocations_max: the default 10000 live chunks is exhausted inside
# fit_begin ("Too many arena chunks", a robin_set in ipc-toolkit's collision
# mesh; PolyFEM keeps ~79k small allocations alive).
func _open() -> bool:
	return open_sandbox(fit_elf, fit_memory_mib, 4096, fit_execution_timeout, {"allocations_max": 4000000},
			PackedStringArray(REQUIRED))

# --- pipeline calls -------------------------------------------------------------------

# Hands the whole problem over (small, synchronous). "" on success, else the
# first guest answer that was not OK.
func setup(body_v: PackedFloat32Array, body_f: PackedInt32Array, src_skel: PackedFloat32Array,
		tgt_skel: PackedFloat32Array, bones: PackedInt32Array, garment_v: PackedFloat32Array,
		garment_f: PackedInt32Array, nofit: PackedInt32Array, config_text: String) -> String:
	var calls := [
		["fit_reset", []],
		["fit_set_body", [body_v, body_f]],
		["fit_set_skeletons", [src_skel, tgt_skel, bones]],
		["fit_set_garment", [garment_v, garment_f, nofit]],
		["fit_set_config", [config_text]],
	]
	for c in calls:
		var r := str(call_now(c[0], c[1]))
		if not r.begins_with("OK"):
			return "%s: %s" % [c[0], r]
	return ""

func start_begin() -> String:
	return start("fit_begin")

func start_step() -> String:
	return start("fit_step")

func status_raw() -> String:
	return str(call_now("fit_status"))

func result_vertices():
	return call_now("fit_result_vertices")

# override: empty checks the solver's own state; else that garment (body space).
func check_intersections(override_v: PackedFloat32Array = PackedFloat32Array()) -> String:
	return str(call_now("fit_check_intersections", [override_v]))

# --- MCP wrappers (cut-6's main.gd, moved here; rule 8) ------------------------------

func _fit_busy() -> String:
	if sandbox == null:
		return "FAIL: no fit sandbox (%s)" % reason
	if busy():
		return busy_text()
	var p := poll()
	if p.result != null:
		_last = "host_ms=%d %s" % [p.host_ms, str(p.result)]
	return ""

func _fit_now(method: String, args: Array = []) -> String:
	var b := _fit_busy()
	return b if b != "" else str(call_now(method, args))

func _fit_start(method: String) -> String:
	var b := _fit_busy()
	if b != "":
		return b
	var r := start(method)
	return r + " (poll fit_status)" if r.begins_with("STARTED") else r

func _repo_path(rel: String) -> String:
	return ProjectSettings.globalize_path("res://").path_join("..").path_join(rel).simplify_path()

# A fresh fit Sandbox with the current fit_memory_mib / fit_elf /
# fit_execution_timeout (Gate 6.P: one Sandbox per ladder arm). Drops every
# input and the driver.
func fit_configure() -> String:
	if busy():
		return busy_text()
	if sandbox != null:
		remove_child(sandbox)
		sandbox.free()
		sandbox = null
	_last = ""
	_result = null
	if not _open():
		return "FAIL: no %s (%s)" % [fit_elf, reason]
	return "OK fit sandbox %s memory_max %d MiB execution_timeout %d" % [fit_elf, fit_memory_mib, fit_execution_timeout]

func fit_configure_with(memory_mib: int = 2048, elf: String = "res://fit.elf", execution_timeout: int = -1) -> String:
	fit_memory_mib = memory_mib
	fit_elf = elf
	if execution_timeout > 0:
		fit_execution_timeout = execution_timeout
	return fit_configure()

func _apply_overrides(cfg_text: String) -> String:
	for k in fit_config_overrides:
		var re := RegEx.new()
		re.compile("(\"%s\"\\s*:\\s*)[^,}\\n]+" % k)
		if re.search(cfg_text) == null:
			cfg_text = cfg_text.replace("{", "{\"%s\": %s, " % [k, fit_config_overrides[k]])
		else:
			cfg_text = re.sub(cfg_text, "${1}" + str(fit_config_overrides[k]))
	return cfg_text

# Loads foxgirl_skirt as the native oracle does (tools/native/foxgirl_oracle.json:
# the FoxGirl avatar and skeleton, LCL_Skirt_DressEvening_003 with its skeleton
# and no-fit list) through util/obj_io.gd and hands it to fit.elf. Positions go
# as float32, as fit_native rounds them by default. Then call fit_begin.
func fit_fixture_foxgirl() -> String:
	var busy_s := _fit_busy()
	if busy_s != "":
		return busy_s
	var a := foxgirl_arrays()
	if a.has("error"):
		return "FAIL: " + str(a["error"])
	var out := PackedStringArray()
	out.append(str(call_now("fit_reset")))
	out.append(str(call_now("fit_set_body", [a["body_v"], a["body_f"]])))
	out.append(str(call_now("fit_set_skeletons", [a["src_sk_v"], a["tgt_sk_v"], a["bones"]])))
	out.append(str(call_now("fit_set_garment", [a["garment_v"], a["garment_f"], a["nofit"]])))
	# The config goes as text: a GDScript round trip would turn 2 into 2.0,
	# which the spec's integer fields refuse. The guest drops the *_path keys.
	out.append(str(call_now("fit_set_config", [_apply_overrides(a["cfg_text"])])))
	if not fit_config_overrides.is_empty():
		out.append("overrides %s" % str(fit_config_overrides))
	return " | ".join(out)

# The foxgirl fixture as the packed arrays that cross the wire (Gate 6.0's
# wire check holds them to fit_native --dump-inputs bit for bit).
func foxgirl_arrays() -> Dictionary:
	var cfg_path := _repo_path("tools/native/foxgirl_oracle.json")
	var cfg_text := FileAccess.get_file_as_string(cfg_path)
	if cfg_text.is_empty():
		return {"error": "cannot read %s" % cfg_path}
	var cfg = JSON.parse_string(cfg_text)
	if typeof(cfg) != TYPE_DICTIONARY:
		return {"error": "%s is not a JSON object" % cfg_path}
	var body: Dictionary = ObjIO.read(_repo_path(cfg["avatar_mesh_path"]))
	var garment: Dictionary = ObjIO.read(_repo_path(cfg["garment_mesh_path"]))
	var src_sk: Dictionary = ObjIO.read(_repo_path(cfg["source_skeleton_path"]))
	var tgt_sk: Dictionary = ObjIO.read(_repo_path(cfg["target_skeleton_path"]))
	for m in [body, garment, src_sk, tgt_sk]:
		if m.has("error"):
			return {"error": m["error"]}
	if src_sk["l"] != tgt_sk["l"]:
		return {"error": "source and target skeletons have different bones"}
	var nofit := PackedInt32Array()
	if str(cfg.get("no_fit_spec_path", "")) != "":
		var r: Dictionary = ObjIO.read_ints(_repo_path(cfg["no_fit_spec_path"]))
		if r.has("error"):
			return {"error": r["error"]}
		nofit = r["ints"]
	return {"cfg_text": cfg_text, "body_v": body["v"], "body_f": body["f"], "garment_v": garment["v"],
			"garment_f": garment["f"], "src_sk_v": src_sk["v"], "tgt_sk_v": tgt_sk["v"], "bones": src_sk["l"],
			"nofit": nofit}

func fit_reset() -> String:
	return _fit_now("fit_reset")

func fit_begin() -> String:
	return _fit_now("fit_begin")

# One phase (AL solve or reduced solve) on the worker thread.
func fit_step() -> String:
	return _fit_start("fit_step")

# Every remaining phase in one vmcall, on the worker thread.
func fit_run_all() -> String:
	return _fit_start("fit_run_all")

# The guest's status (phase, Newton iterations, energy, io_attempts, heap) plus
# the host's view: the Sandbox heap reading and the last worker answer.
func fit_status() -> String:
	var b := _fit_busy()
	if b != "":
		return b
	return "%s host_heap_usage=%d | last: %s" % [status_raw(), heap(), _last]

# Skin weights for the target avatar (J x N, rows are joints); the FoxGirl
# fixture has none, so the default clears them.
func fit_set_skin_weights(weights: PackedFloat32Array = PackedFloat32Array()) -> String:
	return _fit_now("fit_set_skin_weights", [weights])

# Intersection check on the current state.
func fit_check() -> String:
	return _fit_now("fit_check_intersections", [PackedFloat32Array()])

# The current garment: vertex count and body-space bounds (GDScript callers
# take the arrays from fit_result_vertices / fit_result_vertices_f64).
func fit_result() -> String:
	var b := _fit_busy()
	if b != "":
		return b
	var v = call_now("fit_result_vertices")
	if typeof(v) != TYPE_PACKED_FLOAT32_ARRAY:
		return str(v)
	return "garment %d v, bounds %s" % [v.size() / 3, str(bounds(v))]

func fit_result_vertices() -> Variant:
	var b := _fit_busy()
	return b if b != "" else call_now("fit_result_vertices")

func fit_result_vertices_f64() -> Variant:
	var b := _fit_busy()
	return b if b != "" else call_now("fit_result_vertices_f64")

# The newest preview snapshot (every Newton iteration by default).
func fit_preview() -> String:
	var b := _fit_busy()
	if b != "":
		return b
	var v = call_now("fit_preview", [0])
	if typeof(v) != TYPE_PACKED_FLOAT32_ARRAY:
		return str(v)
	return "preview %d v, bounds %s" % [v.size() / 3, str(bounds(v))]

# The SDF (Lean kernel) at the current garment's vertices: the value range in
# voxels (the grid stores solve-frame distances, clamped to [-1, 150] voxels)
# and how many vertices are inside the body.
func fit_sdf() -> String:
	var b := _fit_busy()
	if b != "":
		return b
	var g = call_now("fit_result_vertices_f64")
	if typeof(g) != TYPE_PACKED_FLOAT64_ARRAY:
		return str(g)
	var d = call_now("fit_sdf_dump", [g])
	if typeof(d) != TYPE_PACKED_FLOAT64_ARRAY:
		return str(d)
	var n: int = d.size() / 10
	var h := 0.01
	var cfg = JSON.parse_string(FileAccess.get_file_as_string(_repo_path("tools/native/foxgirl_oracle.json")))
	if typeof(cfg) == TYPE_DICTIONARY and cfg.has("voxel_size"):
		h = float(cfg["voxel_size"])
	var lo := INF
	var hi := -INF
	var inside := 0
	for i in n:
		var x: float = d[10 * i] / h
		lo = minf(lo, x)
		hi = maxf(hi, x)
		if x < 0.0:
			inside += 1
	return "sdf at %d garment vertices: min %.4f max %.4f voxels, %d inside" % [n, lo, hi, inside]

func fit_probe_io() -> String:
	return _fit_now("fit_probe", ["io"])

func fit_probe_ldlt() -> String:
	return _fit_now("fit_probe", ["ldlt"])

func fit_probe_exceptions() -> String:
	return _fit_now("fit_probe", ["exceptions"])

func fit_probe_io_paths() -> String:
	return _fit_now("fit_probe", ["io_paths"])

# polysolve's SimplicialLDLT on an 8000-unknown 3D Laplacian, host-timed
# around the vmcall (the guest clock is not a clock).
func fit_probe_ldlt8k() -> String:
	var t0 := Time.get_ticks_usec()
	var r := _fit_now("fit_probe", ["ldlt8k"])
	return "host_us=%d %s" % [Time.get_ticks_usec() - t0, r]

# libm result hashes (fit_probes.cpp); fit_native --probe libm prints its own.
func fit_probe_libm() -> String:
	return _fit_now("fit_probe", ["libm"])

# Tie order of std::sort / nth_element / partial_sort and a sum in that order
# (fit_probes.cpp); fit_native --probe stl prints its own.
func fit_probe_stl() -> String:
	return _fit_now("fit_probe", ["stl"])

# The instret CSR advances (Gate 6.P reads a phase's instruction count with it).
func fit_probe_instret() -> String:
	return _fit_now("fit_probe", ["instret"])

func fit_probe_heap() -> String:
	return _fit_now("fit_probe", ["heap"])

# The intersection check's positive control: the garment's closest vertex
# moved 5 cm (0.05 solve units, 5 voxels) into the avatar along -grad SDF,
# through fit_check_intersections. Must say INTERSECTS.
func fit_push_control() -> String:
	return _fit_push(0.05)

# Its flat control: the same path with no push. Must say none.
func fit_push_flat() -> String:
	return _fit_push(0.0)

func _fit_push(dist: float) -> String:
	var b := _fit_busy()
	if b != "":
		return b
	var cur = call_now("fit_result_vertices")
	var pushed = call_now("fit_push_vertex", [dist])
	if typeof(pushed) != TYPE_PACKED_FLOAT32_ARRAY or typeof(cur) != TYPE_PACKED_FLOAT32_ARRAY:
		return "FAIL: %s / %s" % [str(pushed).left(200), str(cur).left(200)]
	var moved := -1
	var by := 0.0
	for i in range(0, cur.size(), 3):
		var d := Vector3(pushed[i] - cur[i], pushed[i + 1] - cur[i + 1], pushed[i + 2] - cur[i + 2]).length()
		if d > by:
			by = d
			moved = i / 3
	var r := str(call_now("fit_check_intersections", [pushed]))
	return "push %.3f solve units: vertex %d moved %.5f body units -> %s" % [dist, moved, by, r]

static func bounds(v: PackedFloat32Array) -> AABB:
	if v.size() < 3:
		return AABB()
	var box := AABB(Vector3(v[0], v[1], v[2]), Vector3.ZERO)
	for i in range(0, v.size(), 3):
		box = box.expand(Vector3(v[i], v[i + 1], v[i + 2]))
	return box
