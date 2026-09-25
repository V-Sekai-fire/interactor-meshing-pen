# The Skateboard's simulator implementation: the pen driven through OpenXR by
# OXRSys, with tools/replay_oxrsys.py in place of the simulator's hand.
#
#   XR_RUNTIME_JSON=<oxrsys build>/runtime/oxrsys-runtime.json \
#     godot --path . --rendering-driver metal --xr-mode on --script tools/gate_replay.gd -- \
#       --plan=<plan.json> --out=<results.txt> [--wallclock=600] [--frame-port=9950] [--render-scale=1.0]
#   python3 tools/replay_oxrsys.py <plan.json>      (started alongside)
#
# The pipeline runs with pen = "xr" and stops after MESH, so every stroke comes
# from xr-grid's SketchTool on the right controller: OXRSys tracking packet ->
# OpenXR pose and trigger -> hand.gd -> SketchTool.active -> xr/pen_bridge.gd
# -> curvenet.elf. Boundary mode toggles on the thumbstick click, and the
# menu button ends the authoring, as a person would.
#
# The strokes are the pipeline's own scripted skirt (xr/pen_source_scripted.gd,
# via strokes_ready), in the Body frame. The replay client first holds the
# right controller at CALIB (tracking space); this script reads where that
# lands in the XROrigin frame, and writes the plan: every point mapped Body ->
# XROrigin, minus that offset, so the runtime's reference-space origin cancels.
#
# Each frame this script sends its frame number to the replay client (UDP,
# --frame-port), which counts its holds in those frames, so the strokes survive
# any frame rate. --render-scale sets the root viewport's 3D scale: the gate
# needs poses and strokes, not pixels, and a software rasterizer pays per pixel.
#
# PASS: the pen made as many strokes as the plan has, and curvenet closed the
# full skirt's 2 cycles with 2 openings (Gate 8's pen criteria).
extends SceneTree

const SCENE := "res://xr_main.tscn"
const CALIB := Vector3(0.0, 1.2, -0.3)
const FULL_SKIRT_CYCLES := 2

var _args := {}
var _out: FileAccess
var _t0 := 0
var _wall_s := 600.0
var _main: Node = null
var _phase := "boot"
var _frames := 0
var _strokes: Array = []
var _plan_path := ""
var _calib_frames := 0
var _frame_peer := PacketPeerUDP.new()

func _say(s: String) -> void:
	print(s)
	if _out != null:
		_out.store_line(s)
		_out.flush()

func _arg(k: String, d: String = "") -> String:
	return _args.get(k, d)

func _initialize() -> void:
	_t0 = Time.get_ticks_msec()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv := a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	_wall_s = float(_arg("wallclock", "600"))
	_frame_peer.connect_to_host("127.0.0.1", int(_arg("frame-port", "9950")))
	root.scaling_3d_scale = clampf(float(_arg("render-scale", "1.0")), 0.25, 2.0)
	_plan_path = _arg("plan", OS.get_user_data_dir().path_join("replay_plan.json"))
	var out := _arg("out", OS.get_user_data_dir().path_join("replay_results.txt"))
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	_out = FileAccess.open(out, FileAccess.WRITE)
	DirAccess.remove_absolute(_plan_path)
	_say("gate_replay: Godot %s, XR_RUNTIME_JSON %s" % [Engine.get_version_info().string,
			OS.get_environment("XR_RUNTIME_JSON").get_file()])
	var ps: PackedScene = load(SCENE)
	if ps == null:
		_finish("FAIL (cannot load %s)" % SCENE)
		return
	_main = ps.instantiate()
	root.add_child(_main)
	_phase = "wait"

func _process(_dt: float) -> bool:
	_frames += 1
	_frame_peer.put_packet(str(_frames).to_ascii_buffer())
	if _phase == "done":
		return false
	if (Time.get_ticks_msec() - _t0) / 1000.0 > _wall_s:
		_finish("FAIL (wall clock %.0f s in %s: %s)" % [_wall_s, _phase,
				_main.dress_on_status() if _main != null and _main.get("pipeline") != null else "-"])
		return false
	match _phase:
		"wait":
			if _frames < 5:
				return false
			var w = _main.get_node_or_null("World")
			if w == null or not w.xr_on:
				_finish("FAIL (no XR session: is XR_RUNTIME_JSON set and --xr-mode on?)")
				return false
			_say("view: XR %s" % str(w.xr_runtime))
			_main.pipeline.strokes_ready.connect(func(s: Array): _strokes = s)
			_main.pipeline.state_changed.connect(func(st: String, _rec: Dictionary): _say("STATE " + st))
			var r: String = _main.dress_on_run_opts({"pen": "xr", "allow_fixture": "infer,rig", "stop_after": "MESH"})
			_say("run: " + r)
			if not r.begins_with("STARTED"):
				_finish("FAIL (run did not start)")
				return false
			_phase = "strokes"
		"strokes":
			if not _strokes.is_empty():
				_phase = "calib"
		"calib":
			# The client holds the right controller at CALIB; wait until the
			# pose is tracked and has stayed put for a few frames.
			var hand: XRController3D = _main.get_node("World/XROrigin3D/hand_right")
			if hand.get_has_tracking_data() and hand.position.length() > 0.0:
				_calib_frames += 1
			if _calib_frames >= 30:
				_write_plan(hand.position - CALIB)
				_phase = "author"
		"author":
			var st: String = _main.pipeline.state
			if st == "DONE" or st == "FAILED":
				_evaluate()
	return false

func _write_plan(offset: Vector3) -> void:
	var origin: Node3D = _main.get_node("World/XROrigin3D")
	var body: Node3D = _main.get_node("World/Body")
	var to_origin := origin.global_transform.affine_inverse() * body.global_transform
	var plan := {"calib": [CALIB.x, CALIB.y, CALIB.z], "strokes": []}
	for s in _strokes:
		var pts := []
		for p in s.points:
			var q: Vector3 = to_origin * p - offset
			pts.append([q.x, q.y, q.z])
		plan.strokes.append({"name": s.name, "boundary": bool(s.boundary), "points": pts})
	var f := FileAccess.open(_plan_path + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(plan))
	f.close()
	DirAccess.rename_absolute(_plan_path + ".tmp", _plan_path)
	_say("plan: %d strokes, offset %s (the runtime's origin in XROrigin space), %s" % [_strokes.size(), str(offset), _plan_path])

func _evaluate() -> void:
	var p = _main.pipeline
	var c: Dictionary = p.data.get("counts", {})
	var strokes := int(c.get("strokes", -1))
	var cycles := int(c.get("cycles", -1))
	var openings := int(c.get("openings", -1))
	_say("pen: strokes %d (plan %d) cycles %d openings %d, state %s, bridge strokes_sent %d" % [strokes, _strokes.size(),
			cycles, openings, p.state, int(_main.get_node("World/PenBridge").strokes_sent) if _main.has_node("World/PenBridge") else -1])
	var ok := strokes == _strokes.size() and cycles == FULL_SKIRT_CYCLES and openings == 2
	_finish("PASS" if ok else "FAIL")

func _finish(verdict: String) -> void:
	_say("RESULT: " + verdict)
	_phase = "done"
	if _out != null:
		_out.close()
		_out = null
	quit(0 if verdict == "PASS" else 1)
