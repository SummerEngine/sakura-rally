class_name ArrivalStop
extends Node
## Brings the parent Car to rest at a pose on the road: a stage's finish stop after the finish
## line, the next stage's grid at the end of the liaison (Main adds it within braking distance,
## the player lets go there). Whatever speed the car comes in at, it steers along the road
## toward `target` and brakes on a constant-deceleration profile to rest there, or as soon as it
## can if it ran past. Stays on the car holding it at rest until Main removes it.

## Deceleration of the stop (m/s^2): a firm but unhurried stop, no lock-up.
const DECEL := 5.0
## Creep speed to the target for a car that was already slow (m/s).
const CREEP := 9.0
## Road metres of margin on top of the braking distance when Main hands over.
const MARGIN := 10.0

var track: Track
var target: Transform3D

## Road distance (Track abs s) of the target.
var _target_s := 0.0
var _car: Car
var _hint := -1
var _cap := CREEP


## Road metres a car at `speed` (m/s) needs to stop at the target under this profile.
static func stopping_distance(speed: float) -> float:
	return speed * speed / (2.0 * DECEL) + MARGIN


func _ready() -> void:
	_car = get_parent() as Car
	process_physics_priority = -10
	_cap = maxf(CREEP, _car.linear_velocity.length())
	_target_s = track.abs_s(track.nearest(target.origin), target.origin)


func _physics_process(_delta: float) -> void:
	if _car == null or track == null:
		return
	var pos := _car.global_position
	var fwd := -target.basis.z
	var speed := _car.linear_velocity.length()
	_hint = track.nearest(pos, _hint)
	# Road metres to the target (across the lap seam on a loop).
	var ahead := _target_s - track.abs_s(_hint, pos)
	if track.closed:
		ahead = wrapf(ahead, -track.length * 0.5, track.length * 0.5)
	# Metres to go: along the road before the target, along its heading past it.
	var left := ahead if ahead > 1.0 else (target.origin - pos).dot(fwd)
	# Steer: pure pursuit on the road ahead, onto the target's heading past its road end.
	var look := clampf(4.0 + speed * 0.5, 5.0, 14.0)
	var aim := track.position_at_abs(_target_s - ahead + look) if look < ahead \
			else target.origin + fwd * (look - ahead)
	var local := _car.global_transform.affine_inverse() * aim
	var alpha := atan2(local.x, -local.z)
	var k := 2.0 * sin(alpha) / maxf(Vector2(local.x, local.z).length(), 1.0)
	_car.input_steer = clampf(atan(k * Car.WHEELBASE) / _car.steer_lock_at(speed * 3.6), -1.0, 1.0) if speed > 0.3 else 0.0
	# Speed: v = sqrt(2 a d) down to rest at the target, never faster than it came in.
	var want := minf(_cap, sqrt(2.0 * DECEL * maxf(left, 0.0)))
	_car.input_handbrake = false
	if speed < 1.0 and left <= 0.8:
		# At rest: handbrake on, and the foot brake under the gearbox's hold-to-reverse threshold.
		_car.input_throttle = 0.0
		_car.input_brake = 0.3
		_car.input_handbrake = true
	elif left <= 0.5 or speed > want + 0.4:
		_car.input_throttle = 0.0
		_car.input_brake = 1.0 if left <= 0.5 else clampf((speed - want) / 3.0, 0.15, 1.0)
	else:
		_car.input_throttle = clampf((want - speed) / 4.0, 0.0, 0.35)
		_car.input_brake = 0.0
