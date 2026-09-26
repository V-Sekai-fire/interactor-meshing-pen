# usd_nodes -- Godot nodes from usd_stage's arrays (Cut U): an ArrayMesh per
# UsdGeomMesh, a StandardMaterial3D per UsdPreviewSurface, a Node3D tree
# with each mesh's world transform. Static helpers; use as
#   const UsdNodes := preload("res://util/usd_nodes.gd")
#
# Frames: USD triangles are right-handed (counter-clockwise front faces) and
# Godot's are clockwise, so corners 1 and 2 swap (as util/mesh_wire.gd does);
# USD's st origin is the image's bottom left, Godot's UV origin its top left,
# so v -> 1 - v. A mesh's xform is USD's GfMatrix4d, row-major, row-vector
# convention: row i is the image of axis i and row 3 the origin. The 3x3
# rotation part crosses as a matrix (rule 11) and becomes Godot's Basis
# with those rows as its axis columns. A Z-up stage is turned to Y-up at the
# root, and metersPerUnit scales it to metres.
extends RefCounted

static func to_transform(xf: PackedFloat32Array) -> Transform3D:
	if xf.size() != 16:
		return Transform3D.IDENTITY
	var b := Basis(Vector3(xf[0], xf[1], xf[2]), Vector3(xf[4], xf[5], xf[6]), Vector3(xf[8], xf[9], xf[10]))
	return Transform3D(b, Vector3(xf[12], xf[13], xf[14]))

# Mesh.ARRAY_* surface arrays from {points, normals, uvs, indices}.
static func to_godot_arrays(m: Dictionary) -> Array:
	var p: PackedFloat32Array = m.points
	var n: int = p.size() / 3
	var pts := PackedVector3Array()
	pts.resize(n)
	for i in n:
		pts[i] = Vector3(p[3 * i], p[3 * i + 1], p[3 * i + 2])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	var nr: PackedFloat32Array = m.get("normals", PackedFloat32Array())
	if nr.size() == 3 * n and n > 0:
		var nv := PackedVector3Array()
		nv.resize(n)
		for i in n:
			nv[i] = Vector3(nr[3 * i], nr[3 * i + 1], nr[3 * i + 2])
		arrays[Mesh.ARRAY_NORMAL] = nv
	var uv: PackedFloat32Array = m.get("uvs", PackedFloat32Array())
	if uv.size() == 2 * n and n > 0:
		var tv := PackedVector2Array()
		tv.resize(n)
		for i in n:
			tv[i] = Vector2(uv[2 * i], 1.0 - uv[2 * i + 1])
		arrays[Mesh.ARRAY_TEX_UV] = tv
	var f: PackedInt32Array = m.get("indices", PackedInt32Array())
	var idx := PackedInt32Array()
	idx.resize(f.size())
	for t in range(0, f.size() - 2, 3):
		idx[t] = f[t]
		idx[t + 1] = f[t + 2]
		idx[t + 2] = f[t + 1]
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays

static func to_array_mesh(m: Dictionary, mat: Material = null) -> ArrayMesh:
	var am := ArrayMesh.new()
	if m.has("error") or m.get("points", PackedFloat32Array()).is_empty():
		return am
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, to_godot_arrays(m))
	if mat != null:
		am.surface_set_material(0, mat)
	return am

# PNG or JPEG by magic; null when the bytes decode to nothing.
static func to_image(bytes: PackedByteArray) -> Image:
	if bytes.size() < 4:
		return null
	var img := Image.new()
	var err: int
	if bytes[0] == 0x89 and bytes[1] == 0x50:
		err = img.load_png_from_buffer(bytes)
	elif bytes[0] == 0xFF and bytes[1] == 0xD8:
		err = img.load_jpg_from_buffer(bytes)
	elif bytes[0] == 0x52 and bytes[1] == 0x49:
		err = img.load_webp_from_buffer(bytes)
	else:
		return null
	return img if err == OK and not img.is_empty() else null

static func to_texture(bytes: PackedByteArray) -> ImageTexture:
	var img := to_image(bytes)
	return null if img == null else ImageTexture.create_from_image(img)

static func _channel(c: String) -> int:
	match c:
		"r": return BaseMaterial3D.TEXTURE_CHANNEL_RED
		"g": return BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		"b": return BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		"a": return BaseMaterial3D.TEXTURE_CHANNEL_ALPHA
	return BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE

# StandardMaterial3D from usd_stage.material(i)'s Dictionary; textures are
# shared by their index within one call (metallic and roughness usually read
# two channels of one image).
static func to_material(mat: Dictionary, cache: Dictionary = {}) -> StandardMaterial3D:
	var sm := StandardMaterial3D.new()
	if mat.has("error"):
		return sm
	var d: PackedFloat32Array = mat.get("diffuse", PackedFloat32Array([0.18, 0.18, 0.18]))
	if d.size() >= 3:
		sm.albedo_color = Color(d[0], d[1], d[2])
	sm.metallic = float(mat.get("metallic", 0.0))
	sm.roughness = float(mat.get("roughness", 0.5))
	var tex := func(k: String) -> ImageTexture:
		var t: int = int(mat.get(k + "_texture", -1))
		if t < 0 or not mat.has(k + "_bytes"):
			return null
		if not cache.has(t):
			cache[t] = to_texture(mat[k + "_bytes"])
		return cache[t]
	var albedo: ImageTexture = tex.call("diffuse")
	if albedo != null:
		sm.albedo_texture = albedo
		sm.albedo_color = Color(1, 1, 1)
	var metal: ImageTexture = tex.call("metallic")
	if metal != null:
		sm.metallic = 1.0
		sm.metallic_texture = metal
		sm.metallic_texture_channel = _channel(str(mat.get("metallic_channel", "")))
	var rough: ImageTexture = tex.call("roughness")
	if rough != null:
		sm.roughness = 1.0
		sm.roughness_texture = rough
		sm.roughness_texture_channel = _channel(str(mat.get("roughness_channel", "")))
	var normal: ImageTexture = tex.call("normal")
	if normal != null:
		sm.normal_enabled = true
		sm.normal_texture = normal
	var opacity := float(mat.get("opacity", 1.0))
	var opac: ImageTexture = tex.call("opacity")
	if opacity < 1.0 or opac != null:
		sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		sm.albedo_color.a = opacity
	return sm

# The document as a Node3D: one MeshInstance3D per mesh, named after its
# prim, at its world transform, with its bound material.
static func to_node(doc: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "Usd"
	if str(doc.get("up", "Y")) == "Z":
		root.basis = Basis(Vector3.RIGHT, -PI / 2)
	var mpu := float(doc.get("mpu", 1.0))
	if mpu > 0.0 and not is_equal_approx(mpu, 1.0):
		root.basis = root.basis.scaled(Vector3.ONE * mpu)
	var mats := []
	var cache := {}
	for m in doc.get("materials", []):
		mats.append(to_material(m, cache))
	for m in doc.get("meshes", []):
		if m.has("error"):
			continue
		var mi := MeshInstance3D.new()
		mi.name = str(m.get("name", "Mesh"))
		var k: int = int(m.get("material", -1))
		mi.mesh = to_array_mesh(m, mats[k] if k >= 0 and k < mats.size() else null)
		mi.transform = to_transform(m.get("xform", PackedFloat32Array()))
		root.add_child(mi)
	return root
