# Pen strokes <-> OpenUSD, through usd.elf (stages/usd_stage.gd): GDScript never
# parses USD (RFD 2234). A stroke is the pipeline's {name, boundary, points}
# dict, points in the Body frame (+Y up, metres). The layer is one linear
# BasisCurves prim per stroke under /Creation; boundary is authored only on the
# strokes drawn in boundary mode.
extends RefCounted

# {text} or {error}.
static func to_usda(usd, strokes: Array, meta: Dictionary = {}) -> Dictionary:
	var pts := PackedFloat32Array()
	var counts := PackedInt32Array()
	var boundary := PackedInt32Array()
	var names := PackedStringArray()
	for k in strokes.size():
		var s: Dictionary = strokes[k]
		var p: PackedVector3Array = s.points
		for v in p:
			pts.append_array([v.x, v.y, v.z])
		counts.append(p.size())
		names.append(str(s.get("name", "stroke_%03d" % k)))
		if bool(s.get("boundary", false)):
			boundary.append(k)
	var text: String = usd.write_curves(pts, counts, boundary, names, meta)
	if text.begins_with("ERR") or text.begins_with("FAIL"):
		return {"error": text}
	return {"text": text}

# {strokes, meta, open} or {error}.
static func from_usda(usd, bytes: PackedByteArray) -> Dictionary:
	var r: String = usd.open_package(bytes)
	if not r.begins_with("ok "):
		return {"error": r}
	var strokes := []
	for i in usd.curve_count():
		var c: Dictionary = usd.curve(i)
		if c.has("error"):
			return {"error": "curve %d: %s" % [i, c.error]}
		strokes.append(c)
	return {"strokes": strokes, "meta": usd.layer_data(), "open": r}

static func from_file(usd, path: String) -> Dictionary:
	var g := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(g):
		return {"error": "no file %s" % path}
	return from_usda(usd, FileAccess.get_file_as_bytes(g))

# The pen events a stroke list makes, as the scripted source makes them.
static func events(strokes: Array, pressure: float = 0.5) -> Array:
	var out := []
	for k in strokes.size():
		var pts: PackedVector3Array = strokes[k].points
		out.append({"kind": "begin", "stroke": k, "pos": pts[0], "pressure": pressure,
				"boundary": bool(strokes[k].get("boundary", false))})
		for i in range(1, pts.size()):
			out.append({"kind": "point", "stroke": k, "pos": pts[i], "pressure": pressure})
		out.append({"kind": "end", "stroke": k})
	return out
