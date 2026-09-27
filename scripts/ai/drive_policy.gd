class_name DrivePolicy
extends RefCounted
## A driving network trained by tools/rl (tools/rl/train.py writes it as JSON): a tanh MLP from a
## DriveSense observation to one group of logits per DriveHands action group (steer, pedal, hand).
## act() takes the likeliest option of each group, or samples them when given a generator.

const FORMAT := "sakura-drive-policy"

var obs_size: int = 0
var action_dims := PackedInt32Array()
## Hidden layers then the logit head: {"in", "out", "w" (out x in, row-major), "b"}.
var layers: Array[Dictionary] = []
## Training facts written by train.py (run, steps, routes, ...).
var meta: Dictionary = {}
var path: String = ""

var _buf_a := PackedFloat32Array()
var _buf_b := PackedFloat32Array()


## Loads a policy file (a relative path is taken from the project root, as on a command line);
## null (with an error) if it is missing, malformed or expects another DriveSense / DriveHands
## layout.
static func load_file(file_path: String) -> DrivePolicy:
	if file_path.is_relative_path():
		file_path = "res://" + file_path
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(file_path))
	if typeof(data) != TYPE_DICTIONARY or data.get("format", "") != FORMAT:
		push_error("DrivePolicy: %s is not a %s file" % [file_path, FORMAT])
		return null
	if int(data.get("sense_version", -1)) != DriveSense.VERSION or int(data.get("obs_size", -1)) != DriveSense.OBS_SIZE:
		push_error("DrivePolicy: %s was trained for DriveSense v%s (%s inputs), this build has v%d (%d)" % [
				file_path, data.get("sense_version"), data.get("obs_size"), DriveSense.VERSION, DriveSense.OBS_SIZE])
		return null
	if PackedInt32Array(data.get("action_dims", [])) != PackedInt32Array(DriveHands.ACTION_DIMS):
		push_error("DrivePolicy: %s has actions %s, DriveHands has %s" % [file_path, data.get("action_dims"), DriveHands.ACTION_DIMS])
		return null
	var p := DrivePolicy.new()
	p.path = file_path
	p.obs_size = int(data["obs_size"])
	p.action_dims = PackedInt32Array(data["action_dims"])
	p.meta = data.get("meta", {})
	var widest := p.obs_size
	var width := p.obs_size
	for l: Dictionary in data["layers"] + [data["head"]]:
		var layer := {
			"in": int(l["in"]),
			"out": int(l["out"]),
			"w": PackedFloat32Array(l["w"]),
			"b": PackedFloat32Array(l["b"]),
		}
		if layer["in"] != width or (layer["w"] as PackedFloat32Array).size() != layer["in"] * layer["out"] \
				or (layer["b"] as PackedFloat32Array).size() != layer["out"]:
			push_error("DrivePolicy: %s has a malformed layer" % file_path)
			return null
		p.layers.append(layer)
		width = layer["out"]
		widest = maxi(widest, width)
	var total := 0
	for n in p.action_dims:
		total += n
	if width != total:
		push_error("DrivePolicy: %s ends in %d logits for %d options" % [file_path, width, total])
		return null
	p._buf_a.resize(widest)
	p._buf_b.resize(widest)
	return p


## The network's output for one observation: sum(action_dims) logits, group after group.
func logits(obs: PackedFloat32Array) -> PackedFloat32Array:
	var x := _buf_a
	var y := _buf_b
	for i in obs_size:
		x[i] = obs[i]
	var last := layers.size() - 1
	for li in layers.size():
		var l: Dictionary = layers[li]
		var n_in: int = l["in"]
		var n_out: int = l["out"]
		var w: PackedFloat32Array = l["w"]
		var b: PackedFloat32Array = l["b"]
		for o in n_out:
			var s := b[o]
			var row := o * n_in
			for i in n_in:
				s += w[row + i] * x[i]
			y[o] = s if li == last else tanh(s)
		var t := x
		x = y
		y = t
	return x.slice(0, (layers[last]["out"] as int))


## One decision: an option index per action group. With `rng` the options are sampled by the
## network's probabilities (a looser driver) instead of taking the likeliest.
func act(obs: PackedFloat32Array, rng: RandomNumberGenerator = null) -> PackedInt32Array:
	var z := logits(obs)
	var out := PackedInt32Array()
	out.resize(action_dims.size())
	var start := 0
	for g in action_dims.size():
		var n := action_dims[g]
		var best := 0
		if rng == null:
			for k in range(1, n):
				if z[start + k] > z[start + best]:
					best = k
		else:
			var top := z[start]
			for k in range(1, n):
				top = maxf(top, z[start + k])
			var total := 0.0
			for k in n:
				total += exp(z[start + k] - top)
			var pick := rng.randf() * total
			best = n - 1
			for k in n:
				pick -= exp(z[start + k] - top)
				if pick <= 0.0:
					best = k
					break
		out[g] = best
		start += n
	return out
