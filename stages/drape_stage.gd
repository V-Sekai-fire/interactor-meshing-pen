# drape_stage -- drape.elf: Stage 2's AVBD solver jobs (moved from main.gd
# unchanged) and Cut 5's drape API (drape_open / scene_mesh / primitive /
# config / queue_forward / tick / positions / result), which the pipeline's
# DRAPE and DRAPE_COLLECT states use.
#
# The drape API exists only in a drape.elf built from cut-5 on. has_drape()
# says whether this one has it; the pipeline turns "no" into
# FAILED("drape missing") unless --allow-fixture names drape.
#
# Rule 4: a forward is queued, then drape_tick runs once per frame from
# _process (the host clock goes in with it) until it answers IDLE.
#
# Cut 6d: the fit mode. fit_avbd_start loads the garment against the body
# mesh collider with a fit set (every vertex the loop lists, pulled toward
# the body surface + gap by the attachment kernels) and queues drape.elf's
# fit phase (gravity off, targets refreshed); the pipeline's FIT_* states in
# fit_mode avbd run it with FIT_AVBD, the one setting Gate 6d's ladder picked.
extends "res://stages/stage_base.gd"

const DRAPE_API := ["drape_open", "drape_scene_mesh", "drape_primitive", "drape_config", "drape_queue_forward",
		"drape_tick", "drape_positions", "drape_result"]
const FIT_API := ["drape_fit_set", "drape_queue_fit"]

# The avbd fit's setting: one rung of Gate 6d's ladder (gates/6d-fit-avbd/
# README.md, "The ladder"), not a slider; gate_fit_avbd.gd FAILs if this is
# not its CHOSEN rung. Drape units (1 m = 10 units, the loop's drape_scale):
# the body collider's skin 0.1 (1 cm), band 0.1 and depth 1.0 as the drape's;
# gap 0 = every fitted vertex is pulled to the body surface itself (cloth-fit's
# fit term pulls to sdf = 0; the collider's skin is the clearance, as its
# contact barrier is there); k = kFit, the pull per unit of vertex area
# against the membrane's kTri 150 x area (600 is the cloth-fit calibration,
# fit_weight 2 over similarity 1; 180 is x0.3 of it); iters = solver
# iterations per step; steps = the fit phase's cap, tol = the largest vertex
# move per step (units) that ends it early; refresh = steps between target
# refreshes; similarity 1 = the rest shape is re-fitted every refresh as the
# best similarity (rotation, uniform scale, translation) of the authored
# garment onto the current vertices (drape_scene.h fitSimilarity: cloth-fit's
# SimilarityForm with one global transform, so the skirt can shrink to the
# hips as PolyFEM's does instead of buckling); kBend = the bending stiffness
# during the fit (the drape's own 1e-5 is restored by the DRAPE state's fresh
# scene). Why this rung: the ladder table's numbers (the README): the closest
# to the PolyFEM fit (mean / p95 per-vertex distance) among the rungs whose
# fit_check_intersections is OK none, within the loop's 45 s.
const FIT_AVBD := {
	"iters": 32,
	"steps": 300,
	"tol": 0.0005,
	"k": 60.0,
	"gap": 0.0,
	"refresh": 1,
	"similarity": 1.0,
	"h": 1.0 / 60.0,
	"restEvery": 4,
	"settle": 0,
	"kAnchor": 100.0,
	"kBend": 0.00001,
	"skin": 0.1,
	"band": 0.1,
	"depth": 1.0,
}

var _drape_status := "IDLE no session"
var _drape_job_status := ""
var _drape_job_on := false
var ticks := 0

func _ready() -> void:
	stage_name = "drape"
	# The drape's uniform sets are kernels x colours per call.
	open_sandbox("res://drape.elf", 1024, 65536, 0)

# "" if this drape.elf has the Cut 5 API, else why not.
func drape_api_missing() -> String:
	if sandbox == null:
		return reason
	if not sandbox.has_method("has_function"):
		return ""
	for fn in DRAPE_API:
		if not sandbox.has_function(fn):
			return "drape.elf has no %s() (built before cut-5)" % fn
	return ""

# "" if this drape.elf has the Cut 6d fit mode, else why not.
func fit_api_missing() -> String:
	var m := drape_api_missing()
	if m != "":
		return m
	if not sandbox.has_method("has_function"):
		return ""
	for fn in FIT_API:
		if not sandbox.has_function(fn):
			return "drape.elf has no %s() (built before cut-6d)" % fn
	return ""

