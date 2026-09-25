# pipeline -- the loop as one state machine, advanced from _process (rule 4):
#
#   IDLE -> INFER -> RIG -> AUTHOR -> MESH -> FIT_BEGIN -> FIT_RUN -> FIT_READ
#        -> CHECK -> DRAPE -> DRAPE_COLLECT -> DONE | FAILED(reason)
#
# INFER   body mesh (infer.elf; today only the FoxGirl fixture)
# RIG     15-joint skeleton (infer.elf's rig; today FoxGirl's own, via skeleton15)
# AUTHOR  pen events -> curvenet pen_begin/point/end, then curvenet_build
# MESH    mesh_build on curvenet's worker thread -> garment + boundary loops
# FIT_*   fit_mode polyfem: fit.elf: setup, fit_begin (worker), one fit_step
#         per job (worker), status read between jobs, then the fitted vertices
#         fit_mode avbd (Cut 6d): the similarity retarget, then drape.elf's fit
#         phase against the body mesh collider (drape_stage.gd FIT_AVBD: every
#         garment vertex not in the nofit set pulled to the body surface + gap,
#         gravity off, targets refreshed) ticked from the drape stage's
#         _process; fit.elf is set up and begun on its worker meanwhile, for
#         CHECK. Labelled FIT(avbd), not FIXTURE: the fit is measured
# CHECK   fit_check_intersections must answer "OK none"; the inward-vertex
#         control is run beside it every time
# DRAPE   drape.elf: the fitted garment as a drape_scene_mesh, pinned on its
#         waist loop (the boundary loop with the highest mean y), the body as
#         drape.elf's triangle-mesh collider (or, drape_body = capsules, 14
#         capsules along the skeleton), N forward steps
# DRAPE_COLLECT  drape_tick runs from the drape stage's _process; positions
#         are read once it is IDLE and must all be finite
#
# A stage whose ELF is missing (or too old to have its API) FAILs the run as
# "<stage> missing (...)" unless opts.allow_fixture names it; then its fixture
# stands in and the run is labelled FIXTURE for it. At most one vmcall is in
# flight per sandbox: the long calls go to that stage's worker Thread and the
# machine does nothing else on that stage until poll() says done.
# Every state records its host-timed duration, its stage's vmcall time and
# the stage sandbox's heap when it ends.
extends Node

const PenSource := preload("res://xr/pen_source_scripted.gd")
const MeshTopo := preload("res://util/mesh_topo.gd")
const MeshWire := preload("res://util/mesh_wire.gd")
const ObjIO := preload("res://util/obj_io.gd")

signal state_changed(state: String, record: Dictionary)
signal body_ready(v: PackedFloat32Array, f: PackedInt32Array)
signal skeleton_ready(joints: PackedFloat32Array, bones: PackedInt32Array)
signal strokes_ready(strokes: Array)
signal garment_ready(v: PackedFloat32Array, f: PackedInt32Array, label: String)
signal progress(text: String) # a line within a state (each fit phase)

const TERMINAL := ["IDLE", "DONE", "FAILED"]
const PEN_EVENTS_PER_FRAME := 64

var infer = null
var curvenet = null
var fit = null
var drape = null

var opts := {}
var state := "IDLE"
var reason := ""
var records: Array = []
var fixtures := PackedStringArray()
var data := {}
var pen_queue: Array = []
var pen_external := false # a pen bridge (xr/pen_bridge.gd) feeds pen_queue
var pen_finished := false

var _enter_ms := 0
var _frames := 0
var _run_t0 := 0
var _first := true
var _stroke_ids := {}
var _note := ""

const DEFAULTS := {
	"allow_fixture": [],       # stage keys, or one comma-separated String
	"force_fixture": [],       # stages run as their fixture even when present (to reach what follows them)
	"pen": "scripted",        # scripted | xr
	"drop_seam": false,       # control: the back seam is not drawn -> FAILED(MESH)
	"push_vertex": false,     # control: CHECK uses a garment with one vertex pushed inside -> INTERSECTS
	"closed_rings": false,
	"no_boundary": false,     # control: the rings are ordinary strokes, so their caps are patched too
	"mesh_edge": 0.03,        # curvenet mesh_build target_edge_length (m); 0 = no remesh
	"weld_eps": 1e-5,
	# The fit budget (plan, "Measured budgets"): a <= ~1000-vertex garment
	# (mesh_edge 0.03 gives 932 vertices) and incremental_steps 1, so 2 phases.
	# The plan's "both solves capped at 30" was measured and is not used: at 30
	# the AL phase's first minimize stops short of its constraint, so the AL
	# runs 5 minimizes (150 Newton, 983 s), and the reduced solve throws at its
	# limit (polysolve without allow_out_of_iterations). -1 keeps
	# fixtures/foxgirl/fit_config.json's value (2; AL 50 and Newton 5000, the
	# cut-6 oracle setup).
	"fit_incremental_steps": 1,
	"fit_max_iterations": -1,
	# Newton's force_psd_projection in the AL and the reduced solve (the fit
	# budget, gates/6-fit/budget/README.md): plain Newton on this nonconvex
	# energy takes CCD-clipped steps and the AL's minimizes run to their cap;
	# the projected Hessian's directions let the AL converge in one minimize.
	"fit_force_psd": true,
	"fit_grad_norm": -1.0,    # the reduced solve's grad_norm; -1 keeps fit_config.json's 0.01
	                          # (0.03 with fit_force_psd: 99 Newton native, measured, not the default)
	"drape_steps": 100,
	"drape_backend": "auto",
	"drape_scale": 10.0,      # body metres -> drape units: cut-5's capsule has DiffCloth's fixed 0.1-unit
	                          # contact offset (1 cm at 10). Cut 8 ran at 5 while rd went NaN at 10 on
	                          # the fitted LCL skirt; cut-5-fix's |s| = 0 guard in the bending kernels
	                          # fixed that (Gate 5 G10), so the loop is back at 10
	"drape_mu": 0.3,
	"drape_capsules": true,   # false: no body collider at all (a control for the drape itself)
	"drape_body": "mesh",     # mesh: the body's triangles as drape.elf's mesh collider (cut-5-fix; 0 skirt
	                          # vertices inside after 30 steps against the capsules' 186); capsules: 14
	                          # along the skeleton; none
	"fit_from": "",           # with fit as a fixture: an OBJ whose vertices are the fitted garment (a saved fit)
	"fit_mode": "avbd",       # avbd (default): drape.elf's fit phase with drape_stage.gd's FIT_AVBD (Cut 6d,
	                          # gates/6d-fit-avbd, 13 s), CHECK by fit.elf | polyfem: fit.elf (cloth-fit, 627 s)
	"stop_after": "",         # "MESH" for --gate=pen
}

