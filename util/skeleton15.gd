# skeleton15 -- any rig onto cloth-fit's 15-joint layout, the one its
# garment-data skeletons use and the one GarmentSolver's is_skirt understands
# (vendor/cloth-fit src/polyfem/solver/forms/garment_forms/
# CurveCenterTargetForm.cpp:494-527 on cut-6: with is_skirt, 15 joints get a
# virtual mid-leg bone from rows 10/13 (knees) and 11/14 (ankles); 24 joints
# (SMPL) are the only other layout it accepts; anything else throws).
#
# The layout, as FoxGirl/skeleton.obj has it (0-based):
#    0 pelvis   1 chest   2 head
#    3 L shoulder  4 L elbow  5 L wrist
#    6 R shoulder  7 R wrist  8 R elbow     <- the file's order: 7 is the wrist
#    9 L hip   10 L knee  11 L ankle
#   12 R hip   13 R knee  14 R ankle
# Left is +x in the rig's frame (the character faces +z, Godot's convention;
# FoxGirl's left arm is at +x after the fixture's (x, z, -y) conversion).
#
# adapt(rig) takes {positions: PackedVector3Array | PackedFloat32Array (xyz),
# bones: PackedInt32Array (index pairs), names: PackedStringArray (optional)}
# and answers {joints: PackedFloat32Array (45), bones: PackedInt32Array (28),
# map: PackedInt32Array (15: the rig joint in each slot), method: "names" |
# "topology", error: ""}. Names win when every slot matches one; otherwise
# the bone graph decides (branch nodes, chain order, +x = left).
extends RefCounted

const N := 15
const SLOTS := ["pelvis", "chest", "head", "l_shoulder", "l_elbow", "l_wrist", "r_shoulder", "r_wrist", "r_elbow",
		"l_hip", "l_knee", "l_ankle", "r_hip", "r_knee", "r_ankle"]
const BONES := [0, 1, 1, 2, 1, 3, 3, 4, 4, 5, 1, 6, 6, 8, 7, 8, 0, 9, 9, 10, 10, 11, 0, 12, 12, 13, 13, 14]

# Side-free base names per slot, most specific first (Godot humanoid, Mixamo,
# Blender rigify-ish, VRM, plain).
const ALIASES := {
	"pelvis": ["hips", "pelvis", "hip"],
	"chest": ["upperchest", "chest", "spine2", "spine02", "spine1", "spine01"],
	"head": ["head"],
	"shoulder": ["upperarm", "arm", "uparm", "shoulder"],
	"elbow": ["lowerarm", "forearm", "elbow"],
	"wrist": ["hand", "wrist"],
	"hip": ["upperleg", "upleg", "thigh", "hip"],
	"knee": ["lowerleg", "leg", "calf", "shin", "knee"],
	"ankle": ["foot", "ankle"],
}

static func layout_bones() -> PackedInt32Array:
	return PackedInt32Array(BONES)

static func _positions(rig: Dictionary) -> PackedVector3Array:
	var p = rig.get("positions", PackedVector3Array())
	if typeof(p) == TYPE_PACKED_VECTOR3_ARRAY:
		return p
	var out := PackedVector3Array()
	for i in range(0, p.size() - 2, 3):
		out.append(Vector3(p[i], p[i + 1], p[i + 2]))
	return out

static func adapt(rig: Dictionary) -> Dictionary:
	var pos := _positions(rig)
	var bones: PackedInt32Array = rig.get("bones", PackedInt32Array())
	var names: PackedStringArray = rig.get("names", PackedStringArray())
	var map := PackedInt32Array()
	var method := ""
	if names.size() == pos.size() and not names.is_empty():
		map = _by_names(names)
		method = "names"
	if map.is_empty():
		var t := _by_topology(pos, bones)
		if t.has("error"):
			return {"error": t.error}
		map = t.map
		method = "topology"
	var joints := PackedFloat32Array()
	for s in N:
		var p := pos[map[s]]
		joints.append_array([p.x, p.y, p.z])
	return {"joints": joints, "bones": layout_bones(), "map": map, "method": method, "error": ""}

# --- names -------------------------------------------------------------------------

# "LeftUpperArm", "mixamorig:LeftForeArm", "upper_arm.L", "l_hand" ->
# ["l", "upperarm"]; side "" when none.
static func _split(name: String) -> Array:
	var n := name.to_lower()
	var colon := n.rfind(":")
	if colon >= 0:
		n = n.substr(colon + 1)
	for pre in ["def-", "def_", "bip01", "bip", "j_bip_", "j_"]:
		if n.begins_with(pre):
			n = n.substr(pre.length())
	var side := ""
	if n.begins_with("left"):
		side = "l"; n = n.substr(4)
	elif n.begins_with("right"):
		side = "r"; n = n.substr(5)
	elif n.ends_with("left"):
		side = "l"; n = n.substr(0, n.length() - 4)
	elif n.ends_with("right"):
		side = "r"; n = n.substr(0, n.length() - 5)
	else:
		for sep in [".", "_", "-", " "]:
			if n.ends_with(sep + "l"):
				side = "l"; n = n.substr(0, n.length() - 2); break
			if n.ends_with(sep + "r"):
				side = "r"; n = n.substr(0, n.length() - 2); break
			if n.begins_with("l" + sep):
				side = "l"; n = n.substr(2); break
			if n.begins_with("r" + sep):
				side = "r"; n = n.substr(2); break
	var base := ""
	for c in n:
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			base += c
	return [side, base]

