# ggml_stage -- Cut 3's ggml_test.elf: ggml-rd under test-backend-ops, the
# ggml-rd probes and the G3.graph / G3.cost runs. Moved out of cut-3's main.gd
# when it merged into the thin root; main.gd keeps a delegate for every method
# so /root/Main answers the same calls over MCP (rule 8).
#
# Its own Sandbox, created on first use, with a host-owned local
# RenderingDevice that the guest adopts. A job (test-backend-ops, or a probe)
# runs on a guest fiber; _process pumps it once per frame through
# infer_host.gd (WAIT_GPU / COOP / READ / UPLOAD / DONE / ERROR), so a sync
# always lands a frame after its submit (rule 4). gate_ggml_rd.gd is the
# gate. Every entry point has a wrapper of its own name with its arguments
# defaulted, and the gate's runs have presets; start one, then poll
# ggml_job_status() until it is not RUNNING. A job that runs ggml-cpu
# (test-backend-ops, the census probe) has every vmcall capped at ~5 minutes
# (rule 10, InferHost.GGML_CPU_TIMEOUT_UNITS).
extends Node

const InferHost := preload("res://infer_host.gd")
const GGML_TOTAL_MB := 24576  # what ggml-rd reports as device memory (Godot has no call for it)

var _ggml = null                      # the Sandbox running ggml_test.elf
var _ggml_rd: RenderingDevice = null  # the device the guest adopted
var _ggml_host = null                 # InferHost: pumps the running job
var _ggml_pumped_frame := -1          # at most one pump per frame (rule 4)

func ggml_attach(total_mb: int = GGML_TOTAL_MB) -> String:
	if _ggml != null:
		return "ATTACHED (ggml_rd_close first to re-attach)"
	var sb = ClassDB.instantiate("Sandbox")
	if sb == null:
		return "FAIL: no Sandbox class"
	_ggml = sb
	add_child(_ggml)
	_ggml.memory_max = 2048  # before program= (Gate 0F): whole test tensors live in the heap
	_ggml.program = load("res://ggml_test.elf")
	_ggml.references_max = 65536
	# Host calls are charged against it (Gate 0F finding 6); a ggml-cpu job
	# gets InferHost's 5-minute cap per vmcall instead (rule 10).
	_ggml.execution_timeout = 1000000
	_ggml_rd = RenderingServer.create_local_rendering_device()
	var r := str(_ggml.vmcall("ggml_attach", _ggml_rd, total_mb))
	_ggml_host = InferHost.new(_ggml, _ggml_rd, "ggml_pump")
	_ggml_host.state = "done"
	return r

func _ggml_started(r: String, runs_cpu: bool) -> String:
	if r.begins_with("STARTED"):
		_ggml_host.reset(runs_cpu)
	return r

func ggml_ops_start(args: String = "-o ADD,MUL -b RD0", env: String = "") -> String:
	var e := "" if _ggml != null else ggml_attach()
	if _ggml == null:
		return e
	return _ggml_started(str(_ggml.vmcall("ggml_ops_start", args, env)), InferHost.ggml_runs_cpu("ggml_ops_start"))

func ggml_probe_start(name: String = "chain", arg: String = "256", env: String = "") -> String:
	var e := "" if _ggml != null else ggml_attach()
	if _ggml == null:
		return e
	return _ggml_started(str(_ggml.vmcall("ggml_probe_start", name, arg, env)),
			InferHost.ggml_runs_cpu("ggml_probe_start", name))

# One pump, at most once per frame; _process calls it too.
func ggml_pump() -> String:
	var f := Engine.get_process_frames()
	if _ggml_host != null and _ggml_host.state == "running" and f != _ggml_pumped_frame:
		_ggml_pumped_frame = f
		_ggml_host.pump_frame()
	return ggml_job_status()

func ggml_output() -> String:
	return str(_ggml.vmcall("ggml_output")) if _ggml != null else "IDLE"

func ggml_rd_stats() -> String:
	return str(_ggml.vmcall("ggml_rd_stats")) if _ggml != null else "IDLE"

func ggml_rd_close() -> String:
	if _ggml == null:
		return "IDLE"
	var r := str(_ggml.vmcall("ggml_rd_close"))
	if r.begins_with("CLOSED"):
		_ggml.queue_free()
		_ggml = null
		_ggml_host = null
		if _ggml_rd != null:
			_ggml_rd.free()
			_ggml_rd = null
	return r

# "RUNNING ...", "DONE ..." or "ERROR ...", with the pump counters.
func ggml_job_status() -> String:
	if _ggml_host == null:
		return "IDLE"
	return "%s %s%s" % [_ggml_host.state.to_upper(), _ggml_host.summary(),
			(" " + _ggml_host.text) if _ggml_host.text != "" else ""]