func setup(stages: Dictionary) -> void:
	infer = stages.get("infer")
	curvenet = stages.get("curvenet")
	fit = stages.get("fit")
	drape = stages.get("drape")

# --- control ---------------------------------------------------------------------------

func start(o: Dictionary = {}) -> String:
	if not (state in TERMINAL):
		return "BUSY pipeline in %s" % state
	for s in [curvenet, fit, drape]:
		if s != null and s.busy():
			return "BUSY %s: %s" % [s.stage_name, s.busy_text()]
	opts = DEFAULTS.duplicate(true)
	for k in o:
		opts[k] = o[k]
	if typeof(opts.allow_fixture) == TYPE_STRING:
		opts.allow_fixture = str(opts.allow_fixture).split(",", false)
	opts.allow_fixture = PackedStringArray(opts.allow_fixture)
	if typeof(opts.force_fixture) == TYPE_STRING:
		opts.force_fixture = str(opts.force_fixture).split(",", false)
	opts.force_fixture = PackedStringArray(opts.force_fixture)
	records = []
	fixtures = PackedStringArray()
	data = {}
	pen_queue = []
	pen_finished = false
	reason = ""
	_stroke_ids = {}
	_run_t0 = Time.get_ticks_msec()
	for s in [infer, curvenet, fit, drape]:
		if s != null:
			s.take_vm_us()
	if not (str(opts.fit_mode) in ["polyfem", "avbd"]):
		return "FAIL fit_mode must be polyfem or avbd, not %s" % str(opts.fit_mode)
	_goto("INFER")
	return "STARTED allow_fixture=%s force_fixture=%s pen=%s fit_mode=%s" % [",".join(opts.allow_fixture),
			",".join(opts.force_fixture), opts.pen, opts.fit_mode]

# Pen events from a bridge (body-local). kind: begin | point | end.
# boundary (begin only): the stroke is the edge of an opening (curvenet's
# boundary pen mode; a cycle made only of such strokes gets no patch).
func pen_event(kind: String, stroke: int, pos: Vector3 = Vector3.ZERO, pressure: float = 0.5,
		boundary: bool = false) -> void:
	pen_queue.append({"kind": kind, "stroke": stroke, "pos": pos, "pressure": pressure, "boundary": boundary})

func pen_finish() -> void:
	pen_finished = true

func status() -> String:
	var s := "%s" % state
	if state == "FAILED":
		s += "(%s)" % reason
	if not fixtures.is_empty():
		s += " FIXTURE:" + ",".join(fixtures)
	s += " t=%.1fs" % ((Time.get_ticks_msec() - _run_t0) / 1000.0 if _run_t0 > 0 else 0.0)
	if state == "FIT_RUN" and fit != null and fit.busy():
		s += " " + fit.busy_text()
	if state == "DRAPE_COLLECT" and drape != null:
		s += " " + drape.drape_status()
	return s

func summary() -> Dictionary:
	var d := {"state": state, "reason": reason, "fixtures": fixtures, "records": records,
			"wall_s": (Time.get_ticks_msec() - _run_t0) / 1000.0}
	d["fit_mode"] = str(opts.get("fit_mode", "avbd"))
	for k in ["counts", "rings", "min_clearance", "mesh", "fit_config", "fit_begin", "fit_phases", "fit_avbd", "check",
			"check_control", "drape", "drape_input", "drape_setup", "drape_body", "capsules", "pins"]:
		if data.has(k):
			d[k] = data[k]
	return d

# --- the machine -------------------------------------------------------------------------

func _process(_dt: float) -> void:
	if state in TERMINAL:
		return
	_frames += 1
	_heartbeat()
	var first := _first
	_first = false
	match state:
		"INFER": _infer()
		"RIG": _rig()
		"AUTHOR": _author(first)
		"MESH": _mesh(first)
		"FIT_BEGIN": _fit_begin(first)
		"FIT_RUN": _fit_run(first)
		"FIT_READ": _fit_read()
		"CHECK": _check()
		"DRAPE": _drape()
		"DRAPE_COLLECT": _drape_collect()

