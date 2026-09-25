# mesh_wire -- the host side of guest/common/mesh_wire.h: how meshes, curves
# and knots cross between the stage ELFs (AGENTS.md rule 6). Static helpers;
# use it as `const MeshWire := preload("res://util/mesh_wire.gd")`.
#
# Frame and units: body-local Godot frame (+Y up), metres.
#   vertices       PackedFloat32Array, 3N
#   triangles      PackedInt32Array, 3F, counter-clockwise seen from outside.
#                  Godot's own front faces are clockwise, so from_godot_arrays
#                  and to_godot_arrays swap the winding.
#   boundary loops PackedInt32Array [n, len0, i.., len1, i..]
#   curves         PackedFloat32Array [n, per curve np, closed, knot0, knot1,
#                  np * (pos3, in3, out3)]; in/out relative to pos
#   knots          PackedFloat32Array [n, per knot pos3, degree,
#                  is_intersection, needs_setup, basis9 (row-major)]
extends RefCounted

const CURVE_HEADER := 4
const CURVE_POINT := 9
const KNOT_STRIDE := 15

# Mesh.ARRAY_* surface arrays (Godot winding) -> {vertices, triangles}.
static func from_godot_arrays(arrays: Array) -> Dictionary:
	var pts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(pts.size())
		for i in pts.size():
			idx[i] = i
	var v := PackedFloat32Array()
	v.resize(pts.size() * 3)
	for i in pts.size():
		v[3 * i] = pts[i].x
		v[3 * i + 1] = pts[i].y
		v[3 * i + 2] = pts[i].z
	var f := PackedInt32Array()
	f.resize(idx.size() - idx.size() % 3)
	for t in range(0, f.size(), 3):
		f[t] = idx[t]
		f[t + 1] = idx[t + 2]
		f[t + 2] = idx[t + 1]
	return {"vertices": v, "triangles": f}

# {vertices, triangles} -> Mesh.ARRAY_* surface arrays (Godot winding).
static func to_godot_arrays(v: PackedFloat32Array, f: PackedInt32Array) -> Array:
	var pts := PackedVector3Array()
	pts.resize(v.size() / 3)
	for i in pts.size():
		pts[i] = Vector3(v[3 * i], v[3 * i + 1], v[3 * i + 2])
	var idx := PackedInt32Array()
	idx.resize(f.size())
	for t in range(0, f.size(), 3):
		idx[t] = f[t]
		idx[t + 1] = f[t + 2]
		idx[t + 2] = f[t + 1]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	arrays[Mesh.ARRAY_INDEX] = idx
	return arrays

static func to_array_mesh(v: PackedFloat32Array, f: PackedInt32Array) -> ArrayMesh:
	var m := ArrayMesh.new()
	if f.size() >= 3:
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, to_godot_arrays(v, f))
	return m

# [n, len0, i.., ...] -> Array of PackedInt32Array; [] on a malformed buffer.
static func loops(p: PackedInt32Array) -> Array:
	var out := []
	if p.is_empty():
		return out
	var at := 1
	for k in p[0]:
		if at >= p.size() or at + 1 + p[at] > p.size():
			return []
		out.append(p.slice(at + 1, at + 1 + p[at]))
		at += 1 + p[at]
	return out if at == p.size() else []

# Curves -> Array of {closed, knots: Vector2i, points: [{pos, in, out}]}.
static func curves(p: PackedFloat32Array) -> Array:
	var out := []
	if p.is_empty():
		return out
	var at := 1
	for c in int(p[0]):
		var np := int(p[at])
		var d := {"closed": p[at + 1] != 0.0, "knots": Vector2i(int(p[at + 2]), int(p[at + 3])), "points": []}
		at += CURVE_HEADER
		for j in np:
			d.points.append({
				"pos": Vector3(p[at], p[at + 1], p[at + 2]),
				"in": Vector3(p[at + 3], p[at + 4], p[at + 5]),
				"out": Vector3(p[at + 6], p[at + 7], p[at + 8]),
			})
			at += CURVE_POINT
		out.append(d)
	return out

# A decoded curve as a Curve3D.
static func to_curve3d(d: Dictionary) -> Curve3D:
	var c := Curve3D.new()
	for q in d.points:
		c.add_point(q.pos, q["in"], q.out)
	c.closed = d.closed
	return c

# Knots -> Array of {position, degree, is_intersection, needs_setup, basis}.
static func knots(p: PackedFloat32Array) -> Array:
	var out := []
	if p.is_empty():
		return out
	for k in int(p[0]):
		var at := 1 + k * KNOT_STRIDE
		var b := Basis(Vector3(p[at + 6], p[at + 9], p[at + 12]), Vector3(p[at + 7], p[at + 10], p[at + 13]),
				Vector3(p[at + 8], p[at + 11], p[at + 14]))
		out.append({
			"position": Vector3(p[at], p[at + 1], p[at + 2]),
			"degree": int(p[at + 3]),
			"is_intersection": p[at + 4] != 0.0,
			"needs_setup": p[at + 5] != 0.0,
			"basis": b,
		})
	return out

# n samples of 4 floats (x, y, z, pressure) on the circle of latitude `lat`
# (radians) of a sphere of radius r, sweeping `sweep` radians; a full sweep
# ends exactly on its first sample. For pen_stroke.
static func circle_stroke(r: float, lat: float, sweep: float, n: int, pressure: float = 0.5) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var y := r * sin(lat)
	var rho := r * cos(lat)
	for i in n + 1:
		var a := 0.0 if (i == n and sweep >= TAU) else sweep * float(i) / float(n)
		out.append_array([rho * cos(a), y, rho * sin(a), pressure])
	return out

# A unit cube on 8 shared corners, 12 triangles, CCW-outward (wire winding).
static func cube() -> Dictionary:
	return {
		"vertices": PackedFloat32Array([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 0, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1]),
		"triangles": PackedInt32Array([0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7,
				0, 7, 3, 1, 2, 6, 1, 6, 5]),
	}

# A capped cylinder body of radius r around the y axis from y0 to y1, in wire
# winding (Godot's CylinderMesh, rewound and lifted).
static func cylinder(r: float, y0: float, y1: float, radial: int = 64, rings: int = 16) -> Dictionary:
	var c := CylinderMesh.new()
	c.top_radius = r
	c.bottom_radius = r
	c.height = y1 - y0
	c.radial_segments = radial
	c.rings = rings
	var d := from_godot_arrays(c.get_mesh_arrays())
	var v: PackedFloat32Array = d.vertices
	for i in range(1, v.size(), 3):
		v[i] += 0.5 * (y0 + y1)
	d.vertices = v
	return d

# A sphere body of radius r in wire winding (Godot's SphereMesh, rewound).
static func sphere(r: float, radial: int = 64, rings: int = 32) -> Dictionary:
	var s := SphereMesh.new()
	s.radius = r
	s.height = 2.0 * r
	s.radial_segments = radial
	s.rings = rings
	return from_godot_arrays(s.get_mesh_arrays())
