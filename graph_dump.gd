# Gate 3 G3.graph: copy the last graph run's ggml-rd outputs out of
# ggml_test.elf (ggml_dump_list / ggml_dump_chunk) into files for the host
# oracle (tests/ggml_graph_oracle): <dir>/<arm>/<output>.f32, f32 little-endian.
# Chunks of 8 MiB: a PackedByteArray made from guest memory faults above
# 16 MiB (Gate 3 finding 3). Used by gate_ggml_graph.gd and main.gd.
extends RefCounted

const CHUNK := 8 << 20

# Returns "DUMPED <n> files <bytes> bytes to <dir>" or "FAIL ...".
static func save(sb, dir: String) -> String:
	var listing := str(sb.vmcall("ggml_dump_list"))
	var files := 0
	var total := 0
	var index := 0
	for line in listing.split("\n", false):
		var parts := line.split(" ")
		if parts.size() != 2:
			return "FAIL bad dump line '%s'" % line
		var name := parts[0]
		var size := int(parts[1])
		var path := dir.path_join(name + ".f32")
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return "FAIL cannot write %s" % path
		var off := 0
		while off < size:
			var chunk: PackedByteArray = sb.vmcall("ggml_dump_chunk", index, off, CHUNK)
			if chunk.is_empty():
				f.close()
				return "FAIL %s: empty chunk at %d of %d" % [name, off, size]
			f.store_buffer(chunk)
			off += chunk.size()
		f.close()
		files += 1
		total += size
		index += 1
	if files == 0:
		return "FAIL nothing to dump (no G3.graph run yet)"
	return "DUMPED %d files %d bytes to %s" % [files, total, dir]