# A heartbeat while one guest call runs for minutes (a fit phase is one vmcall;
# nothing else is written meanwhile). Every HEARTBEAT_S seconds of a state, one
# progress line: the state, its age, the stage's in-flight call and its age, the
# last fit phase seen, and the guest heap (a host-side reading, no vmcall). The
# cost is one clock compare per frame and one line per HEARTBEAT_S; the gate
# writes it to the results file, and the RunPod handler forwards it as job
# progress.
const HEARTBEAT_S := 30.0
var _beat_ms := 0

func _heartbeat() -> void:
	var now := Time.get_ticks_msec()
	if now - _enter_ms < HEARTBEAT_S * 1000.0 or now - _beat_ms < HEARTBEAT_S * 1000.0:
		return
	_beat_ms = now
	var st = _stage_for(state)
	var call := ""
	if st != null and st.has_method("busy") and st.busy():
		var p: Dictionary = st.poll()
		call = "%s %.0f s" % [str(p.get("call", "")), float(p.get("host_ms", 0)) / 1000.0]
	var last := ""
	if data.has("fit_phases") and not data.fit_phases.is_empty():
		last = " | last " + str(data.fit_phases[-1]).left(60)
	progress.emit("HEARTBEAT %s t=%.0f s%s heap %s%s" % [state, (now - _enter_ms) / 1000.0,
			(" | " + call) if call != "" else "", _fmt_heap(st.heap() if st != null else -1), last])

func _fmt_heap(b: int) -> String:
	return "-" if b < 0 else "%.1f MiB" % (b / 1048576.0)

func _stage_for(s: String):
	match s:
		"INFER", "RIG": return infer
		"AUTHOR", "MESH": return curvenet
		"FIT_BEGIN", "FIT_RUN", "FIT_READ": return drape if _avbd() else fit
		"CHECK": return fit
		"DRAPE", "DRAPE_COLLECT": return drape
	return null

func _close_record() -> void:
	if state in TERMINAL:
		return
	var st = _stage_for(state)
	var rec := {
		"state": state,
		"ms": Time.get_ticks_msec() - _enter_ms,
		"frames": _frames,
		"vm_ms": (st.take_vm_us() / 1000.0) if st != null else 0.0,
		"heap": st.heap() if st != null else -1,
		"fixture": _note.begins_with("FIXTURE"),
		"note": _note,
	}
	records.append(rec)
	state_changed.emit(state, rec)

func _goto(next: String, note: String = "") -> void:
	if note != "":
		_note = note
	_close_record()
	if opts.get("stop_after", "") != "" and state == opts.stop_after and next != "FAILED":
		next = "DONE"
	state = next
	_enter_ms = Time.get_ticks_msec()
	_frames = 0
	_first = true
	_note = ""
	if next in ["DONE", "FAILED"]:
		state_changed.emit(next, {"state": next, "reason": reason})

func _fail(why: String) -> void:
	reason = "%s: %s" % [state, why]
	_note = "FAILED " + why
	_goto("FAILED")

func _allowed(key: String) -> bool:
	return opts.allow_fixture.has(key)

# "real" when the stage can run, "fixture" when it cannot and the run allows
# its fixture, "" after failing the run.
func _mode(key: String, stage, missing: String) -> String:
	if opts.force_fixture.has(key):
		if not fixtures.has(key):
			fixtures.append(key)
		return "fixture"
	if missing == "":
		return "real"
	if _allowed(key):
		if not fixtures.has(key):
			fixtures.append(key)
		return "fixture"
	_fail("%s missing (%s)" % [key, missing])
	return ""

func _missing(stage) -> String:
	if stage == null:
		return "no stage node"
	return "" if stage.available() else stage.reason

# --- INFER / RIG ---------------------------------------------------------------------------

func _infer() -> void:
	var m := _mode("infer", infer, _missing(infer) if _missing(infer) != "" else "infer.elf has no pipeline path yet")
	if m == "":
		return
	var b: Dictionary = infer.body_fixture()
	if b.has("error"):
		_fail(b.error)
		return
	data.body_v = b.vertices
	data.body_f = b.triangles
	body_ready.emit(b.vertices, b.triangles)
	_goto("RIG", "%s: %d v, %d f" % [b.source, b.vertices.size() / 3, b.triangles.size() / 3])

func _rig() -> void:
	var m := _mode("rig", infer, _missing(infer) if _missing(infer) != "" else "infer.elf has no rig path yet")
	if m == "":
		return
	var r: Dictionary = infer.rig_fixture()
	if r.has("error") and r.error != "":
		_fail(r.error)
		return
	data.joints = r.joints
	data.bones = r.bones
	skeleton_ready.emit(r.joints, r.bones)
	_goto("AUTHOR", "%s: 15 joints, map %s" % [r.source, str(Array(r.map))])

# --- AUTHOR / MESH -------------------------------------------------------------------------

