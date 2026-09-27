class_name ReplayWriter
extends RefCounted
## One car's replay being written, in ReplayFormat's layout (docs/REPLAYS.md): frames taken from
## the car itself, events, and the blocks a file is made of after ReplayFormat.header_bytes().
## The Replays autoload writes the player's drives with one; tools that drive cars of their own
## use one per car (tools/rl/swarm.gd: the AI's practice runs, played back by ReplayGhost).

const F := preload("res://scripts/game/replay_format.gd")
## Road samples searched around the last one per frame for the route distance.
const SEARCH_WINDOW := 12

## The route the frames measure distance and lateral offset on (null: none).
var track: Track
## Road sample of the last frame; -1 finds the car on the whole road at the next frame (set it
## after a teleport).
var hint: int = -1
## The camera stored with each frame: the id of its "camera" event (NO_CAMERA: none), its
## transform, vertical FOV, and the replay time it was sampled at.
var cam_id: int = F.NO_CAMERA
var cam_xf := Transform3D.IDENTITY
var cam_fov: float = 70.0
var cam_t: float = 0.0
## Frames written in all, and the raw bytes of every block taken.
var frames_written: int = 0
var bytes_taken: int = 0

var _fbuf := PackedByteArray()
var _flen: int = 0
var _ebuf := PackedByteArray()
var _elen: int = 0
var _surfaces: Dictionary = {} ## surface name -> id (1-based in frames)


## `block_frames`: frames the buffer holds before it grows.
func _init(road: Track = null, block_frames: int = 608) -> void:
	track = road
	_fbuf.resize(block_frames * F.FRAME_SIZE)
	_ebuf.resize(16 * 1024)


