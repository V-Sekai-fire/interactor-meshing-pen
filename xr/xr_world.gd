# xr_world -- the visible half of xr_main.tscn: picks XR or flat, shows the
# pipeline's body, strokes and garment (mesh, fit, drape) under Body, and hands
# the pen bridge to the pipeline. Main (the scene root, main.gd) calls
# attach(main) once its stages exist (children are ready before parents).
#
# XR: with --xr-mode on and a runtime (XR_RUNTIME_JSON per process, never the
# system default: AGENTS.md rule 9) the OpenXR interface comes up initialised;
# then the viewport renders to it from XRCamera3D. Otherwise FlatCamera looks
# at the body; that is the flat run Gate 8 screenshots.
extends Node3D

const MeshWire := preload("res://util/mesh_wire.gd")

var xr_on := false
var xr_runtime := ""
var main = null

@onready var body: Node3D = $Body

func _ready() -> void:
	var xr := XRServer.find_interface("OpenXR")
	xr_on = xr != null and xr.is_initialized()
	if xr_on:
		get_viewport().use_xr = true
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		$XROrigin3D/XRCamera3D.current = true
		if xr.has_method("get_system_info"):
			xr_runtime = str(xr.get_system_info())
	else:
		$FlatCamera.current = true
	print("[dress-on] xr_main: %s" % ("XR on (%s)" % xr_runtime if xr_on else "flat"))

func attach(m) -> void:
	main = m
	var p = m.pipeline
	p.body_ready.connect(_on_body)
	p.garment_ready.connect(_on_garment)
	p.skeleton_ready.connect(_on_skeleton)
	var bridge = get_node_or_null("PenBridge")
	if bridge != null:
		bridge.attach(p)

func _mat(c: Color, alpha: float = 1.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(c, alpha)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

# mesh_wire's ArrayMesh with smooth normals, so the screenshot shows shape.
func _shaded(v: PackedFloat32Array, f: PackedInt32Array) -> ArrayMesh:
	var m := MeshWire.to_array_mesh(v, f)
	if m.get_surface_count() == 0:
		return m
	var st := SurfaceTool.new()
	st.create_from(m, 0)
	st.generate_normals()
	return st.commit()

func _on_body(v: PackedFloat32Array, f: PackedInt32Array) -> void:
	var mi: MeshInstance3D = body.get_node("BodyMesh")
	mi.mesh = _shaded(v, f)
	mi.material_override = _mat(Color(0.85, 0.75, 0.68))

func _on_skeleton(joints: PackedFloat32Array, _bones: PackedInt32Array) -> void:
	var holder: Node3D = body.get_node("Joints")
	for c in holder.get_children():
		c.queue_free()
	for i in joints.size() / 3:
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.012
		sm.height = 0.024
		s.mesh = sm
		s.material_override = _mat(Color(0.9, 0.2, 0.2))
		s.position = Vector3(joints[3 * i], joints[3 * i + 1], joints[3 * i + 2])
		holder.add_child(s)

# label: mesh | fit | drape. The newest one is shown.
func _on_garment(v: PackedFloat32Array, f: PackedInt32Array, label: String) -> void:
	var mi: MeshInstance3D = body.get_node("Garment")
	mi.mesh = _shaded(v, f)
	var col := {"mesh": Color(0.3, 0.5, 0.9), "fit": Color(0.2, 0.7, 0.4), "drape": Color(0.8, 0.3, 0.6)}
	mi.material_override = _mat(col.get(label, Color.WHITE))