func _author(first: bool) -> void:
	if first:
		var m := _mode("curvenet", curvenet, _missing(curvenet))
		if m == "":
			return
		if m == "fixture":
			var g: Dictionary = infer.garment_fixture()
			if g.has("error"):
				_fail(g.error)
				return
			data.garment = {"vertices": g.vertices, "triangles": g.triangles, "source_joints": g.source_joints,
					"nofit": g.nofit, "loops": MeshTopo.boundary_loops(g.triangles)}
			data.counts = {"fixture": true}
			_goto("MESH", g.source)
			return
		var src := PenSource.make(data.body_v, data.joints, {"drop_seam": opts.drop_seam, "closed_rings": opts.closed_rings,
				"no_boundary": opts.no_boundary})
		if src.error != "":
			_fail("pen source: " + src.error)
			return
		data.rings = {"waist": _ring_text(src.waist), "hem": _ring_text(src.hem)}
		data.min_clearance = "%.4f m after growing both rings by %.4f m (the rings alone: %.4f m)" % [src.min_clearance,
				src.grow, src.clearance_before_grow]
		data.expected = src.expected
		strokes_ready.emit(src.strokes)
		var r0: String = curvenet.reset()
		var r1: String = curvenet.set_body(data.body_v, data.body_f)
		if r0.begins_with("FAIL") or r1.begins_with("FAIL"):
			_fail("curvenet setup: %s | %s" % [r0, r1])
			return
		data.pen_ends = []
		if opts.pen == "scripted" and not pen_external:
			pen_queue = src.events.duplicate()
			pen_finished = true
		elif opts.pen == "scripted":
			pass # the bridge replays the same source, with its visuals
		return
	var n := 0
	while not pen_queue.is_empty() and n < PEN_EVENTS_PER_FRAME:
		var e: Dictionary = pen_queue.pop_front()
		n += 1
		match e.kind:
			"begin":
				var bm: String = curvenet.set_param("boundary", 1.0 if e.get("boundary", false) else 0.0)
				if bm.begins_with("FAIL"):
					_fail("set_param boundary: " + bm)
					return
				var id: int = curvenet.pen_begin_at(e.pos, e.pressure)
				if id < 0:
					_fail("pen_begin refused stroke %d at %s" % [e.stroke, str(e.pos)])
					return
				_stroke_ids[e.stroke] = id
			"point":
				curvenet.pen_point_at(_stroke_ids.get(e.stroke, -1), e.pos, e.pressure)
			"end":
				var r: String = curvenet.pen_end_raw(_stroke_ids.get(e.stroke, -1))
				data.pen_ends.append(r)
				if r.begins_with("FAIL"):
					_fail("pen_end stroke %d: %s" % [e.stroke, r])
					return
		if e.kind == "end":
			break # at most one stroke ends per frame
	if not pen_queue.is_empty() or not pen_finished:
		return
	var last: String = data.pen_ends[-1] if not data.pen_ends.is_empty() else ""
	var cb: String = curvenet.build_curvenet()
	var kw = curvenet.knots()
	var knots: Array = MeshWire.knots(kw) if typeof(kw) == TYPE_PACKED_FLOAT32_ARRAY else []
	var degrees := []
	var kpos := []
	for k in knots:
		degrees.append(k.degree)
		kpos.append("(%.3f, %.3f, %.3f)" % [k.position.x, k.position.y, k.position.z])
	var patches: int = curvenet.patches()
	data.counts = {
		"strokes": data.pen_ends.size(),
		"cycles": _kv(last, "cycles"),
		"openings": _kv(last, "openings"),
		"edges": _kv(last, "edges"),
		"nodes": _kv(last, "nodes"),
		"patches": patches,
		"curves": _kv(cb, "curves"),
		"knots": _kv(cb, "knots"),
		"knot_degrees": degrees,
		"knot_positions": kpos,
		"pen_ends": data.pen_ends,
		"last_pen_end": last,
		"curvenet_build": cb,
	}
	_goto("MESH", "strokes %d cycles %d openings %d patches %d curves %d knots %d degrees %s" % [data.pen_ends.size(),
			data.counts.cycles, data.counts.openings, patches, data.counts.curves, data.counts.knots, str(degrees)])

func _mesh(first: bool) -> void:
	if data.has("garment"): # the curvenet fixture
		_mesh_done(data.garment, "FIXTURE garment")
		return
	if first:
		var r: String = curvenet.start_mesh_build(opts.mesh_edge, opts.weld_eps)
		if not r.begins_with("STARTED"):
			_fail("mesh_build: " + r)
		return
	var p: Dictionary = curvenet.poll()
	if not p.done:
		return
	var r := str(p.result)
	data.mesh = {"mesh_build": r, "host_ms": p.host_ms}
	if not r.begins_with("ok"):
		_fail("mesh_build: " + r)
		return
	var a: Dictionary = curvenet.mesh_arrays()
	if a.has("error"):
		_fail(a.error)
		return
	_mesh_done({"vertices": a.vertices, "triangles": a.triangles, "loops": a.loops,
			"source_joints": data.joints, "nofit": PackedInt32Array()}, r)

func _mesh_done(g: Dictionary, note: String) -> void:
	var nv: int = g.vertices.size() / 3
	var nf: int = g.triangles.size() / 3
	var comps := MeshTopo.components(nv, g.triangles)
	var loops: Array = g.loops
	data.garment = g
	data.mesh = data.get("mesh", {})
	data.mesh.merge({"vertices": nv, "triangles": nf, "loops": loops.size(), "components": comps,
			"finite": MeshTopo.all_finite(g.vertices)})
	garment_ready.emit(g.vertices, g.triangles, "mesh")
	# A skirt is one tube: one component, two boundary loops (waist, hem).
	if nf == 0 or comps != 1 or loops.size() != 2 or not data.mesh.finite:
		_fail("not a skirt tube: %d triangles, %d components, %d boundary loops (want >0, 1, 2)%s" % [nf, comps,
				loops.size(), "" if data.mesh.finite else ", non-finite vertices"])
		return
	_goto("FIT_BEGIN", "%s | %d v %d f %d loops" % [note, nv, nf, loops.size()])