func _process(_delta: float) -> void:
	if sandbox == null:
		return
	if not _drape_status.begins_with("IDLE") and not _drape_status.begins_with("FAIL"):
		_drape_status = str(call_now("drape_tick", [Time.get_ticks_usec()]))
		ticks += 1
	if _drape_job_on:
		_drape_job_status = str(call_now("drape_job_tick", [Time.get_ticks_usec()]))
		if not _drape_job_status.begins_with("RUNNING"):
			_drape_job_on = false

# --- Stage 2: the AVBD solver ----------------------------------------------------
# The one-shot calls are cpu only (rule 4: a one-shot rd call would sync in its
# submit's frame). On rd use the jobs below: avbd_job_start("fixture", "rd"),
# avbd_job_start("bench_fwd", "rd"), then avbd_job_tick once per frame.

func avbd_fixture(backend: String = "cpu") -> String:
	if sandbox == null:
		return "FAIL: no drape sandbox"
	var t0 := Time.get_ticks_usec()
	var r = sandbox.vmcall("avbd_fixture", backend)
	return "host_us=%d %s" % [Time.get_ticks_usec() - t0, str(r)]

func avbd_bench(backend: String = "cpu", nx: int = 32, ny: int = 32, substeps: int = 5, iters: int = 10) -> String:
	if sandbox == null:
		return "FAIL: no drape sandbox"
	var t0 := Time.get_ticks_usec()
	var r = sandbox.vmcall("avbd_bench", backend, nx, ny, substeps, iters)
	var dt := Time.get_ticks_usec() - t0
	return "host_us=%d ms/substep=%.2f %s" % [dt, dt / 1000.0 / substeps, str(r)]

# Drop the job and free the drape's RenderingDevice and its permanent RID
# slots; call before freeing the drape sandbox (BUSY while a submit is in flight).
func drape_rd_close() -> String:
	return str(sandbox.vmcall("rd_close")) if sandbox != null else "FAIL: no drape sandbox"

func drape_rd_last_step() -> String:
	return str(sandbox.vmcall("rd_last_step")) if sandbox != null else "FAIL: no drape sandbox"

# Rule 4's guard: syncs that landed in their submit's process frame.
func rd_rule4() -> String:
	return str(sandbox.vmcall("rd_rule4")) if sandbox != null else "FAIL: no drape sandbox"

# The guard's positive control: submits and syncs in one call.
func rd_rule4_probe() -> String:
	return str(sandbox.vmcall("rd_rule4_probe")) if sandbox != null else "FAIL: no drape sandbox"

# Stage 2 gate jobs: one job at a time, one tick per frame. Rule 4: a job's
# GPU submit ends its tick, so the readback lands on a later frame.
func avbd_job_start(name: String = "fixture", backend: String = "rd") -> String:
	return str(sandbox.vmcall("avbd_job_start", name, backend)) if sandbox != null else "FAIL: no drape sandbox"

func avbd_job_tick() -> String:
	return str(sandbox.vmcall("avbd_job_tick", Time.get_ticks_usec())) if sandbox != null else "FAIL: no drape sandbox"

func avbd_job_names() -> String:
	return str(sandbox.vmcall("avbd_job_names")) if sandbox != null else "FAIL: no drape sandbox"

# --- Cut 5: the drape API ----------------------------------------------------------

func _dv(name: String, args: Array = []) -> String:
	var miss := drape_api_missing()
	if miss != "" and name.begins_with("drape_"):
		return "FAIL: " + miss
	return str(call_now(name, args))

# backend: cpu | rd | auto (rd from 160 vertices at 90 fps: Gate 5 G9).
func drape_open(backend: String = "auto") -> String:
	return _dv("drape_open", [backend])

func drape_sphere_demo(backend: String = "auto") -> String:
	var o := drape_open(backend)
	if not o.begins_with("OPENED"):
		return o
	return _dv("drape_scene_sphere_demo")

# material: [density, kTri, kBend, kAttach], any prefix.
func drape_scene_mesh(positions: PackedFloat32Array = PackedFloat32Array(), triangles: PackedInt32Array = PackedInt32Array(),
		pins: PackedInt32Array = PackedInt32Array(), material: PackedFloat32Array = PackedFloat32Array()) -> String:
	return _dv("drape_scene_mesh", [positions, triangles, pins, material])

# kind: sphere [c, r, mu] | plane [c, ul, ur, mu] | capsule [bottom, axis, r, len, mu] | clear.
func drape_primitive(kind: String = "clear", params: PackedFloat32Array = PackedFloat32Array()) -> String:
	return _dv("drape_primitive", [kind, params])

