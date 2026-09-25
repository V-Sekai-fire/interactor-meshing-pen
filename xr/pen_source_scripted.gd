# pen_source_scripted -- deterministic skirt strokes from a body and its
# 15-joint skeleton (util/skeleton15.gd), as the pen events a hand would make:
# pen_begin / pen_point / pen_end in the body-local frame (+Y up, metres).
#
#   waist ring at the pelvis joint's height, centred on the pelvis
#   hem ring at the knees' mean height, centred between the knees
#   each ring as two half-rings, left (+x) and right (-x), meeting at the
#   front (+z) and the back (-z), so no stroke is closed and Cassie's
#   closed-stroke split is not needed (closed_rings = true draws each ring as
#   one closed stroke instead, for that path)
#   a front seam and a back seam from waist to hem, ending exactly on the
#   ring points
#
# Ring radius: the largest horizontal distance, from the ring centre, of body
# vertices within BAND of the ring's height, + CLEARANCE. Vertices farther than
# 0.6 x the nearest wrist's horizontal distance are left out (FoxGirl's hands
# hang at pelvis height: the torso ends at 0.16 m, the hands start at 0.34 m).
# Then both rings grow by the same amount if the straight cone between them
# would pass closer than CLEARANCE to the body (FoxGirl's hips: the rings
# alone leave it 2.5 cm inside), since fit_begin refuses a garment that starts
# intersecting the body.
#
# The rings are boundary strokes (curvenet's "boundary" pen mode, captured at
# pen_begin; the begin event carries it): a cycle made only of them is an
# opening, the waist or the hem, and gets no patch. Without the mark the two
# rings' caps are surfaced too (4 patches), since the network alone cannot
# tell a cap from an opening (gates/4-curvenet/README.md, skirt (b)).
#
# The sketch graph this should give: 4 knots (waist/hem x front/back), each of
# degree 3 (two half-rings and a seam), 6 edges by the handshake lemma (4 x 3 /
# 2), and 2 cycles (the front and the back panel) plus 2 openings, so 2 patches. The Cut 8
# task text says "8 curves"; 4 knots of degree 3 cannot have 8 edges, so the
# gate records the curvenet's own count and checks it against the knots.
extends RefCounted

const Skeleton15 := preload("res://util/skeleton15.gd")
const BAND := 0.02
const CLEARANCE := 0.01
const HAND_CUT := 0.6

# body_v: PackedFloat32Array xyz; joints: 45 floats in the 15-joint layout.
# opts: half_samples (24), seam_samples (12), pressure (0.5), drop_seam
# (false: the back seam is not drawn, the Gate 8 control), closed_rings,
# no_boundary (false: the rings are drawn as ordinary strokes, so their caps
# are surfaced too; a control).
static func make(body_v: PackedFloat32Array, joints: PackedFloat32Array, opts: Dictionary = {}) -> Dictionary:
	if joints.size() != 45:
		return {"error": "want 15 joints (45 floats), got %d floats" % joints.size()}
	var j := func(i: int) -> Vector3: return Vector3(joints[3 * i], joints[3 * i + 1], joints[3 * i + 2])
	var pelvis: Vector3 = j.call(0)
	var knees: Vector3 = (j.call(10) + j.call(13)) * 0.5
	var wrists := [j.call(5), j.call(7)]
	var waist := _ring(body_v, pelvis, wrists)
	var hem := _ring(body_v, knees, wrists)
	if waist.has("error"):
		return waist
	if hem.has("error"):
		return hem
	# The rings alone let the straight cone between them cut into the hips
	# (FoxGirl: -2.5 cm), and fit_begin refuses a garment that starts inside
	# the body. Grow both rings by the deficit so the cone clears by CLEARANCE.
	var grow := 0.0
	var c0 := _clearance(body_v, waist, hem, wrists)
	if c0 < CLEARANCE and not opts.get("no_grow", false):
		grow = CLEARANCE - c0
		waist.radius += grow
		hem.radius += grow
	var nh: int = opts.get("half_samples", 24)
	var ns: int = opts.get("seam_samples", 12)
	var pressure: float = opts.get("pressure", 0.5)
	var strokes := []
	var ring_mark: bool = not opts.get("no_boundary", false)
	var wf := _at(waist, PI / 2)
	var wb := _at(waist, -PI / 2)
	var hf := _at(hem, PI / 2)
	var hb := _at(hem, -PI / 2)
	if opts.get("closed_rings", false):
		strokes.append({"name": "waist", "boundary": ring_mark, "points": _arc(waist, PI / 2, PI / 2 - TAU, 2 * nh)})
		strokes.append({"name": "hem", "boundary": ring_mark, "points": _arc(hem, PI / 2, PI / 2 - TAU, 2 * nh)})
	else:
		strokes.append({"name": "waist_left", "boundary": ring_mark, "points": _arc(waist, PI / 2, -PI / 2, nh)})
		strokes.append({"name": "waist_right", "boundary": ring_mark, "points": _arc(waist, PI / 2, 3 * PI / 2, nh)})
		strokes.append({"name": "hem_left", "boundary": ring_mark, "points": _arc(hem, PI / 2, -PI / 2, nh)})
		strokes.append({"name": "hem_right", "boundary": ring_mark, "points": _arc(hem, PI / 2, 3 * PI / 2, nh)})
	strokes.append({"name": "seam_front", "boundary": false, "points": _line(wf, hf, ns)})
	if not opts.get("drop_seam", false):
		strokes.append({"name": "seam_back", "boundary": false, "points": _line(wb, hb, ns)})
	var events := []
	for k in strokes.size():
		var pts: PackedVector3Array = strokes[k].points
		events.append({"kind": "begin", "stroke": k, "pos": pts[0], "pressure": pressure,
				"boundary": strokes[k].boundary})
		for i in range(1, pts.size()):
			events.append({"kind": "point", "stroke": k, "pos": pts[i], "pressure": pressure})
		events.append({"kind": "end", "stroke": k})
	return {
		"strokes": strokes,
		"events": events,
		"waist": waist,
		"hem": hem,
		"min_clearance": _clearance(body_v, waist, hem, wrists),
		"clearance_before_grow": c0,
		"grow": grow,
		"expected": {"cycles": 2, "openings": 2, "patches": 2, "knots": 4, "knot_degree": 3, "edges": 6,
				"mesh_loops": 2, "mesh_components": 1},
		"error": "",
	}