# --- FIT --------------------------------------------------------------------------------------

func _avbd() -> bool:
	return str(opts.get("fit_mode", "avbd")) == "avbd"

func _fit_begin(first: bool) -> void:
	var g: Dictionary = data.garment
	if first:
		var m := _mode("fit", fit, _missing(fit))
		if m == "":
			return
		if _avbd():
			_fit_begin_avbd(m)
			return
		if m == "fixture":
			data.fit_fixture = true
			if str(opts.fit_from) != "":
				var fo := ObjIO.read(str(opts.fit_from))
				if fo.has("error") or fo.v.size() != g.vertices.size():
					_fail("fit_from %s: %s" % [opts.fit_from, fo.get("error", "%d floats, the garment %d" % [fo.v.size(), g.vertices.size()])])
					return
				data.fitted = fo.v
				_goto("FIT_READ", "FIXTURE fit: vertices from %s" % str(opts.fit_from).get_file())
				return
			data.fitted = _similarity_retarget(g.vertices, g.source_joints, data.joints)
			_goto("FIT_READ", "FIXTURE fit: similarity from the garment skeleton to the body skeleton")
			return
		var e := _fit_elf_begin()
		if e != "":
			_fail(e)
		return
	var p: Dictionary = fit.poll()
	if not p.done:
		return
	var r := str(p.result)
	data.fit_begin = "host_ms=%d %s" % [p.host_ms, r]
	if not r.begins_with("OK begin"):
		_fail(r)
		return
	data.fit_phases = []
	_goto("FIT_RUN", r)

# fit.elf's problem handed over and fit_begin started on its worker: "" or
# the failure. The polyfem fit's first step; with for_check (avbd mode) the
# setup CHECK needs: fit_check_intersections wants the driver's normalisation
# and collision mesh, and tests the garment against the avatar where the
# current phase's alpha puts it (fit_driver.cpp check_intersections_with).
# At phase 0 that is cloth-fit's start avatar, the body collapsed onto its
# skeleton (shrink_normal_distance 0, optimize.cpp:1280), which no garment
# can hit: the pushed-vertex control answers "none" against it. With
# shrink_normal_distance 1e-6 the start avatar is the real body 1e-6 solve
# units (0.65 um) inside its own skin, so the phase-0 check is the loop's
# check without the 627 s of phases; the fit's own start-state refusal
# then also sees the real body (the authored skirt clears it by 1 cm).
func _fit_elf_begin(for_check: bool = false) -> String:
	var g: Dictionary = data.garment
	var cfg: String = infer.fit_config_text()
	if cfg.is_empty():
		return "fixtures/foxgirl/fit_config.json unreadable"
	var fc := _fit_budget(cfg, for_check)
	if fc.has("error"):
		return fc.error
	cfg = fc.text
	data.fit_config = fc.note
	var e: String = fit.setup(data.body_v, data.body_f, g.source_joints, data.joints, data.bones, g.vertices,
			g.triangles, g.nofit, cfg)
	if e != "":
		return e
	var r: String = fit.start_begin()
	if not r.begins_with("STARTED"):
		return r
	return ""

# FIT(avbd), Cut 6d. fit_mode: "real" runs fit.elf's begin on its worker for
# CHECK; "fixture" (fit.elf missing and allowed, or forced) leaves CHECK
# unmeasured. The fit itself is drape.elf's, so a missing drape fails the run.
func _fit_begin_avbd(fit_elf_mode: String) -> void:
	var g: Dictionary = data.garment
	var miss := _missing(drape)
	if miss == "":
		miss = drape.fit_api_missing()
	if miss != "":
		_fail("fit_mode avbd: drape %s" % miss)
		return
	data.fit_check_fixture = fit_elf_mode == "fixture"
	var start := _similarity_retarget(g.vertices, g.source_joints, data.joints)
	var fit_verts := _fit_vertices(g.vertices.size() / 3, g.nofit)
	var anchor := _waist_loop(start, g.triangles)
	var p: Dictionary = drape.FIT_AVBD
	var r: Dictionary = drape.fit_avbd_start(start, g.triangles, fit_verts, anchor, data.body_v, data.body_f, p,
			opts.drape_scale, opts.drape_mu, opts.drape_backend)
	for s in r.steps:
		if str(s).begins_with("FAIL") or str(s).begins_with("BUSY"):
			_fail("fit(avbd) setup: " + str(s))
			return
	if not str(r.queued).begins_with("QUEUED"):
		_fail("fit(avbd): " + str(r.queued))
		return
	data.fit_avbd = {"setting": p, "setup": r.steps, "queued": r.queued, "fit_vertices": fit_verts.size(),
			"nofit": g.nofit.size(), "anchor": anchor.size(), "retarget": "similarity from the garment skeleton to the body skeleton",
			"scale": opts.drape_scale, "mu": opts.drape_mu}
	var elf := "not run (fit FIXTURE)"
	if fit_elf_mode == "real":
		var e := _fit_elf_begin(true)
		if e != "":
			_fail("fit.elf for CHECK: " + e)
			return
		elf = "fit_begin STARTED on the worker (for CHECK)"
	_goto("FIT_RUN", "FIT(avbd): %s | %d fit vertices (%d nofit), k %s gap %s iters %d steps <= %d tol %s refresh %d kBend %s | fit.elf %s" % [
			r.queued, fit_verts.size(), g.nofit.size(), str(p.k), str(p.gap), p.iters, p.steps, str(p.tol), p.refresh,
			str(p.kBend), elf])