# A triangle-mesh body collider (positions in drape units, like the capsules);
# params [skin, mu, band, depth], any prefix (0.1, 0.3, 0.1, 1.0).
func drape_primitive_mesh(positions: PackedFloat32Array = PackedFloat32Array(), triangles: PackedInt32Array = PackedInt32Array(),
		params: PackedFloat32Array = PackedFloat32Array()) -> String:
	return _dv("drape_primitive_mesh", [positions, triangles, params])

func drape_config(key: String = "iters", value: float = 16.0) -> String:
	return _dv("drape_config", [key, value])

# steps > 0 queues steps; 0 rewinds to the initial state.
func drape_forward(steps: int = 100) -> String:
	var r := _dv("drape_queue_forward", [steps])
	if r.begins_with("QUEUED"):
		_drape_status = "RUNNING"
		ticks = 0
	return r

# Cut 6d: the fit set of the loaded scene_mesh scene; params [kFit, gap,
# refresh, similarity, restEvery, settle, kAnchor]; anchor = the loop whose
# centre is held at its source position (the waist loop), the similarity's
# pivot.
func drape_fit_set(verts: PackedInt32Array = PackedInt32Array(), params: PackedFloat32Array = PackedFloat32Array(),
		anchor: PackedInt32Array = PackedInt32Array()) -> String:
	return _dv("drape_fit_set", [verts, params, anchor])

# Queue the fit phase (gravity off, targets refreshed) for up to max_steps
# steps, ending early when the largest vertex move per step is under tol.
func drape_fit(max_steps: int = 300, tol: float = 0.0005) -> String:
	var r := _dv("drape_queue_fit", [max_steps, tol])
	if r.begins_with("QUEUED"):
		_drape_status = "RUNNING"
		ticks = 0
	return r

# The avbd fit of the loop (pipeline FIT_* in fit_mode avbd, and Gate 6d's
# ladder): the garment (metres, body space) against the body mesh collider,
# both scaled to drape units, a fit set of `fit_verts` anchored at `anchor`
# (the waist loop, its centre held at its source position at kAnchor, the
# similarity rest update's pivot), and the fit phase queued with the setting
# p (FIT_AVBD's keys; scale and mu from the caller).
# Returns {steps: [every setup answer], queued: String}; a FAIL/BUSY answer
# in steps is the caller's failure. drape_status then reads RUNNING until the
# phase ends; drape_positions (drape units) is the fitted garment.
func fit_avbd_start(garment_v: PackedFloat32Array, tris: PackedInt32Array, fit_verts: PackedInt32Array,
		anchor: PackedInt32Array, body_v: PackedFloat32Array, body_f: PackedInt32Array, p: Dictionary,
		scale: float = 10.0, mu: float = 0.3, backend: String = "auto") -> Dictionary:
	var steps := [
		drape_open(backend),
		drape_primitive("clear", PackedFloat32Array()),
		drape_primitive_mesh(_scaled(body_v, scale), body_f,
				PackedFloat32Array([float(p.skin), mu, float(p.band), float(p.depth)])),
		drape_config("iters", float(p.iters)),
		drape_config("kBend", float(p.kBend)),
		drape_config("h", float(p.h)),
		drape_config("gravityY", -9.8 * scale),
		drape_scene_mesh(_scaled(garment_v, scale), tris, PackedInt32Array(), PackedFloat32Array()),
		drape_fit_set(fit_verts, PackedFloat32Array([float(p.k), float(p.gap), float(p.refresh), float(p.similarity),
				float(p.restEvery), float(p.settle), float(p.kAnchor)]), anchor),
	]
	var q := drape_fit(int(p.steps), float(p.tol))
	return {"steps": steps, "queued": q}

# AlignTest.lean's oracle through the vendored sinew_align, in the guest.
func drape_sinew_align_test() -> String:
	return _dv("drape_sinew_align_test")

# The drape's own material after a fit (the DRAPE state loads a fresh scene,
# which takes g_cfg as it stands): iters 16, kBend 1e-5 and h 1/180 back.
func fit_avbd_restore() -> Array:
	return [drape_config("iters", 16.0), drape_config("kBend", 0.00001), drape_config("h", 1.0 / 180.0)]

