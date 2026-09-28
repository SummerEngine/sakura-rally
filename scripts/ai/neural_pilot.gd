class_name NeuralPilot
extends Node
## Drives its parent Car with a DrivePolicy trained by tools/rl: every DriveHands.DECISION_TICKS
## physics ticks it looks through a DriveSense and asks the policy, every tick DriveHands moves
## the car's inputs - the loop tools/rl/train_env.gd trains in. Add it as a child of the car (as
## Main does with Autopilot). It never touches `controlled_by_player`: while that is true the
## player's controls overwrite what it sets, so whoever attaches it hands the car over. While
## attached it keeps the car on the automatic box (Car.always_automatic): no gear action.

## A car that moved further than this between two decisions was reset: find it on the road anew.
const JUMP_M := 20.0
## A car slower than STUCK_KMH for STUCK_S (outside a launch hold) gets full throttle, steered by
## the policy, until it passes UNSTICK_KMH. At a standstill the likeliest choice can be to wait
## with the wheel at full lock (seen at a hairpin after a reset: a state no training episode
## ends in), and a rescue puts the car back in the same spot.
const STUCK_KMH := 3.0
const STUCK_S := 1.0
const UNSTICK_KMH := 15.0

var policy: DrivePolicy
## The route being driven; set it again whenever the route changes.
var track: Track:
	set(value):
		track = value
		if sense != null:
			sense.track = value
			sense.reset()
## Sample the policy's choices instead of taking the likeliest: a looser, less repeatable driver.
var sample: bool = false
var sample_seed: int = 0
## Physics tick (of every DriveHands.DECISION_TICKS) it decides on. Give pilots on the road at the
## same time different phases, so their networks do not all run in one tick.
var phase: int = 0

var car: Car
var sense: DriveSense
var hands := DriveHands.new()
var _obs := PackedFloat32Array()
var _last_pos := Vector3.INF
var _rng: RandomNumberGenerator
var _stuck_s := 0.0
var _unsticking := false


func _ready() -> void:
	car = get_parent() as Car
	if car != null:
		car.always_automatic = true
	sense = DriveSense.new(track)
	_obs.resize(DriveSense.OBS_SIZE)
	if sample:
		_rng = RandomNumberGenerator.new()
		_rng.seed = sample_seed
	if car == null or not _has_driver() or track == null:
		push_error("%s needs a Car parent, a policy and a track" % name)
		set_physics_process(false)


## Whether it has a network to drive with (PixelPilot's is another kind).
func _has_driver() -> bool:
	return policy != null


func _exit_tree() -> void:
	if car != null and is_instance_valid(car):
		hands.release(car)
		car.always_automatic = false


func _physics_process(delta: float) -> void:
	if (Engine.get_physics_frames() + phase) % DriveHands.DECISION_TICKS == 0:
		decide(delta)
	hands.apply(car, delta)


## One decision (RaceBot wraps it): look, ask the policy, full throttle when stuck, and set the
## hands to the answer.
func decide(delta: float) -> void:
	_look(delta)
	_answer(policy.act(_obs, _rng))


## A decision's look: the DriveSense floats into _obs, and whether the car is stuck.
func _look(delta: float) -> void:
	var pos := car.global_position
	if pos.distance_squared_to(_last_pos) > JUMP_M * JUMP_M:
		sense.reset()
	_last_pos = pos
	sense.observe(car, _obs)
	var kmh := absf(car.speed_kmh)
	_stuck_s = _stuck_s + delta * DriveHands.DECISION_TICKS if kmh < STUCK_KMH and not car.launch_hold else 0.0
	if _stuck_s > STUCK_S:
		_unsticking = true
	elif kmh > UNSTICK_KMH or car.launch_hold:
		_unsticking = false


## Sets the hands to choice `a`, with full throttle and no handbrake while stuck (as of the last
## look); returns the choice they took.
func _answer(a: PackedInt32Array) -> PackedInt32Array:
	if _unsticking:
		a[1] = 2 # throttle
		a[2] = 0 # handbrake off
	hands.set_action(a[0], a[1], a[2])
	return a