# The waist loop (the boundary loop with the highest mean y, the drape's pin
# loop): the similarity rest update's anchor.
static func _waist_loop(v: PackedFloat32Array, tris: PackedInt32Array) -> PackedInt32Array:
	var loops := MeshTopo.boundary_loops(tris)
	var wi := MeshTopo.highest_loop(v, loops)
	return loops[wi] if wi >= 0 else PackedInt32Array()

# Every garment vertex not in the nofit set (the loop's authored garment has
# none; the LCL fixture lists 2005 of 2682).
static func _fit_vertices(n: int, nofit: PackedInt32Array) -> PackedInt32Array:
	var skip := {}
	for i in nofit:
		skip[i] = true
	var out := PackedInt32Array()
	for i in n:
		if not skip.has(i):
			out.append(i)
	return out

func _fit_run(first: bool) -> void:
	if _avbd():
		var st: String = drape.drape_status()
		if st.begins_with("RUNNING"):
			data.fit_avbd.last_running = st
			return
		if st.begins_with("FAIL") or st.find("DONE fit") < 0:
			_fail("fit(avbd): " + st)
			return
		data.fit_avbd.result = st
		data.fit_avbd.ticks = drape.ticks
		data.fit_avbd.result_full = drape.drape_result().split("\n")[0]
		_goto("FIT_READ", st)
		return
	if not first:
		var p: Dictionary = fit.poll()
		if not p.done:
			return
		var r := str(p.result)
		data.fit_phases.append("host_ms=%d %s" % [p.host_ms, r])
		progress.emit("fit_step: " + data.fit_phases[-1])
		if r.begins_with("FAIL"):
			_fail(r)
			return
	var s: String = fit.status_raw()
	if s.find(" FAILED") >= 0:
		_fail(s)
		return
	if s.find(" done") >= 0:
		_goto("FIT_READ", "%d phases | %s" % [data.fit_phases.size(), s])
		return
	var r2: String = fit.start_step()
	if not r2.begins_with("STARTED"):
		_fail(r2)

func _fit_read() -> void:
	if _avbd():
		var pos: PackedFloat32Array = drape.drape_positions()
		data.fitted = _scaled(pos, 1.0 / float(opts.drape_scale))
		data.fit_avbd.restore = drape.fit_avbd_restore()
	elif not data.get("fit_fixture", false):
		var v = fit.result_vertices()
		if typeof(v) != TYPE_PACKED_FLOAT32_ARRAY:
			_fail("fit_result_vertices: " + str(v))
			return
		data.fitted = v
	var fv: PackedFloat32Array = data.fitted
	if fv.size() != data.garment.vertices.size():
		_fail("fitted garment has %d vertices, the mesh %d" % [fv.size() / 3, data.garment.vertices.size() / 3])
		return
	if not MeshTopo.all_finite(fv):
		_fail("fitted garment has non-finite vertices")
		return
	garment_ready.emit(fv, data.garment.triangles, "fit")
	var note := "%d v" % (fv.size() / 3)
	if data.get("fit_fixture", false):
		note = "FIXTURE fit"
	elif _avbd():
		note = "FIT(avbd) %d v" % (fv.size() / 3)
	_goto("CHECK", note)

func _check() -> void:
	if data.get("fit_fixture", false) or data.get("fit_check_fixture", false):
		data.check = "not run (fit FIXTURE: fit_check_intersections needs fit.elf)"
		_goto("DRAPE", "FIXTURE check skipped")
		return
	var over := PackedFloat32Array() # the solver's own state (the polyfem fit)
	if _avbd():
		# fit.elf's begin, started in FIT_BEGIN on its worker: the check needs
		# its normalisation and collision mesh. The avbd result goes as the
		# override (the solver's own garment is the unfitted one).
		if fit.busy():
			return
		if not data.has("fit_begin"):
			var p: Dictionary = fit.poll()
			var r0 := str(p.result)
			data.fit_begin = "host_ms=%d %s" % [p.host_ms, r0]
			if not r0.begins_with("OK begin"):
				_fail("fit.elf begin for CHECK: " + r0)
				return
		over = data.fitted
	var pushed := _push_vertex(data.fitted)
	var ctrl: String = fit.check_intersections(pushed)
	data.check_control = ctrl
	var r: String = fit.check_intersections(pushed if opts.push_vertex else over)
	data.check = r
	if r.begins_with("OK none"):
		_goto("DRAPE", "%s | control (one vertex pushed inside): %s" % [r, ctrl])
		return
	if r.find("INTERSECTS") >= 0:
		_fail("INTERSECTS %s" % r)
		return
	_fail(r)

