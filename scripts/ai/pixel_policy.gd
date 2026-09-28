class_name PixelPolicy
extends RefCounted
## The pixel driver's network (docs/PIXELS.md §7-8), trained by tools/rl_pixels/train_pixels.py and
## written by its `export` phase, run on the GPU in compute shaders (shaders/ai/): it reads a
## DriveEyes frame straight from its viewport texture, so no picture comes back to the CPU, only
## the 12 logits. The Nature CNN on the 128x72 frame, then with 21 floats (DriveSense's motion and
## hands, the last choice one-hot) to one logit per DriveHands option.
##
## request() records one forward pass into the frame being built; the logits come back with the
## GPU some frames later (RenderingDevice.buffer_get_data_async) and take() hands them over.
## Needs a RenderingDevice (Forward+ or Mobile): load_file() returns null headless or on the
## Compatibility renderer. Its owner (a node, never an engine-lifetime singleton) calls release()
## when it leaves the tree: a RefCounted cannot free its RIDs itself, `self` is already null in
## its predelete notification.

const INPUT_SHADER := "res://shaders/ai/pixel_input.glsl"
const CONV_SHADER := "res://shaders/ai/pixel_conv.glsl"
const DENSE_SHADER := "res://shaders/ai/pixel_dense.glsl"
const FORMAT := "sakura_pixel_driver"
## Answers nobody took (their pilot left) are dropped this many requests later.
const KEEP_RESULTS := 16

var path: String
var meta: Dictionary = {}
var size := Vector2i(128, 72)
var vec_size: int = 21
var action_dims := PackedInt32Array([7, 3, 2])
## Largest difference between these logits and torch's on the file's test frame (NAN: no test).
var check_error: float = NAN

var _rd: RenderingDevice
## Every RID made here but the shaders, freed newest first (sets before their buffers).
var _rids: Array[RID] = []
var _shaders: Array[RID] = []
var _input_shader: RID
var _input_pipeline: RID
var _sampler: RID
var _input_buf: RID
## The input uniform set and the texture it reads (a viewport's texture can be made anew).
var _input_set: RID
var _input_tex: RID
var _to_srgb: int = 0
## Per layer after the input: {pipeline, uniforms, push: PackedByteArray, groups: int}.
var _passes: Array[Dictionary] = []
## The floats' buffer (the output of the layer before the one they join) and their offset in it.
var _vec_buf: RID
var _vec_at: int = 0
var _logits_buf: RID
var _next_ticket: int = 1
var _results: Dictionary = {}


## The network in `file` (project-relative, res:// or absolute), checked against its test frame;
## null with an error when it cannot run here.
static func load_file(file: String) -> PixelPolicy:
	var p := file if file.begins_with("res://") or file.begins_with("user://") or file.is_absolute_path() \
			else "res://" + file
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		push_error("PixelPolicy: no RenderingDevice (headless, or the Compatibility renderer)")
		return null
	if not FileAccess.file_exists(p):
		push_error("PixelPolicy: no file %s" % p)
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not data is Dictionary or str((data as Dictionary).get("format", "")) != FORMAT:
		push_error("PixelPolicy: %s is not a %s file" % [p, FORMAT])
		return null
	var policy := PixelPolicy.new()
	policy.path = p
	if not policy._build(rd, data):
		policy.release()
		return null
	policy.check(data.get("test", {}))
	return policy


