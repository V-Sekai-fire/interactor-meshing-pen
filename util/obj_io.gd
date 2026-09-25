# Wavefront OBJ into packed arrays, for handing meshes to the guests (which
# cannot open files: Gate 0F probe 3). Reads what cloth-fit's readers read:
#   v x y z          -> "v": PackedFloat32Array, xyz triples (file order)
#   f a[/t[/n]] ...  -> "f": PackedInt32Array, triangles; polygons are fanned
#                       from their first vertex (optimize.cpp's triangulation)
#   l a b            -> "l": PackedInt32Array, edge pairs (skeletons)
# Indices come out 0-based; negative (relative) indices are resolved. Other
# records (vn, vt, o, g, s, usemtl, mtllib, comments) are skipped.
extends RefCounted

static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"error": "cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	var v := PackedFloat32Array()
	var tris := PackedInt32Array()
	var lines := PackedInt32Array()
	var nv := 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("v "):
			var p := line.split(" ", false)
			if p.size() < 4:
				return {"error": "%s: bad vertex line '%s'" % [path, line]}
			v.push_back(p[1].to_float())
			v.push_back(p[2].to_float())
			v.push_back(p[3].to_float())
			nv += 1
		elif line.begins_with("f "):
			var p := line.split(" ", false)
			var ids := PackedInt32Array()
			for i in range(1, p.size()):
				ids.push_back(_index(p[i], nv))
			for i in range(1, ids.size() - 1):
				tris.push_back(ids[0])
				tris.push_back(ids[i])
				tris.push_back(ids[i + 1])
		elif line.begins_with("l "):
			var p := line.split(" ", false)
			# A polyline l a b c ... is its consecutive edges.
			for i in range(1, p.size() - 1):
				lines.push_back(_index(p[i], nv))
				lines.push_back(_index(p[i + 1], nv))
	f.close()
	return {"v": v, "f": tris, "l": lines}

static func _index(tok: String, nv: int) -> int:
	var k := tok.get_slice("/", 0).to_int()
	return k - 1 if k > 0 else nv + k

# Whitespace-separated integers (cloth-fit's no-fit.txt), as given (0-based).
static func read_ints(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"error": "cannot open %s (%s)" % [path, error_string(FileAccess.get_open_error())]}
	var out := PackedInt32Array()
	var text := f.get_as_text().replace("\r", " ").replace("\n", " ").replace("\t", " ")
	for tok in text.split(" ", false):
		out.push_back(tok.to_int())
	f.close()
	return {"ints": out}