# The garment vertex nearest the pelvis joint, moved onto the pelvis joint
# (inside the body): its edges must cross the body surface.
func _push_vertex(v: PackedFloat32Array) -> PackedFloat32Array:
	var out := v.duplicate()
	var j: PackedFloat32Array = data.joints
	var pel := Vector3(j[0], j[1], j[2])
	var best := 0
	var bd := INF
	for i in range(0, v.size() - 2, 3):
		var d := Vector3(v[i], v[i + 1], v[i + 2]).distance_squared_to(pel)
		if d < bd:
			bd = d
			best = i
	out[best] = pel.x
	out[best + 1] = pel.y
	out[best + 2] = pel.z
	data.pushed_vertex = best / 3
	return out

# --- DRAPE ----------------------------------------------------------------------------------

func _drape() -> void:
	var m := _mode("drape", drape, _missing(drape) if _missing(drape) != "" else drape.drape_api_missing())
	if m == "":
		return
	var g: Dictionary = data.garment
	var fv: PackedFloat32Array = data.fitted
	var loops := MeshTopo.boundary_loops(g.triangles)
	var wi := MeshTopo.highest_loop(fv, loops)
	var pins: PackedInt32Array = loops[wi] if wi >= 0 else PackedInt32Array()
	data.pins = {"loop": wi, "count": pins.size(), "mean_y": MeshTopo.mean_y(fv, pins) if wi >= 0 else 0.0}
	data.capsules = _capsules(data.body_v, data.joints, data.bones)
	data.drape_input = MeshTopo.quality(fv, g.triangles)
	if m == "fixture":
		data.drape = "not run (drape FIXTURE)"
		_goto("DONE", "FIXTURE drape skipped; the fitted garment is shown undraped")
		return
	var s: float = opts.drape_scale
	var steps := [
		drape.drape_open(opts.drape_backend),
		drape.drape_primitive("clear", PackedFloat32Array()),
	]
	var body: String = str(opts.drape_body) if opts.drape_capsules else "none"
	if body == "mesh":
		steps.append(drape.drape_primitive_mesh(_scaled(data.body_v, s), data.body_f,
				PackedFloat32Array([0.1, opts.drape_mu, 0.1, 1.0])))
	for c in (data.capsules if body == "capsules" else []):
		var b: Vector3 = c.bottom * s
		var ax: Vector3 = c.axis
		steps.append(drape.drape_primitive("capsule", PackedFloat32Array([b.x, b.y, b.z, ax.x, ax.y, ax.z,
				c.radius * s, c.length * s, opts.drape_mu])))
	steps.append(drape.drape_config("gravityY", -9.8 * s))
	steps.append(drape.drape_scene_mesh(_scaled(fv, s), g.triangles, pins, PackedFloat32Array()))
	for r in steps:
		if str(r).begins_with("FAIL") or str(r).begins_with("BUSY"):
			_fail("drape setup: " + str(r))
			return
	data.drape_setup = steps
	var q: String = drape.drape_forward(int(opts.drape_steps))
	if not q.begins_with("QUEUED"):
		_fail(q)
		return
	data.drape_body = body
	_goto("DRAPE_COLLECT", "%s | body %s%s, %d pins, scale %.1f" % [q, body,
			" (%d capsules)" % data.capsules.size() if body == "capsules" else "", pins.size(), s])

func _drape_collect() -> void:
	var st: String = drape.drape_status()
	if st.begins_with("RUNNING"):
		data.drape_last_running = st
		return
	if st.begins_with("FAIL"):
		_fail(st)
		return
	var pos: PackedFloat32Array = drape.drape_positions()
	var s: float = opts.drape_scale
	var n: int = data.garment.vertices.size()
	var finite := MeshTopo.all_finite(pos)
	data.drape = {"status": st, "last_running": data.get("drape_last_running", ""), "ticks": drape.ticks,
			"vertices": pos.size() / 3, "finite": finite}
	if pos.size() != n or not finite:
		_fail("drape positions: %d of %d floats, finite=%s (%s)" % [pos.size(), n, finite, st])
		return
	data.draped = _scaled(pos, 1.0 / s)
	garment_ready.emit(data.draped, data.garment.triangles, "drape")
	_goto("DONE", "%s | %d finite vertices after %s" % [st, pos.size() / 3, data.get("drape_last_running", "?")])

# Capsules along the skeleton's bones. Each body vertex goes to its nearest
# bone; a bone's radius is the median distance of its vertices, less the
# capsule's own contact offset (0.1 drape units, DiffCloth's Capsule), so the
# contact surface sits near the median skin. An approximation of the body,
# used with drape_body = "capsules" (the default is the body mesh collider).
func _capsules(body_v: PackedFloat32Array, joints: PackedFloat32Array, bones: PackedInt32Array) -> Array:
	var segs := []
	for b in range(0, bones.size() - 1, 2):
		var a := Vector3(joints[3 * bones[b]], joints[3 * bones[b] + 1], joints[3 * bones[b] + 2])
		var c := Vector3(joints[3 * bones[b + 1]], joints[3 * bones[b + 1] + 1], joints[3 * bones[b + 1] + 2])
		if a.y > c.y:
			var t := a
			a = c
			c = t
		segs.append([a, c, []])
	for i in range(0, body_v.size() - 2, 3):
		var p := Vector3(body_v[i], body_v[i + 1], body_v[i + 2])
		var best := -1
		var bd := INF
		for k in segs.size():
			var d := p.distance_to(Geometry3D.get_closest_point_to_segment(p, segs[k][0], segs[k][1]))
			if d < bd:
				bd = d
				best = k
		segs[best][2].append(bd)
	var out := []
	var off := 0.1 / float(opts.get("drape_scale", 10.0))
	for sg in segs:
		var ds: Array = sg[2]
		if ds.is_empty():
			continue
		ds.sort()
		var med: float = ds[ds.size() / 2]
		var axis: Vector3 = sg[1] - sg[0]
		if axis.length() < 1e-6:
			continue
		out.append({"bottom": sg[0], "axis": axis.normalized(), "length": axis.length(),
				"radius": maxf(0.005, med - off), "median_skin": med, "vertices": ds.size()})
	return out