func _build(rd: RenderingDevice, data: Dictionary) -> bool:
	_rd = rd
	meta = data.get("meta", {})
	var shape: Array = data["image"]
	size = Vector2i(int(shape[1]), int(shape[0]))
	vec_size = int(data["vec"])
	action_dims = PackedInt32Array(data["action_dims"])
	_input_shader = _shader(INPUT_SHADER)
	var conv := _shader(CONV_SHADER)
	var dense := _shader(DENSE_SHADER)
	if not (_input_shader.is_valid() and conv.is_valid() and dense.is_valid()):
		return false
	_input_pipeline = _keep(rd.compute_pipeline_create(_input_shader))
	var conv_pipeline := _keep(rd.compute_pipeline_create(conv))
	var dense_pipeline := _keep(rd.compute_pipeline_create(dense))
	var state := RDSamplerState.new()
	state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	_sampler = _keep(rd.sampler_create(state))
	_input_buf = _floats(3 * size.x * size.y)

	var src := _input_buf
	var layers: Array = data["layers"]
	for li in layers.size():
		var l: Dictionary = layers[li]
		var w := _data(Marshalls.base64_to_raw(str(l["w"])))
		var b := _data(Marshalls.base64_to_raw(str(l["b"])))
		var ints: PackedInt32Array
		var n_out: int
		var dst: RID
		var pipeline: RID
		var shader: RID
		if l["type"] == "conv":
			n_out = int(l["out"]) * int(l["out_h"]) * int(l["out_w"])
			dst = _floats(n_out)
			ints = PackedInt32Array([l["in"], l["in_h"], l["in_w"], l["out"], l["out_h"], l["out_w"], l["k"], l["stride"]])
			pipeline = conv_pipeline
			shader = conv
		else:
			n_out = int(l["out"])
			# The layer the floats join (vec_at: where they sit in its input) reads a buffer longer
			# than this layer's output: this layer writes its front, the floats go behind.
			var next: Dictionary = layers[li + 1] if li + 1 < layers.size() else {}
			var joins := next.has("vec_at")
			dst = _floats(int(next["in"]) if joins else n_out)
			if joins:
				_vec_buf = dst
				_vec_at = int(next["vec_at"])
			if li == layers.size() - 1:
				_logits_buf = dst
			ints = PackedInt32Array([l["in"], n_out, 0, 0, 1 if l.get("relu", false) else 0, 0, 0, 0])
			pipeline = dense_pipeline
			shader = dense
		var uniforms := _keep(rd.uniform_set_create([_storage(0, src), _storage(1, w), _storage(2, b), _storage(3, dst)], shader, 0))
		_passes.append({"pipeline": pipeline, "uniforms": uniforms, "push": ints.to_byte_array(), "groups": ceili(n_out / 64.0)})
		src = dst
	if not _logits_buf.is_valid() or not _vec_buf.is_valid():
		push_error("PixelPolicy: %s has no dense head that takes the floats" % path)
		return false
	return true


## Records one forward pass on `texture` (a RenderingDevice texture: DriveEyes.texture_rd()) with
## the floats `vec`, drawn after everything already recorded this frame; returns the ticket
## take() answers once the logits are back.
func request(texture: RID, vec: PackedFloat32Array) -> int:
	_record(texture, vec)
	var ticket := _next_ticket
	_next_ticket += 1
	_rd.buffer_get_data_async(_logits_buf, _on_logits.bind(ticket))
	return ticket


## The logits of `ticket` once the GPU has them (then forgotten), empty before.
func take(ticket: int) -> PackedFloat32Array:
	if not _results.has(ticket):
		return PackedFloat32Array()
	var z: PackedFloat32Array = _results[ticket]
	_results.erase(ticket)
	return z


## One forward pass waited for (it stalls for the GPU): for checks, never per frame in the game.
func logits_now(texture: RID, vec: PackedFloat32Array) -> PackedFloat32Array:
	_record(texture, vec)
	return _rd.buffer_get_data(_logits_buf).to_float32_array()


## The network's input from `texture` (channel-major, 0..1), waited for: for checks.
func input_now(texture: RID) -> PackedFloat32Array:
	_record(texture, PackedFloat32Array())
	return _rd.buffer_get_data(_input_buf).to_float32_array()


## The likeliest option of every group.
func best(logits: PackedFloat32Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	var o := 0
	for d in action_dims:
		var k := 0
		for i in d:
			if logits[o + i] > logits[o + k]:
				k = i
		out.append(k)
		o += d
	return out


## Runs the file's test frame (uploaded as a texture) and compares with the logits torch gave it.
func check(test: Dictionary) -> void:
	if test.is_empty():
		return
	var img := Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGB8, Marshalls.base64_to_raw(str(test["image"])))
	img.convert(Image.FORMAT_RGBA8)
	var fmt := RDTextureFormat.new()
	fmt.width = size.x
	fmt.height = size.y
	fmt.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	fmt.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	var tex := _rd.texture_create(fmt, RDTextureView.new(), [img.get_data()])
	var z := logits_now(tex, PackedFloat32Array(test["vec"]))
	var want: Array = test["logits"]
	check_error = 0.0
	for i in want.size():
		check_error = maxf(check_error, absf(z[i] - float(want[i])))
	_forget_input_set()
	_rd.free_rid(tex)


