# cassie_graph.elf: CASSIE's sketch graph (godot-cassie's CassieSketchGraph)
# on raw strokes, for a sketch's expected cycles.
extends "res://stages/stage_base.gd"

const REQUIRED := ["cg_cycles"]

func ensure() -> bool:
	stage_name = "cassie_graph"
	return open_sandbox("res://cassie_graph.elf", 256, 4096, 400, {}, PackedStringArray(REQUIRED))

# strokes: [{points: PackedVector3Array}, ...] -> the guest's Dictionary, or {error}.
func cycles(strokes: Array, merge_epsilon: float = 0.0) -> Dictionary:
	var pts := PackedFloat32Array()
	var counts := PackedInt32Array()
	for s in strokes:
		for v in s.points:
			pts.append_array([v.x, v.y, v.z])
		counts.append(s.points.size())
	var r = call_now("cg_cycles", [pts, counts, merge_epsilon])
	return r if typeof(r) == TYPE_DICTIONARY else {"error": str(r)}

func cg_cycles() -> String:
	var sq := [PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0)]), PackedVector3Array([Vector3(1, 0, 0), Vector3(1, 1, 0)]),
			PackedVector3Array([Vector3(1, 1, 0), Vector3(0, 1, 0)]), PackedVector3Array([Vector3(0, 1, 0), Vector3(0, 0, 0)])]
	var strokes := []
	for p in sq:
		strokes.append({"points": p})
	return str(cycles(strokes))