static func _by_names(names: PackedStringArray) -> PackedInt32Array:
	var parts := []
	for nm in names:
		parts.append(_split(nm))
	var map := PackedInt32Array()
	map.resize(N)
	for s in N:
		var slot: String = SLOTS[s]
		var side := ""
		var key := slot
		if slot.begins_with("l_") or slot.begins_with("r_"):
			side = slot.substr(0, 1)
			key = slot.substr(2)
		var found := -1
		for alias in ALIASES[key]:
			for i in parts.size():
				if parts[i][0] == side and parts[i][1] == alias:
					found = i
					break
			if found >= 0:
				break
		if found < 0:
			return PackedInt32Array()
		map[s] = found
	# Every slot a distinct joint.
	var seen := {}
	for s in N:
		if seen.has(map[s]):
			return PackedInt32Array()
		seen[map[s]] = true
	return map

# --- topology ----------------------------------------------------------------------

static func _by_topology(pos: PackedVector3Array, bones: PackedInt32Array) -> Dictionary:
	var n := pos.size()
	if n < N:
		return {"error": "rig has %d joints; the 15-joint layout needs at least 15" % n}
	var adj := []
	adj.resize(n)
	for i in n:
		adj[i] = []
	for b in range(0, bones.size() - 1, 2):
		var a := bones[b]
		var c := bones[b + 1]
		if a < 0 or c < 0 or a >= n or c >= n:
			return {"error": "bone %d-%d out of range" % [a, c]}
		adj[a].append(c)
		adj[c].append(a)
	var branch := []
	for i in n:
		if adj[i].size() >= 3:
			branch.append(i)
	if branch.is_empty():
		return {"error": "no branch joint (a chain is not a body)"}
	var pelvis: int = branch[0]
	var chest: int = branch[0]
	for i in branch:
		if pos[i].y < pos[pelvis].y:
			pelvis = i
		if pos[i].y > pos[chest].y:
			chest = i
	if pelvis == chest:
		return {"error": "one branch joint only; cannot tell the pelvis from the chest"}
	# The spine: the path pelvis -> chest (BFS).
	var spine := _path(adj, pelvis, chest)
	if spine.is_empty():
		return {"error": "pelvis and chest are not connected"}
	var toward_chest: int = spine[1]
	var toward_pelvis: int = spine[spine.size() - 2]
	var up := []  # chains leaving the chest, not toward the pelvis
	for nb in adj[chest]:
		if nb != toward_pelvis:
			up.append(_chain(adj, chest, nb))
	var down := [] # chains leaving the pelvis, not toward the chest
	for nb in adj[pelvis]:
		if nb != toward_chest:
			down.append(_chain(adj, pelvis, nb))
	if up.size() != 3:
		return {"error": "the chest has %d chains besides the spine; want head + two arms" % up.size()}
	if down.size() != 2:
		return {"error": "the pelvis has %d chains besides the spine; want two legs" % down.size()}
	# Head: the chain whose end is highest. Arms: the other two, +x = left.
	var hi := 0
	for k in 3:
		if pos[up[k][-1]].y > pos[up[hi][-1]].y:
			hi = k
	var arms := []
	for k in 3:
		if k != hi:
			arms.append(up[k])
	if _mean_x(pos, arms[0]) < _mean_x(pos, arms[1]):
		arms.reverse()
	if _mean_x(pos, down[0]) < _mean_x(pos, down[1]):
		down.reverse()
	for c in arms + down:
		if c.size() < 3:
			return {"error": "a limb chain has %d joints; want 3 or more" % c.size()}
	var map := PackedInt32Array()
	map.resize(N)
	map[0] = pelvis
	map[1] = chest
	map[2] = up[hi][-1]
	# Arms: the last three before the hand branches (a clavicle is skipped).
	var la: Array = arms[0]
	var ra: Array = arms[1]
	map[3] = la[-3]; map[4] = la[-2]; map[5] = la[-1]
	map[6] = ra[-3]; map[8] = ra[-2]; map[7] = ra[-1]
	# Legs: the first three from the pelvis (toes are skipped).
	var ll: Array = down[0]
	var rl: Array = down[1]
	map[9] = ll[0]; map[10] = ll[1]; map[11] = ll[2]
	map[12] = rl[0]; map[13] = rl[1]; map[14] = rl[2]
	return {"map": map}

# From `from` into `start`, along degree-2 joints; stops at a leaf or at a
# branch joint (which is included).
static func _chain(adj: Array, from: int, start: int) -> Array:
	var out := [start]
	var prev := from
	var cur := start
	while adj[cur].size() == 2 and out.size() <= adj.size(): # a cycle cannot spin forever
		var nxt: int = adj[cur][0] if adj[cur][0] != prev else adj[cur][1]
		prev = cur
		cur = nxt
		out.append(cur)
	return out

static func _path(adj: Array, a: int, b: int) -> Array:
	var prev := {a: -1}
	var q := [a]
	while not q.is_empty():
		var c: int = q.pop_front()
		if c == b:
			break
		for nb in adj[c]:
			if not prev.has(nb):
				prev[nb] = c
				q.append(nb)
	if not prev.has(b):
		return []
	var path := []
	var c := b
	while c != -1:
		path.push_front(c)
		c = prev[c]
	return path

static func _mean_x(pos: PackedVector3Array, chain: Array) -> float:
	var s := 0.0
	for i in chain:
		s += pos[i].x
	return s / chain.size()