## Frees every GPU resource; the policy is unusable after it.
func release() -> void:
	if _rd == null:
		return
	_forget_input_set()
	for i in range(_rids.size() - 1, -1, -1):
		_rd.free_rid(_rids[i])
	for s in _shaders:
		_rd.free_rid(s)
	_rids.clear()
	_shaders.clear()
	_passes.clear()
	_rd = null


## The input pass and every layer, one compute list each: the RenderingDevice orders them and
## puts the barriers between them (each reads what the one before wrote).
func _record(texture: RID, vec: PackedFloat32Array) -> void:
	_bind_input(texture)
	if not vec.is_empty():
		var bytes := vec.to_byte_array()
		_rd.buffer_update(_vec_buf, _vec_at * 4, bytes.size(), bytes)
	var push := PackedInt32Array([size.x, size.y, _to_srgb, 0]).to_byte_array()
	var cl := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(cl, _input_pipeline)
	_rd.compute_list_bind_uniform_set(cl, _input_set, 0)
	_rd.compute_list_set_push_constant(cl, push, push.size())
	_rd.compute_list_dispatch(cl, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	_rd.compute_list_end()
	for p in _passes:
		var bytes: PackedByteArray = p["push"]
		cl = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(cl, p["pipeline"])
		_rd.compute_list_bind_uniform_set(cl, p["uniforms"], 0)
		_rd.compute_list_set_push_constant(cl, bytes, bytes.size())
		_rd.compute_list_dispatch(cl, p["groups"], 1, 1)
		_rd.compute_list_end()


## The input uniform set for `texture`, made again when the texture changed. A texture stored as
## sRGB reads back linear: then the input shader encodes it again.
func _bind_input(texture: RID) -> void:
	if texture == _input_tex and _rd.uniform_set_is_valid(_input_set):
		return
	_forget_input_set()
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	u.binding = 0
	u.add_id(_sampler)
	u.add_id(texture)
	_input_set = _rd.uniform_set_create([u, _storage(1, _input_buf)], _input_shader, 0)
	_input_tex = texture
	var f := _rd.texture_get_format(texture).format
	_to_srgb = 1 if f in [RenderingDevice.DATA_FORMAT_R8G8B8A8_SRGB, RenderingDevice.DATA_FORMAT_B8G8R8A8_SRGB] else 0


func _forget_input_set() -> void:
	if _input_set.is_valid() and _rd.uniform_set_is_valid(_input_set):
		_rd.free_rid(_input_set)
	_input_set = RID()
	_input_tex = RID()


func _on_logits(data: PackedByteArray, ticket: int) -> void:
	_results[ticket] = data.to_float32_array()
	_results.erase(ticket - KEEP_RESULTS)


func _shader(file: String) -> RID:
	var src := load(file) as RDShaderFile
	var spirv: RDShaderSPIRV = src.get_spirv() if src != null else null
	if spirv == null or spirv.compile_error_compute != "":
		push_error("PixelPolicy: %s: %s" % [file, spirv.compile_error_compute if spirv != null else "not imported"])
		return RID()
	var s := _rd.shader_create_from_spirv(spirv, file.get_file())
	_shaders.append(s)
	return s


func _floats(n: int) -> RID:
	var bytes := PackedByteArray()
	bytes.resize(n * 4)
	return _data(bytes)


func _data(bytes: PackedByteArray) -> RID:
	return _keep(_rd.storage_buffer_create(bytes.size(), bytes))


func _keep(rid: RID) -> RID:
	_rids.append(rid)
	return rid


static func _storage(binding: int, buffer: RID) -> RDUniform:
	var u := RDUniform.new()
	u.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	u.binding = binding
	u.add_id(buffer)
	return u