static func _scaled(v: PackedFloat32Array, s: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(v.size())
	for i in v.size():
		out[i] = v[i] * s
	return out

# kind: trajectory (the recorded frames become the target) | points | clear.
func drape_target(kind: String = "trajectory", verts: PackedInt32Array = PackedInt32Array(),
		positions: PackedFloat32Array = PackedFloat32Array(), frame: int = -1) -> String:
	return _dv("drape_set_target", [kind, verts, positions, frame])

# loss: match_trajectory | target_points; mode: native | step | unrolled.
func drape_backward(loss: String = "match_trajectory", mode: String = "unrolled") -> String:
	var r := _dv("drape_queue_backward", [loss, mode])
	if r.begins_with("QUEUED"):
		_drape_status = "RUNNING"
	return r

func drape_frame(i: int = 0) -> PackedFloat32Array:
	if drape_api_missing() != "":
		return PackedFloat32Array()
	var r = call_now("drape_frame", [i])
	return r if typeof(r) == TYPE_PACKED_FLOAT32_ARRAY else PackedFloat32Array()

# RUNNING k/N while the queue runs, then IDLE and the last result's first line.
func drape_status() -> String:
	return _drape_status

func drape_result() -> String:
	return _dv("drape_result")

func drape_positions() -> PackedFloat32Array:
	if drape_api_missing() != "":
		return PackedFloat32Array()
	var r = call_now("drape_positions")
	return r if typeof(r) == TYPE_PACKED_FLOAT32_ARRAY else PackedFloat32Array()

func drape_faces() -> PackedInt32Array:
	if drape_api_missing() != "" or not sandbox.has_function("drape_faces"):
		return PackedInt32Array()
	var r = call_now("drape_faces")
	return r if typeof(r) == TYPE_PACKED_INT32_ARRAY else PackedInt32Array()

# Gate 5 jobs: sphere_forward, sphere_backward, sim_gradcheck, bench_drape,
# inverse_min, lbfgsb_components, lbfgsb_problems, lbfgsb_replay, lbfgsb_bench.
func drape_job(name: String = "sphere_forward", backend: String = "auto", args: String = "") -> String:
	var r := _dv("drape_job_start", [name, backend, args])
	_drape_job_on = r.begins_with("STARTED")
	_drape_job_status = r
	return r

func drape_job_result() -> String:
	return _drape_job_status

func drape_job_frame(i: int = 0) -> PackedFloat32Array:
	if drape_api_missing() != "":
		return PackedFloat32Array()
	var r = call_now("drape_job_frame", [i])
	return r if typeof(r) == TYPE_PACKED_FLOAT32_ARRAY else PackedFloat32Array()

func drape_job_names() -> String:
	return _dv("drape_job_names")

# L-BFGS-B over the session's parameters (drape.elf's drape_queue_optimize):
# spec "params=mu[,kTri,...] loss=match_trajectory mode=native steps=N vec=cpu
# m=10 delta=1e-3 ...", one x0/lb/ub value per parameter, max_iter 0 = to
# convergence. Poll drape_status, then drape_optimize_result.
func drape_optimize(spec: String = "params=mu mode=native", x0: PackedFloat32Array = PackedFloat32Array([0.5]),
		lb: PackedFloat32Array = PackedFloat32Array([0.01]), ub: PackedFloat32Array = PackedFloat32Array([1.0]),
		max_iter: int = 10) -> String:
	var r := _dv("drape_queue_optimize", [spec, x0, lb, ub, max_iter])
	if r.begins_with("QUEUED"):
		_drape_status = "RUNNING"
		ticks = 0
	return r

func drape_optimize_result() -> String:
	return _dv("drape_optimize_result")

# Hand the drape jobs a data file by key ("clear" drops them all).
func drape_job_data(key: String = "clear", text: String = "") -> String:
	return _dv("drape_job_data", [key, text])

# The Gate 5 oracle (gates/5-drape/oracle) into drape.elf, for the jobs
# lbfgsb_components, lbfgsb_problems and inverse_min.
func lbfgsb_load_oracle() -> String:
	var root := ProjectSettings.globalize_path("res://../gates/5-drape/oracle/")
	var r := drape_job_data("clear", "")
	for f in ["k_tri", "k_bend_density"]:
		r = drape_job_data("invmin_" + f, FileAccess.get_file_as_string(root + "inverse_min/case_" + f + ".txt"))
	for sub in [["components", ""], ["problems", "prob_"], ["traces", "trace_"]]:
		var d := DirAccess.open(root + sub[0])
		if d == null:
			return "FAIL: no " + root + sub[0]
		for f in d.get_files():
			if f.ends_with(".txt"):
				r = drape_job_data(sub[1] + f.get_basename(), FileAccess.get_file_as_string(root + sub[0] + "/" + f))
	return r

# One tick by hand, with the host clock (MCP stepping; rule 8). _process
# already ticks every frame while a queue or a job runs, so this is only for
# driving a session frame by frame from outside.
func drape_tick() -> String:
	var r := _dv("drape_tick", [Time.get_ticks_usec()])
	_drape_status = r
	return r

func drape_job_tick() -> String:
	var r := _dv("drape_job_tick", [Time.get_ticks_usec()])
	_drape_job_status = r
	if not r.begins_with("RUNNING"):
		_drape_job_on = false
	return r
