# stage_base -- what every stage node shares: its one Sandbox (made by
# sandbox_util), the rule that at most one vmcall is in flight on it, and a
# worker Thread for calls that run for seconds (Gate 0F probe 7: a vmcall on a
# GDScript Thread works and the main thread keeps its frames; probe 8: two
# Sandboxes on two Threads at once are fine).
#
#   call_now(fn, args)   a vmcall on the calling thread; "BUSY ..." while a
#                        worker call is in flight on this sandbox
#   start(fn, args)      a vmcall on the worker Thread; poll() until it is done
#   poll()               {done: bool, result: Variant, host_ms: int}
#
# Rule 4: nothing here waits. The pipeline advances from _process and reads a
# worker result only once Thread.is_alive() is false.
extends Node

const SandboxUtil := preload("res://stages/sandbox_util.gd")

var sandbox = null
var reason := ""        # why sandbox is null
var stage_name := ""
var vm_us := 0          # host-timed vmcall time since the last take_vm_us()

var _thread: Thread = null
var _call := ""
var _t0 := 0
var _result = null
var _result_ms := 0

func open_sandbox(elf: String, mem_mb: int, refs: int, timeout_units: int, extra: Dictionary = {},
		required: PackedStringArray = PackedStringArray()) -> bool:
	if sandbox != null:
		return true
	var r := SandboxUtil.make_sandbox(self, elf, mem_mb, refs, timeout_units, extra, required)
	sandbox = r.sandbox
	reason = r.reason
	if sandbox != null:
		print("[dress-on] %s: sandbox loaded %s" % [stage_name, elf.get_file()])
	else:
		print("[dress-on] %s: %s" % [stage_name, reason])
	return sandbox != null

func available() -> bool:
	return sandbox != null

func busy() -> bool:
	return _thread != null and _thread.is_alive()

func busy_text() -> String:
	return "BUSY %s for %.1f s" % [_call, (Time.get_ticks_msec() - _t0) / 1000.0]

func heap() -> int:
	return SandboxUtil.heap(sandbox)

func take_vm_us() -> int:
	var v := vm_us
	vm_us = 0
	return v

func call_now(fn: String, args: Array = []):
	if sandbox == null:
		return "FAIL: %s missing (%s)" % [stage_name, reason]
	if busy():
		return busy_text()
	_reap()
	var t0 := Time.get_ticks_usec()
	var r = sandbox.callv("vmcall", [fn] + args)
	vm_us += Time.get_ticks_usec() - t0
	return r

func start(fn: String, args: Array = []) -> String:
	if sandbox == null:
		return "FAIL: %s missing (%s)" % [stage_name, reason]
	if busy():
		return busy_text()
	_reap()
	_thread = Thread.new()
	_call = fn
	_t0 = Time.get_ticks_msec()
	_result = null
	_thread.start(_worker.bind(fn, args))
	return "STARTED %s" % fn

func _worker(fn: String, args: Array):
	var t0 := Time.get_ticks_usec()
	var r = sandbox.callv("vmcall", [fn] + args)
	return [r, Time.get_ticks_usec() - t0]

func _reap() -> void:
	if _thread != null and not _thread.is_alive():
		var out = _thread.wait_to_finish()
		_thread = null
		_result = out[0]
		_result_ms = int(out[1] / 1000)
		vm_us += int(out[1])

# {done, result, host_ms, call}. done is true once the worker call has ended
# (and stays true, with the same result, until the next start()).
func poll() -> Dictionary:
	if busy():
		return {"done": false, "result": null, "host_ms": Time.get_ticks_msec() - _t0, "call": _call}
	_reap()
	return {"done": true, "result": _result, "host_ms": _result_ms, "call": _call}

func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
