# dress_on_stage -- Stage 1's GPU-layer probes (dress_on.elf), Gate 0F's
# sandbox runtime probes (probes.elf) and Gate 6G.1's worker-thread round
# trips (rd_worker.elf); the last two in Sandboxes of their own, made on first use.
# Moved out of main.gd unchanged; main.gd keeps a delegate for every method so
# /root/Main answers the same calls over MCP (rule 8).
extends "res://stages/stage_base.gd"

var _probes = null
var _rdw = null

func _ready() -> void:
	stage_name = "dress_on"
	# Every Array, RDUniform and returned Variant is scoped to one vmcall; the
	# default cap (100) is hit by ~30 uniform sets. Stage 1 finding.
	open_sandbox("res://dress_on.elf", 0, 65536, 0)

func _bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b

# --- Stage 1: the GPU layer's own probes ------------------------------------

func rd_open() -> String:
	return str(sandbox.vmcall("rd_open")) if sandbox != null else "FAIL: no sandbox"

func rd_close() -> String:
	return str(sandbox.vmcall("rd_close")) if sandbox != null else "FAIL: no sandbox"

# Gate 0A's probe, now through rd_compute. Says whether the device was held
# from an earlier call.
func rd_probe() -> String:
	if sandbox == null:
		return "FAIL: no sandbox"
	var spirv := _bytes("res://probe.spv")
	if spirv.is_empty():
		return "FAIL: could not open probe.spv"
	return str(sandbox.vmcall("rd_probe", spirv))

# n_submit compute lists of n_dispatch accumulate dispatches; the count must
# equal the product. host_us is the whole vmcall, boundary included.
func rd_bench(n_dispatch: int = 1, n_submit: int = 1, barrier: bool = true) -> String:
	if sandbox == null:
		return "FAIL: no sandbox"
	var spirv := _bytes("res://accumulate.spv")
	if spirv.is_empty():
		return "FAIL: could not open accumulate.spv"
	var t0 := Time.get_ticks_usec()
	var r = sandbox.vmcall("rd_bench", spirv, n_dispatch, n_submit, barrier)
	var dt := Time.get_ticks_usec() - t0
	return "nd=%d ns=%d barrier=%s host_us=%d %s" % [n_dispatch, n_submit, barrier, dt, str(r)]

func rd_last_step() -> String:
	return str(sandbox.vmcall("rd_last_step")) if sandbox != null else "FAIL: no sandbox"

# rd_bench with no guest clock reads (probe_rd_mix.gd's "guest-quiet" arm);
# host-timed only.
func rd_bench_quiet(n_dispatch: int = 1, n_submit: int = 1, barrier: bool = true) -> String:
	if sandbox == null:
		return "FAIL: no sandbox"
	var spirv := _bytes("res://accumulate.spv")
	if spirv.is_empty():
		return "FAIL: could not open accumulate.spv"
	var t0 := Time.get_ticks_usec()
	var r = sandbox.vmcall("rd_bench_quiet", spirv, n_dispatch, n_submit, barrier)
	var dt := Time.get_ticks_usec() - t0
	return "nd=%d ns=%d barrier=%s host_us=%d %s" % [n_dispatch, n_submit, barrier, dt, str(r)]

# Keeps probe.spv in the guest for rd_calls' shader/pipeline/uset/readback kinds.
func rd_set_probe() -> String:
	if sandbox == null:
		return "FAIL: no sandbox"
	var spirv := _bytes("res://probe.spv")
	if spirv.is_empty():
		return "FAIL: could not open probe.spv"
	return str(sandbox.vmcall("rd_set_probe", spirv))

# One RenderingDevice call kind n times, timed on the host around the vmcall
# (probe_rd_calls.gd). The shader kinds need rd_set_probe first.
func rd_calls(kind: String = "ticks", n: int = 1000) -> String:
	if sandbox == null:
		return "FAIL: no sandbox"
	var t0 := Time.get_ticks_usec()
	var r = sandbox.vmcall("rd_calls", kind, n)
	return "host_us=%d %s" % [Time.get_ticks_usec() - t0, str(r)]

# --- Gate 0F: probes.elf, the sandbox runtime probes ---------------------------
# Its own Sandbox, created on first use. gate_runtime.gd is the gate; these are
# the no-argument wrappers (AGENTS.md rule 8), every argument defaulted.

func pv(fn: String, args: Array = []) -> String:
	if _probes == null:
		var r := SandboxUtil.make_sandbox(self, "res://probes.elf", 0, 4096, 0)
		_probes = r.sandbox
		if _probes == null:
			return "FAIL: no sandbox (%s)" % r.reason
	return str(_probes.callv("vmcall", [fn] + args))

# --- Gate 6G.1: rd_worker.elf (gates/6g-polyfem-gpu/g1-rd-worker) ----------------
# Its own Sandbox, made on first use, called on the calling thread. Its device
# is bound to the thread that opened it (Godot's render-thread guard), which
# for these wrappers is the main thread; gate_rd_worker.gd runs the worker arms.

func rw(fn: String, args: Array = []) -> String:
	if _rdw == null:
		var r := SandboxUtil.make_sandbox(self, "res://rd_worker.elf", 0, 4096, 4000000)
		_rdw = r.sandbox
		if _rdw == null:
			return "FAIL: no sandbox (%s)" % r.reason
	var v = _rdw.callv("vmcall", [fn] + args)
	if typeof(v) == TYPE_PACKED_BYTE_ARRAY:
		return "%d bytes" % v.size()
	return str(v)