## Appends the frame at replay time `t` (s): `car`'s inputs, pose, velocities, drivetrain and
## wheels, where it is on `track`, and the Game state, button bits (ReplayFormat.BUTTONS) and
## race clock given.
func frame(t: float, car: Car, state: int, buttons: int = 0, checkpoint: int = 0, elapsed: float = 0.0,
		running: bool = false) -> void:
	if _fbuf.size() < _flen + F.FRAME_SIZE:
		_fbuf.resize(_fbuf.size() * 2)
	# Written straight into the member: a local copy of a packed array would copy on write.
	var o := _flen
	var pos := car.global_position
	var vel := car.linear_velocity
	var flags := 0
	if car.controlled_by_player:
		flags |= F.F_PLAYER
	if car.launch_hold:
		flags |= F.F_LAUNCH_HOLD
	if car.is_shifting:
		flags |= F.F_SHIFTING
	if car.player_input.analog_steer:
		flags |= F.F_ANALOG
	if running:
		flags |= F.F_RUNNING
	var s := -1.0
	var lat := 0.0
	var half := 0.0
	if track != null:
		hint = track.nearest(pos, hint, SEARCH_WINDOW) if hint >= 0 else track.nearest(pos)
		s = track.progress_of(hint, pos)
		lat = track.lateral(hint, pos)
		half = track.half_width(hint)
		if absf(lat) <= half:
			flags |= F.F_ON_ROAD
	_fbuf.encode_float(o + F.O_T, t)
	_fbuf.encode_u16(o + F.O_BUTTONS, buttons)
	_fbuf.encode_u16(o + F.O_FLAGS, flags)
	_fbuf[o + F.O_STATE] = clampi(state, 0, 255)
	_fbuf.encode_s8(o + F.O_GEAR, clampi(car.gear, -127, 127))
	_fbuf.encode_s8(o + F.O_IN_STEER, int(roundf(clampf(car.input_steer, -1.0, 1.0) * 127.0)))
	_fbuf[o + F.O_IN_THROTTLE] = int(roundf(clampf(car.input_throttle, 0.0, 1.0) * 255.0))
	_fbuf[o + F.O_IN_BRAKE] = int(roundf(clampf(car.input_brake, 0.0, 1.0) * 255.0))
	_fbuf.encode_s8(o + F.O_STEER, int(roundf(clampf(car.steer, -1.0, 1.0) * 127.0)))
	_fbuf[o + F.O_HANDBRAKE] = int(roundf(clampf(car.handbrake, 0.0, 1.0) * 255.0))
	_fbuf[o + F.O_GROUNDED] = clampi(car.grounded_wheels, 0, 255)
	_fbuf.encode_float(o + F.O_POS, pos.x)
	_fbuf.encode_float(o + F.O_POS + 4, pos.y)
	_fbuf.encode_float(o + F.O_POS + 8, pos.z)
	F.quat_encode(_fbuf, o + F.O_ROT, car.global_basis.get_rotation_quaternion())
	_fbuf.encode_half(o + F.O_LIN, vel.x)
	_fbuf.encode_half(o + F.O_LIN + 2, vel.y)
	_fbuf.encode_half(o + F.O_LIN + 4, vel.z)
	var ang := car.angular_velocity
	_fbuf.encode_half(o + F.O_ANG, ang.x)
	_fbuf.encode_half(o + F.O_ANG + 2, ang.y)
	_fbuf.encode_half(o + F.O_ANG + 4, ang.z)
	_fbuf.encode_u16(o + F.O_RPM, clampi(int(car.rpm), 0, 65535))
	_fbuf.encode_half(o + F.O_KMH, car.speed_kmh)
	_fbuf.encode_half(o + F.O_SLIP, car.body_slip)
	for w in 4:
		var ws: WheelState = car.wheels[w]
		var wo := o + F.O_WHEELS + w * F.WHEEL_SIZE
		_fbuf[wo + F.W_SURFACE] = _surface_id(ws.surface, t) if ws.contact else 0
		_fbuf[wo + F.W_COMPRESSION] = int(roundf(clampf(ws.compression, 0.0, 1.0) * 255.0))
		_fbuf.encode_u16(wo + F.W_SPIN_ANGLE, int(fposmod(ws.spin_angle, TAU) / TAU * 65536.0) & 0xffff)
		_fbuf.encode_half(wo + F.W_SPIN_SPEED, ws.spin_speed)
		_fbuf.encode_half(wo + F.W_STEER, ws.steer_angle)
		_fbuf.encode_half(wo + F.W_OFFSET, ws.offset_y)
	_fbuf.encode_float(o + F.O_S, s)
	_fbuf.encode_half(o + F.O_LAT, lat)
	_fbuf[o + F.O_HALF] = clampi(int(roundf(half * 10.0)), 0, 255)
	_fbuf[o + F.O_CHECKPOINT] = clampi(checkpoint, 0, 255)
	_fbuf[o + F.O_CAMERA] = cam_id
	_fbuf[o + F.O_PAD] = 0
	_fbuf.encode_float(o + F.O_ELAPSED, elapsed)
	var cam := cam_xf.origin - pos
	_fbuf.encode_half(o + F.O_CAM_POS, cam.x)
	_fbuf.encode_half(o + F.O_CAM_POS + 2, cam.y)
	_fbuf.encode_half(o + F.O_CAM_POS + 4, cam.z)
	F.quat_encode(_fbuf, o + F.O_CAM_ROT, cam_xf.basis.get_rotation_quaternion())
	_fbuf.encode_half(o + F.O_CAM_FOV, cam_fov)
	_fbuf.encode_half(o + F.O_CAM_DT, cam_t - t)
	_flen += F.FRAME_SIZE
	frames_written += 1


## Appends event `e` ({"type": ..., ...}) at replay time `t`.
func event(t: float, e: Dictionary) -> void:
	_elen = F.append_event(_ebuf, _elen, t, e)


## Raw bytes written since the last take_block().
func pending_bytes() -> int:
	return _flen + _elen


## The frames and events written since the last call, as ReplayFormat.block_bytes() takes them:
## {frames, count, events}; empty when there are none.
func take_block() -> Dictionary:
	if _flen == 0 and _elen == 0:
		return {}
	var block := {"frames": _fbuf.slice(0, _flen), "count": _flen / F.FRAME_SIZE, "events": _ebuf.slice(0, _elen)}
	bytes_taken += _flen + _elen
	_flen = 0
	_elen = 0
	return block


## Route distance of `pos` at the last frame's road sample (-1 without a track or a frame).
func route_s(pos: Vector3) -> float:
	return track.progress_of(hint, pos) if track != null and hint >= 0 else -1.0


func _surface_id(surface: StringName, t: float) -> int:
	var id: int = _surfaces.get(surface, 0)
	if id == 0:
		id = _surfaces.size() + 1
		_surfaces[surface] = id
		event(t, {"type": "surface", "id": id - 1, "name": String(surface)})
	return id