static func _ring(body_v: PackedFloat32Array, c: Vector3, wrists: Array) -> Dictionary:
	var cut := INF
	for w in wrists:
		cut = minf(cut, Vector2(w.x - c.x, w.z - c.z).length())
	cut *= HAND_CUT
	var r := 0.0
	var n := 0
	for i in range(0, body_v.size() - 2, 3):
		if absf(body_v[i + 1] - c.y) > BAND:
			continue
		var d := Vector2(body_v[i] - c.x, body_v[i + 2] - c.z).length()
		if d < cut:
			r = maxf(r, d)
			n += 1
	if n == 0:
		return {"error": "no body vertices within %.2f m of y=%.3f" % [BAND, c.y]}
	return {"center": c, "radius": r + CLEARANCE, "body_radius": r, "vertices": n, "cut": cut}

static func _at(ring: Dictionary, a: float) -> Vector3:
	var c: Vector3 = ring.center
	var r: float = ring.radius
	return Vector3(c.x + r * cos(a), c.y, c.z + r * sin(a))

# n + 1 samples from angle a0 to a1; a full turn ends exactly on its start.
static func _arc(ring: Dictionary, a0: float, a1: float, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in n + 1:
		out.append(_at(ring, a0 + (a1 - a0) * float(i) / float(n)))
	if absf(absf(a1 - a0) - TAU) < 1e-6:
		out[n] = out[0]
	return out

static func _line(a: Vector3, b: Vector3, n: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	for i in n + 1:
		out.append(a.lerp(b, float(i) / float(n)))
	out[n] = b
	return out

# The skirt as the straight cone between the rings, against body vertices
# between the two heights (hands left out as for the rings): the smallest
# radial gap. Negative means the cone starts inside the body there.
static func _clearance(body_v: PackedFloat32Array, waist: Dictionary, hem: Dictionary, wrists: Array) -> float:
	var y0: float = hem.center.y
	var y1: float = waist.center.y
	var best := INF
	for i in range(0, body_v.size() - 2, 3):
		var y := body_v[i + 1]
		if y < y0 or y > y1:
			continue
		var t := (y - y0) / maxf(1e-9, y1 - y0)
		var c: Vector3 = (hem.center as Vector3).lerp(waist.center, t)
		var cut := INF
		for w in wrists:
			cut = minf(cut, Vector2(w.x - c.x, w.z - c.z).length())
		var d := Vector2(body_v[i] - c.x, body_v[i + 2] - c.z).length()
		if d >= cut * HAND_CUT:
			continue
		var r := lerpf(hem.radius, waist.radius, t)
		best = minf(best, r - d)
	return best
