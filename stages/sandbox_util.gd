# sandbox_util -- one place that makes a stage's Sandbox the way Gate 0F says
# it must be made. Static helpers; use as
#   const SandboxUtil := preload("res://stages/sandbox_util.gd")
#
# Gate 0F (gates/0f-runtime/README.md):
#   - memory_max is set BEFORE program=: a lower value set later is ignored,
#     and the heap is 0.8 x memory_max, which must end below 4 GiB (so at most
#     ~5112 MiB).
#   - references_max only grows; set it (4096 or more) before the first
#     object-creating vmcall.
#   - execution_timeout is instructions_max in units of 2^20 instructions
#     (default 8000); host calls are charged against it.
# A missing ELF is not an error here: make_sandbox answers {sandbox: null,
# reason: "..."} and the stage decides (pipeline: FAILED("<stage> missing")
# unless --allow-fixture names it).
extends RefCounted

const HEAP_CEILING_MB := 5112

# elf: "res://x.elf". mem_mb, refs, timeout_units: 0 leaves the Sandbox
# default. extra: other Sandbox properties set before program= (for example
# allocations_max). required: guest functions the stage needs; one missing
# yields a null sandbox and a reason naming it (an older ELF of that name).
# Native translation: the addon loads res://bintr/bintr-<HASH>.so for a
# program whose hash it matches, when sandbox/binary_translation/enabled is
# on. The setting stays off in project.godot (a Windows addon build
# segfaulted with it on and no library present, 2026-09-23); it is turned on
# here, per process, only where a translation is shipped, on Linux, where
# the org's addon build with the emit switch (tools/godot-sandbox/) was
# gated. tools/build.exs bakes the libraries; gates call this too.
static func enable_native_translation() -> bool:
	if OS.get_name() != "Linux":
		return false
	var dir := DirAccess.open("res://bintr")
	if dir == null:
		return false
	for f in dir.get_files():
		if f.begins_with("bintr-") and f.ends_with(".so"):
			ProjectSettings.set_setting("sandbox/binary_translation/enabled", true)
			return true
	return false

static func make_sandbox(parent: Node, elf: String, mem_mb: int = 0, refs: int = 4096, timeout_units: int = 0,
		extra: Dictionary = {}, required: PackedStringArray = PackedStringArray()) -> Dictionary:
	enable_native_translation()
	if mem_mb > HEAP_CEILING_MB:
		return {"sandbox": null, "reason": "memory_max %d MiB is past the %d MiB ceiling (Gate 0F probe 6)" % [mem_mb, HEAP_CEILING_MB]}
	if not ResourceLoader.exists(elf):
		return {"sandbox": null, "reason": "%s not found (not built or not imported)" % elf.get_file()}
	var sb = ClassDB.instantiate("Sandbox")
	if sb == null:
		return {"sandbox": null, "reason": "Sandbox class not registered (godot_sandbox addon disabled?)"}
	if mem_mb > 0:
		sb.memory_max = mem_mb # before program=
	if refs > 0:
		sb.references_max = refs
	if timeout_units > 0:
		sb.execution_timeout = timeout_units
	# allocations_max: the addon's default is 4000 live guest heap chunks. The Linux
	# build runs out of them where the Windows build of the same ELF does not
	# (Gate 0H: curvenet.elf in curvenet_build, drape.elf in its first call), so
	# every stage gets 1,000,000 unless it asks for more (fit_stage.gd: 4,000,000).
	sb.allocations_max = 1000000
	for k in extra:
		sb.set(k, extra[k])
	var prog = load(elf)
	if prog == null:
		sb.free()
		return {"sandbox": null, "reason": "%s did not load" % elf.get_file()}
	sb.program = prog
	for fn in required:
		if sb.has_method("has_function") and not sb.has_function(fn):
			sb.free()
			return {"sandbox": null, "reason": "%s has no %s() (an ELF from before its stage's cut)" % [elf.get_file(), fn]}
	if parent != null:
		parent.add_child(sb)
	return {"sandbox": sb, "reason": ""}

# Guest heap in bytes as the host sees it (-1 if the addon has no reading).
static func heap(sb) -> int:
	if sb == null or not is_instance_valid(sb):
		return -1
	if sb.has_method("get_heap_usage"):
		return int(sb.get_heap_usage())
	return -1