# --- helpers ---------------------------------------------------------------------------------

# The fit budget as text edits on the setup JSON: a GDScript JSON round trip
# would turn 2 into 2.0, which the spec's integer fields refuse. Each edit
# must match exactly one literal, so a changed fixture fails loudly instead of
# fitting with the wrong budget. The CCD's max_iterations (200) is left alone.
func _fit_budget(cfg: String, for_check: bool = false) -> Dictionary:
	var edits := []
	if for_check:
		# The start avatar is the real body, not the collapse (_fit_elf_begin).
		edits.append([r'^(\s*[{])', '"shrink_normal_distance": 1e-6, '])
	var inc: int = int(opts.get("fit_incremental_steps", -1))
	var cap: int = int(opts.get("fit_max_iterations", -1))
	if inc > 0:
		edits.append([r'("incremental_steps"\s*:\s*)\d+', str(inc)])
	if cap > 0:
		# augmented_lagrangian.nonlinear.max_iterations, then solver.nonlinear.max_iterations
		edits.append([r'("grad_norm"\s*:\s*1,\s*"max_iterations"\s*:\s*)\d+', str(cap)])
		edits.append([r'("min_step_size"\s*:\s*[0-9.e+-]+\s*[}],\s*"max_iterations"\s*:\s*)\d+', str(cap)])
	var gn: float = float(opts.get("fit_grad_norm", -1.0))
	if gn > 0.0:
		# solver.nonlinear.grad_norm (the reduced solve's stop; the AL's own is 1)
		edits.append([r'("grad_norm"\s*:\s*)0\.01\b', str(gn)])
	if bool(opts.get("fit_force_psd", false)):
		# solver.nonlinear.Newton.force_psd_projection (an insertion: the key is
		# not in fit_config.json). Both solves get it: the driver's init_args
		# merges augmented_lagrangian.nonlinear over solver.nonlinear
		# (optimize.cpp:1418-1428), so the AL's Newton inherits it.
		edits.append([r'("nonlinear"\s*:\s*[{]\s*"Newton"\s*:\s*[{])', '"force_psd_projection": true, '])
	var notes := []
	for e in edits:
		var re := RegEx.new()
		re.compile(e[0])
		var hits := re.search_all(cfg)
		if hits.size() != 1:
			return {"error": "fit budget: %d matches for /%s/ in fit_config.json (want 1)" % [hits.size(), e[0]]}
		var hit := hits[0].get_string().replace("\n", " ").replace("\r", "").replace("\t", "")
		notes.append("%s -> %s" % [" ".join(hit.split(" ", false)), e[1]])
		cfg = re.sub(cfg, "${1}" + str(e[1]))
	return {"text": cfg, "note": "; ".join(notes) if not notes.is_empty() else "fit_config.json as is"}

# cloth-fit's normalisation (fit_driver.cpp, optimize.cpp:1349-1369): the
# source skeleton centred and scaled to the target's bounding-box size, then
# centred on the target skeleton. Identity when the skeletons are equal.
func _similarity_retarget(v: PackedFloat32Array, src: PackedFloat32Array, tgt: PackedFloat32Array) -> PackedFloat32Array:
	var cs := _centroid(src)
	var ct := _centroid(tgt)
	var k := _bbox_max(tgt) / maxf(1e-12, _bbox_max(src))
	var out := PackedFloat32Array()
	out.resize(v.size())
	for i in range(0, v.size() - 2, 3):
		var p := (Vector3(v[i], v[i + 1], v[i + 2]) - cs) * k + ct
		out[i] = p.x
		out[i + 1] = p.y
		out[i + 2] = p.z
	return out

static func _centroid(p: PackedFloat32Array) -> Vector3:
	var c := Vector3.ZERO
	for i in range(0, p.size() - 2, 3):
		c += Vector3(p[i], p[i + 1], p[i + 2])
	return c / maxf(1.0, p.size() / 3)

static func _bbox_max(p: PackedFloat32Array) -> float:
	var box := AABB(Vector3(p[0], p[1], p[2]), Vector3.ZERO)
	for i in range(0, p.size() - 2, 3):
		box = box.expand(Vector3(p[i], p[i + 1], p[i + 2]))
	return maxf(box.size.x, maxf(box.size.y, box.size.z))

static func _scaled(v: PackedFloat32Array, s: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(v.size())
	for i in v.size():
		out[i] = v[i] * s
	return out

static func _kv(text: String, key: String) -> int:
	var at := text.find(key + "=")
	if at < 0:
		return -1
	var s := text.substr(at + key.length() + 1)
	var end := 0
	while end < s.length() and (s[end] == "-" or (s[end] >= "0" and s[end] <= "9")):
		end += 1
	return int(s.substr(0, end)) if end > 0 else -1

static func _ring_text(r: Dictionary) -> String:
	return "centre %s radius %.4f m (body %.4f m + 0.01, %d vertices)" % [str(r.center), r.radius, r.body_radius, r.vertices]