# The gate's runs (gate_ggml_rd.gd), as presets.
func ggml_ops_add_mul() -> String: return ggml_ops_start("-o ADD,MUL -b RD0", "")
func ggml_ops_barrier_all() -> String: return ggml_ops_start("-o ADD,MUL -b RD0", "GGML_RD_BARRIER_ALL=1")
func ggml_ops_fault() -> String: return ggml_ops_start("-o ADD -b RD0", "GGML_RD_FAULT=1")  # must FAIL
func ggml_probe_chain() -> String: return ggml_probe_start("chain", "256", "")
func ggml_probe_independent() -> String: return ggml_probe_start("independent", "64", "")
func ggml_probe_alias_rw() -> String: return ggml_probe_start("alias", "rw", "")
func ggml_probe_alias_ro() -> String: return ggml_probe_start("alias", "ro", "")  # the control: must lose counts
# Families K1/K5 (census_ggml_rd.gd): the census rows vs ggml-cpu, their
# fault control, and the timed runs (row 0 is the timing floor).
func ggml_ops_k1k5() -> String: return ggml_ops_start("-o SILU,GELU,GELU_ERF,SIGMOID,NEG,SCALE,DIAG_MASK_INF,ROPE -b RD0", "")
func ggml_probe_census() -> String: return ggml_probe_start("census", "all", "")
func ggml_probe_census_fault() -> String: return ggml_probe_start("census", "all", "GGML_RD_FAULT=1")  # every row must FAIL
func ggml_probe_perf() -> String: return ggml_probe_start("perf", "all", "")
# The data-movement family (CPY/DUP/CONT, GET_ROWS, CONCAT, REPEAT).
func ggml_ops_move() -> String: return ggml_ops_start("-o CPY,DUP,CONT,GET_ROWS,CONCAT,REPEAT -b RD0", "")
func ggml_ops_move_fault() -> String: return ggml_ops_start("-o DUP,CONT,GET_ROWS,CONCAT,REPEAT -p ^(?!type=i32,) -b RD0", "GGML_RD_FAULT=1")  # must FAIL
func ggml_probe_perf_move() -> String: return ggml_probe_start("perf", "move", "")  # GPU time per op, hot shapes
# Family K7 (IM2COL, CONV_3D).
func ggml_ops_conv() -> String: return ggml_ops_start("-o IM2COL,CONV_3D -b RD0", "")
func ggml_ops_conv_fault() -> String: return ggml_ops_start("-o IM2COL,CONV_3D -b RD0", "GGML_RD_FAULT=1")  # must FAIL
func ggml_probe_conv_perf() -> String: return ggml_probe_start("conv_perf", "all", "")
# Families K3/K4 (NORM, RMS_NORM, MEAN, SOFT_MAX), K6 (MUL_MAT), K8
# (FLASH_ATTN_EXT), and every op of Gate 3 at once (the census's 22, DUP, MEAN).
func ggml_ops_rows() -> String: return ggml_ops_start("-o NORM,RMS_NORM,MEAN,SOFT_MAX -b RD0", "")
func ggml_probe_rows_perf() -> String: return ggml_probe_start("rows_perf", "", "")
func ggml_ops_mul_mat() -> String: return ggml_ops_start("-o MUL_MAT -b RD0", "")
func ggml_probe_mm_perf() -> String: return ggml_probe_start("mm_perf", "all", "")
func ggml_ops_flash_attn() -> String: return ggml_ops_start("-o FLASH_ATTN_EXT -b RD0", "")
func ggml_probe_fa_perf() -> String: return ggml_probe_start("fa_perf", "4096,4096,20", "")  # D=128, 12 heads, f32
func ggml_ops_all() -> String: return ggml_ops_start("-o ADD,MUL,CPY,DUP,CONT,GET_ROWS,CONCAT,REPEAT,MUL_MAT,FLASH_ATTN_EXT,IM2COL,CONV_3D,NORM,RMS_NORM,MEAN,SOFT_MAX,SILU,GELU,GELU_ERF,SIGMOID,NEG,SCALE,DIAG_MASK_INF,ROPE -b RD0", "")
# G3.graph and G3.cost (gate_ggml_graph.gd): the apps' own graphs on random
# weights on ggml-rd only (the guest runs no CPU reference), and the
# per-graph cost. A graph run's outputs go to the host with ggml_graph_dump;
# tests/ggml_graph_oracle compares them there (ggml-vulkan / host ggml-cpu).
# The DiT block runs at 8^3 tokens here (this Sandbox's 2 GB heap); the gate
# runs 16^3 = 4096 with a 3.6 GB one.
func ggml_graph_qwen() -> String: return ggml_probe_start("graph", "qwen", "")
func ggml_graph_sconv() -> String: return ggml_probe_start("graph", "sconv", "")
func ggml_graph_dit() -> String: return ggml_probe_start("graph", "dit:8", "")
func ggml_graph_kimodo_denoiser() -> String: return ggml_probe_start("graph", "kimodo_denoiser", "")
func ggml_graph_kimodo_text() -> String: return ggml_probe_start("graph", "kimodo_text", "")
# The last graph run's dumped outputs ("name bytes" lines).
func ggml_dump_list() -> String:
	return str(_ggml.vmcall("ggml_dump_list")) if _ggml != null else "IDLE"
# Bytes [offset, offset + bytes) of dumped output `index` (at most 8 MiB a
# call); ggml_graph_dump reads them all through graph_dump.gd.
func ggml_dump_chunk(index: int = 0, offset: int = 0, bytes: int = 4096) -> PackedByteArray:
	return _ggml.vmcall("ggml_dump_chunk", index, offset, bytes) if _ggml != null else PackedByteArray()
# Write them for the oracle: user://graph-dump/<arm>/<output>.f32.
func ggml_graph_dump() -> String:
	if _ggml == null:
		return "IDLE"
	if _ggml_host != null and _ggml_host.state == "running":
		return "BUSY a job is running"
	return preload("res://graph_dump.gd").save(_ggml, ProjectSettings.globalize_path("user://graph-dump"))
func ggml_cost_decode() -> String: return ggml_probe_start("cost", "decode:5", "")
func ggml_cost_dit() -> String: return ggml_probe_start("cost", "dit:3", "")
func ggml_probe_files() -> String:
	var path := ProjectSettings.globalize_path("user://ggml_upload_probe.f32")
	var f := FileAccess.open(path, FileAccess.WRITE)
	for i in 4096:
		f.store_float(0.5 * i - 7.25)
	f.close()
	return ggml_probe_start("files", path, "")

func _process(_delta: float) -> void:
	if _ggml_host != null and _ggml_host.state == "running":
		ggml_pump()
