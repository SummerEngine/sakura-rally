extends Node
## Stand-in for the race session in the UI preview: the documented session properties
## (elapsed, checkpoint_index, checkpoint_total, progress, best_time, mode) plus a fake lap.
## Progress advances with the mock car's speed; checkpoints and the finish are reported through
## Game.notify_checkpoint / Game.notify_finished exactly like the real session would.

var elapsed := 0.0
var checkpoint_index := 0
var checkpoint_total := 5
var progress := 0.0
var best_time := INF
var mode := "time_trial"
var running := false

var lap_length_m := 5200.0 ## "track length": at ~110 km/h average this is ~2:30
var time_scale := 1.0 ## >1 speeds the lap up in the preview (elapsed advances faster)
var car: Node

var _splits: Array[float] = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_PAUSABLE


func begin(p_mode: String, p_best: float) -> void:
	mode = p_mode
	best_time = p_best
	elapsed = 0.0
	progress = 0.0
	checkpoint_index = 0
	_splits.clear()
	running = false


## Jump the lap forward (preview shortcut): progress and elapsed scale together.
## Checkpoints skipped over get split times interpolated along the jump.
func jump_to(p: float, at_time: float) -> void:
	var p0 := progress
	var t0 := elapsed
	while checkpoint_index < checkpoint_total and p >= _cp_at(checkpoint_index):
		var k := (_cp_at(checkpoint_index) - p0) / maxf(p - p0, 1e-4)
		elapsed = lerpf(t0, at_time, k)
		progress = _cp_at(checkpoint_index)
		_pass_checkpoint()
	progress = p
	elapsed = at_time


func _cp_at(i: int) -> float:
	return float(i + 1) / float(checkpoint_total + 1)


func _process(delta: float) -> void:
	if not running:
		return
	var game := get_tree().root.get_node("Game")
	var d := delta * time_scale
	elapsed += d
	var kmh: float = car.get("speed_kmh") if car != null else 100.0
	if mode == "time_trial":
		progress = minf(progress + kmh / 3.6 * d / lap_length_m, 1.0)
		if checkpoint_index < checkpoint_total and progress >= _cp_at(checkpoint_index):
			_pass_checkpoint()
		if progress >= 1.0:
			running = false
			var top: float = car.get("top_speed_kmh") if car != null else 0.0
			game.notify_finished({"time": elapsed, "splits": _splits.duplicate(), "top_speed_kmh": top})
			game.set_state(game.State.FINISHED)
	else:
		progress = fmod(progress + kmh / 3.6 * d / lap_length_m, 1.0)


func _pass_checkpoint() -> void:
	var game := get_tree().root.get_node("Game")
	_splits.append(elapsed)
	game.notify_checkpoint(checkpoint_index, checkpoint_total, elapsed)
	checkpoint_index += 1
