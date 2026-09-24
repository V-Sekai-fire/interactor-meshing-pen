# pen_bridge -- xr-grid's SketchTool -> the pipeline's pen events (and so
# curvenet.elf's pen_begin / pen_point / pen_end), in the Body's local frame.
#
# pen = "xr": each SketchTool's `active` edge is watched here, the way
# SketchTool._process watches it for SimpleSketch: rising -> begin, held ->
# point (the tool's origin in Body space; pressure = tool.pressure / 0.01,
# hand.gd's max_size), falling -> end. SketchTool keeps drawing its own
# ribbon into Body/strokes. strokes.gd is not used: its just_pressed is
# is_zero_approx(pressed) inside `if not is_zero_approx(pressed)`, always
# false, so it never starts a stroke. The authoring ends on the menu button
# of either controller, Enter on a keyboard, or Main.dress_on_author_done().
# Boundary mode (the edge of an opening: a skirt's waist and hem) toggles on
# a thumbstick click on either controller (A/B/X/Y are xr-grid's own debug
# save/load in hand.gd) or the B key; a stroke takes the mode
# it began in (curvenet captures it at pen_begin).
#
# pen = "scripted": the pipeline's strokes (xr/pen_source_scripted.gd, handed
# over by its strokes_ready signal) are replayed one stroke per frame through
# the same pen_event calls, and drawn into Body/strokes with SimpleSketch so
# the flat and VR screenshots show them. No controller is read.
extends Node

const MAX_SIZE := 0.01 # hand.gd: sketch_tool.pressure = trigger * max_size

@export var tools: Array[NodePath] = []
@export var body_path: NodePath

var pipeline = null
var body: Node3D = null
var _prev := {}
var _stroke_of := {}
var _next_stroke := 0
var _replay: Array = []
var _sketch = null
var strokes_sent := 0
var boundary_mode := false
var _by_prev := false

func attach(p) -> void:
	pipeline = p
	pipeline.pen_external = true
	pipeline.strokes_ready.connect(_on_strokes)
	body = get_node_or_null(body_path)
	var strokes_node = body.get_node_or_null("strokes") if body != null else null
	if strokes_node != null:
		# SimpleSketch (class_name in the addon), made from its path.
		var s = load("res://addons/procedural_3d_grid/core/simple_sketcher/simple_sketch.gd")
		if s != null:
			_sketch = s.new()
			_sketch.target_mesh = strokes_node.mesh

func _on_strokes(strokes: Array) -> void:
	if pipeline == null or pipeline.opts.get("pen", "scripted") != "scripted":
		return
	_replay = strokes.duplicate()
	_next_stroke = 0

func _process(_dt: float) -> void:
	if pipeline == null or pipeline.state != "AUTHOR":
		return
	if pipeline.opts.get("pen", "scripted") == "scripted":
		_replay_one()
	else:
		_forward_tools()

func _replay_one() -> void:
	if _replay.is_empty():
		return
	var st: Dictionary = _replay.pop_front()
	var pts: PackedVector3Array = st.points
	var k := _next_stroke
	_next_stroke += 1
	pipeline.pen_event("begin", k, pts[0], 0.5, bool(st.get("boundary", false)))
	for i in range(1, pts.size()):
		pipeline.pen_event("point", k, pts[i], 0.5)
	pipeline.pen_event("end", k)
	strokes_sent += 1
	if _sketch != null:
		_sketch.stroke_begin()
		for p in pts:
			_sketch.stroke_add(p, 0.008, Color(0.1, 0.2, 0.8))
		_sketch.stroke_end()
	if _replay.is_empty():
		pipeline.pen_finish()

func _forward_tools() -> void:
	if body == null:
		return
	for path in tools:
		var t = get_node_or_null(path)
		if t == null:
			continue
		var active: bool = t.active
		var was: bool = _prev.get(path, false)
		var p: Vector3 = body.to_local(t.global_transform.origin)
		var pressure := clampf(float(t.pressure) / MAX_SIZE, 0.0, 1.0)
		if active and not was:
			_stroke_of[path] = _next_stroke
			_next_stroke += 1
			pipeline.pen_event("begin", _stroke_of[path], p, pressure, boundary_mode)
		elif active and was:
			pipeline.pen_event("point", _stroke_of[path], p, pressure)
		elif was and not active:
			pipeline.pen_event("end", _stroke_of[path])
			strokes_sent += 1
		_prev[path] = active
	if Input.is_action_just_pressed("ui_accept"):
		finish()
	var by := Input.is_physical_key_pressed(KEY_B)
	for path in tools:
		var t = get_node_or_null(path)
		var hand = t.get_parent() if t != null else null
		if hand is XRController3D and hand.is_button_pressed("primary_click"):
			by = true
	if by and not _by_prev:
		boundary_mode = not boundary_mode
		print("pen: boundary mode %s" % ("on" if boundary_mode else "off"))
	_by_prev = by
	for path in tools:
		var t = get_node_or_null(path)
		var hand = t.get_parent() if t != null else null
		if hand is XRController3D and hand.is_button_pressed("menu_button"):
			finish()

func finish() -> void:
	if pipeline != null and pipeline.state == "AUTHOR" and not pipeline.pen_finished:
		# Close any stroke still held.
		for path in _prev:
			if _prev[path]:
				pipeline.pen_event("end", _stroke_of[path])
				_prev[path] = false
		pipeline.pen_finish()
