# Load check for the fork: the dress-on VR scene and its scripts parse, the
# godot-sandbox class is registered, and the pen ELF loads into a Sandbox.
#   godot --headless --path . --xr-mode off --script tools/probe_load.gd
extends SceneTree

func _initialize() -> void:
	var ok := true
	var scene = load("res://xr_main.tscn")
	print("xr_main.tscn: ", "loaded" if scene else "FAIL")
	ok = ok and scene != null
	var has := ClassDB.class_exists("Sandbox")
	print("Sandbox class: ", "registered" if has else "FAIL")
	ok = ok and has
	if has:
		var s = ClassDB.instantiate("Sandbox")
		s.program = load("res://curvenet.elf")
		var fns = s.get_functions() if s.has_method("get_functions") else []
		print("curvenet.elf: ", fns.size(), " functions")
		ok = ok and fns.size() > 0
		s.free()
		# usd.elf is a large OpenUSD guest; load it through its stage so the
		# memory/references/timeout setup is right (a bare Sandbox traps).
		var UsdStage = load("res://stages/usd_stage.gd")
		var stage = UsdStage.new()
		root.add_child(stage)
		stage.ensure()
		var uok: bool = stage.sandbox != null and stage.sandbox.get_functions().size() > 0
		print("usd.elf: ", "loaded, %d functions" % stage.sandbox.get_functions().size() if uok else "FAIL " + str(stage.reason))
		ok = ok and uok
		stage.free()
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
