# mesh_topo -- small host-side mesh helpers for the pipeline: boundary loops
# of a triangle list (for a garment that did not come from curvenet.elf, whose
# mesh_boundary_loops answers the same thing), the loop with the highest mean
# y (the drape's waist pins), connected components, and finiteness.
# Triangles are index triples (util/mesh_wire.gd's format).
extends RefCounted

# Array of PackedInt32Array, each a closed boundary loop in edge order.
static func boundary_loops(tris: PackedInt32Array) -> Array:
	var count := {}
	for t in range(0, tris.size() - 2, 3):
		for k in 3:
			var a := tris[t + k]
			var b := tris[t + (k + 1) % 3]
			var key := Vector2i(mini(a, b), maxi(a, b))
			count[key] = count.get(key, 0) + 1
	var nxt := {} # boundary vertex -> its boundary neighbours
	for key in count:
		if count[key] == 1:
			for pair in [[key.x, key.y], [key.y, key.x]]:
				if not nxt.has(pair[0]):
					nxt[pair[0]] = []
				nxt[pair[0]].append(pair[1])
	var used := {}
	var loops := []
	for start in nxt:
		if used.has(start):
			continue
		var loop := PackedInt32Array([start])
		used[start] = true
		var prev: int = -1
		var cur: int = start
		while true:
			var step := -1
			for c in nxt[cur]:
				if c != prev and not used.has(c):
					step = c
					break
			if step < 0:
				break
			loop.append(step)
			used[step] = true
			prev = cur
			cur = step
		loops.append(loop)
	return loops

static func mean_y(v: PackedFloat32Array, loop: PackedInt32Array) -> float:
	var s := 0.0
	for i in loop:
		s += v[3 * i + 1]
	return s / maxf(1.0, loop.size())

# Index into loops of the loop with the highest mean y; -1 if none.
static func highest_loop(v: PackedFloat32Array, loops: Array) -> int:
	var best := -1
	for i in loops.size():
		if best < 0 or mean_y(v, loops[i]) > mean_y(v, loops[best]):
			best = i
	return best

static func components(n_vertices: int, tris: PackedInt32Array) -> int:
	var parent := [] # an Array: shared by reference with _find/_union
	parent.resize(n_vertices)
	for i in n_vertices:
		parent[i] = i
	var used := {}
	for t in range(0, tris.size() - 2, 3):
		for k in 3:
			used[tris[t + k]] = true
		_union(parent, tris[t], tris[t + 1])
		_union(parent, tris[t], tris[t + 2])
	var roots := {}
	for i in used:
		roots[_find(parent, i)] = true
	return roots.size()

static func _find(parent: Array, i: int) -> int:
	while parent[i] != i:
		parent[i] = parent[parent[i]]
		i = parent[i]
	return i

static func _union(parent: Array, a: int, b: int) -> void:
	var ra := _find(parent, a)
	var rb := _find(parent, b)
	if ra != rb:
		parent[ra] = rb

static func all_finite(v: PackedFloat32Array) -> bool:
	for x in v:
		if is_nan(x) or is_inf(x):
			return false
	return true

static func transform(v: PackedFloat32Array, xf: Transform3D) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(v.size())
	for i in range(0, v.size() - 2, 3):
		var p := xf * Vector3(v[i], v[i + 1], v[i + 2])
		out[i] = p.x
		out[i + 1] = p.y
		out[i + 2] = p.z
	return out

# {min_area, min_edge, degenerate (area < eps)} over a triangle list.
static func quality(v: PackedFloat32Array, tris: PackedInt32Array, eps: float = 1e-12) -> Dictionary:
	var min_a := INF
	var min_e := INF
	var bad := 0
	for t in range(0, tris.size() - 2, 3):
		var a := Vector3(v[3 * tris[t]], v[3 * tris[t] + 1], v[3 * tris[t] + 2])
		var b := Vector3(v[3 * tris[t + 1]], v[3 * tris[t + 1] + 1], v[3 * tris[t + 1] + 2])
		var c := Vector3(v[3 * tris[t + 2]], v[3 * tris[t + 2] + 1], v[3 * tris[t + 2] + 2])
		var area := 0.5 * (b - a).cross(c - a).length()
		min_a = minf(min_a, area)
		min_e = minf(min_e, minf((b - a).length(), minf((c - b).length(), (a - c).length())))
		if area < eps:
			bad += 1
	return {"min_area": min_a, "min_edge": min_e, "degenerate": bad}
