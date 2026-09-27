class_name RaceBot
extends NeuralPilot
## The neural driver as a race opponent (docs/RL.md, Racing). A NeuralPilot that also knows the
## other cars: add it as a child of a Car with `track`, `pace`, `field` and `phase` set; the spawner
## sets `car.controlled_by_player = false`. It holds while `car.launch_hold` is true and drives
## from GO. On top of the network it adds, every decision:
##
##   lane    the network sees a road with the trained geometry (DriveSense.lane_half_width: a 7 m
##           carriageway plus the verge) centred `lane` metres right of the real centre line. Lane
##           room is the real half width minus 3.5 m (±1.5 m on a 10 m loop, 0 on a 7 m road);
##           the lane moves at LANE_RATE and only while the car stays within LANE_KEEP of it, so
##           the car always stays inside the road it sees. Home is lane 0, the line `pace` was
##           calibrated on. The racing line swings metres either side of the lane, but two bots'
##           lines swing alike, so bots in lanes on either side keep apart.
##   pace    a speed limit of `pace` x v_ref(s), the shipped driver's own speed along the route in
##           lane 0 (assets/ai/pace/<route>.json, recorded by tools/rl/race_probe.gd), brought
##           forward by braking at PACE_DECEL: a slower corner ahead lowers the limit early enough
##           to reach it slowed down in a straight line. The network brakes for corners at the speeds
##           it trained at, and a pace-limited car arrives slower than that, so the network alone
##           brakes too late for the lower corner speed pace asks for and the limiter would then
##           brake in the corner and run wide. Near the limit the throttle fades out, well above it
##           the brakes come on.
##   traffic the other cars of `field` in road coordinates (s, lateral, speed, lane) from
##           SEE_BEHIND_M behind to SEE_AHEAD_M ahead: brakes on the time to collision with the car
##           in its path, passes a slower car on the side with room and comes home when clear, moves
##           over for a faster car behind and never moves its lane towards a car alongside.
##   rescue  RESCUE_S more than OFF_ROAD_M past the verge, rolled, or without progress (not while
##           held up by a car ahead, so a bot on the grid never fights it) puts the car back behind
##           on its road, RESCUE_CLEAR_M from every car in `field` (further back or in another lane
##           when needed). The car's own reset is off meanwhile: it would ask the player's session.
##
## Every bot of one race needs its own `phase` (0 .. DriveHands.DECISION_TICKS - 1), so their
## networks run in different physics ticks.

const DRIVER := "res://assets/ai/driver.json"
const PACE_DIR := "res://assets/ai/pace"
## Carriageway half width of every road the network trained on.
const LANE_HALF_WIDTH := 3.5
## How fast the lane moves across the road (m/s), and how far from the car it may be moved.
const LANE_RATE := 1.2
const LANE_KEEP := 3.0
## Lane room is the narrowest road over this stretch around the car.
const ROOM_BEHIND_M := 10.0
const ROOM_AHEAD_M := 50.0
## Other cars it takes into account.
const SEE_AHEAD_M := 60.0
const SEE_BEHIND_M := 20.0
## Car size (m): bumper to bumper and body width, with some margin.
const CAR_LENGTH := 4.3
const CAR_WIDTH := 2.0
## Centre-to-centre lateral spacing at which two cars pass each other.
const SIDE_CLEAR := 2.6
## A car ahead within PASS_LOOK_M that is PASS_MARGIN m/s slower than it wants to go is passed.
const PASS_LOOK_M := 40.0
const PASS_MARGIN := 1.0
## Following distance: FOLLOW_M plus FOLLOW_S seconds at its own speed.
const FOLLOW_M := 2.0
const FOLLOW_S := 0.35
## Brake assist (_pedals()): times to collision to lift and to brake at, the deceleration needed
## to match the speed of the car ahead that brakes anyway (m/s²), and the deceleration of a full
## brake, to turn a needed deceleration into a pedal.
const LIFT_TTC_S := 1.5
const BRAKE_TTC_S := 1.0
const BRAKE_NEED := 3.0
const BRAKE_DECEL := 9.0
## Pace limiter: the braking assumed to reach a slower stretch ahead (m/s²) and how far ahead it
## looks, the band below the limit where the throttle fades, and the brake (see _pace()).
const PACE_DECEL := 4.0
const PACE_LOOK_M := 80.0
const PACE_BAND := 2.0
const PACE_BRAKE := 1.0
const PACE_BRAKE_SPAN := 4.0
const PACE_BRAKE_MAX := 0.8
## Rescue, as AutoDrive's: seconds in trouble, metres past the verge, least progress per second.
const RESCUE_S := 2.5
const OFF_ROAD_M := 3.0
const STUCK_MPS := 3.0
## Where a rescue puts the car: RESCUE_BACK_M behind, then further back RESCUE_STEP_M at a time,
## at least RESCUE_CLEAR_M from every other car and out of the way of cars coming up behind
## (RESCUE_CLEAR_S of their speed).
const RESCUE_BACK_M := 4.0
const RESCUE_STEP_M := 6.0
const RESCUE_TRIES := 12
const RESCUE_CLEAR_M := 8.0
const RESCUE_CLEAR_S := 2.0

## Speed as a share of the shipped driver's own (v_ref); pace_for_lap() finds the pace of a lap time.
var pace: float = 1.0
## Every car in the race, this one included.
var field: Array[Car] = []
## Read-only: the lane (m right of the centre line) the network is driving in now.
var lane: float:
	get:
		return sense.lane if sense != null else 0.0
## Read-only: times it put its car back on the road.
var rescues: int = 0
## Read-only: a car ahead in its path made it lift or brake at the last decision.
var held: bool = false

## The shipped driver, loaded once for every bot.
static var _driver: DrivePolicy
## Pace files by route id (see _pace_file()).
static var _pace_files: Dictionary = {}

## v_ref (m/s) every _ref_step metres of absolute road distance from the first sample.
var _ref := PackedFloat32Array()
var _ref_step: float = 2.0
var _lane_target: float = 0.0
## Other cars (instance id) -> their nearest road sample, and what _see() found this decision:
## [ds (m ahead), lateral, speed along the road, lateral speed, car] each.
var _hints: Dictionary = {}
var _near: Array[Array] = []
## A car ahead in its path holds it up (no progress is then no reason for a rescue).
var _blocked: bool = false
var _trouble: float = 0.0
var _last_s: float = NAN
var _own_reset: float = 2.5


func _ready() -> void:
	if policy == null:
		if _driver == null:
			_driver = DrivePolicy.load_file(DRIVER)
		policy = _driver
	super._ready()
	if car == null or policy == null or track == null:
		return
	sense.lane_half_width = LANE_HALF_WIDTH
	_own_reset = car.auto_reset_time
	car.auto_reset_time = INF
	_ref = _reference(track)


func _exit_tree() -> void:
	super._exit_tree()
	if car != null and is_instance_valid(car):
		car.auto_reset_time = _own_reset


func _physics_process(delta: float) -> void:
	if (Engine.get_physics_frames() + phase) % DriveHands.DECISION_TICKS == 0:
		decide(delta)
		_race(delta * DriveHands.DECISION_TICKS)
	hands.apply(car, delta)


## The pace at which `car_id` laps `route` in `lap_s` seconds (flying lap, lane 0, no traffic),
## interpolated in the calibration table of assets/ai/pace/<route>.json and clamped to its range;
## 1.0 when the route has no table.
static func pace_for_lap(route: String, lap_s: float, car_id: String = "sakura") -> float:
	var laps: Dictionary = _pace_file(route).get("laps", {})
	var rows: Array = laps.get(car_id, laps.get("sakura", []))
	if rows.is_empty():
		push_error("RaceBot: no pace calibration for %s (%s)" % [route, car_id])
		return 1.0
	# rows by pace, slowest first: the lap times fall along them
	if lap_s >= float(rows[0]["flying"]):
		return float(rows[0]["pace"])
	for k in range(1, rows.size()):
		var a: Dictionary = rows[k - 1]
		var b: Dictionary = rows[k]
		if lap_s >= float(b["flying"]):
			var t := (float(a["flying"]) - lap_s) / maxf(float(a["flying"]) - float(b["flying"]), 1e-3)
			return lerpf(float(a["pace"]), float(b["pace"]), t)
	return float(rows[rows.size() - 1]["pace"])


## assets/ai/pace/<route>.json, parsed once (v_ref as a PackedFloat32Array); {} when missing.
static func _pace_file(route: String) -> Dictionary:
	if not _pace_files.has(route):
		var path := PACE_DIR.path_join(route + ".json")
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else null
		var d: Dictionary = data if data is Dictionary else {}
		if d.has("v_ref"):
			d["v_ref"] = PackedFloat32Array(d["v_ref"])
		_pace_files[route] = d
	return _pace_files[route]


## v_ref of the pace file recorded on this very road (same length, width and first sample), or
## nothing (no limiter) for a road without one, such as a reversed loop. The width matters: a
## widened loop keeps its centre line but is driven at other speeds.
static func _reference(t: Track) -> PackedFloat32Array:
	if not DirAccess.dir_exists_absolute(PACE_DIR):
		return PackedFloat32Array()
	for f in DirAccess.get_files_at(PACE_DIR):
		if not f.ends_with(".json"):
			continue
		var d := _pace_file(f.get_basename())
		if d.has("v_ref") and bool(d["closed"]) == t.closed and absf(float(d["length"]) - t.length) < 1.0 \
				and absf(float(d["half_width"]) - t.half_width(0)) < 0.05:
			var o: Array = d["origin"]
			var p := t.point(0)
			if Vector2(p.x - float(o[0]), p.z - float(o[1])).length() < 1.0:
				return d["v_ref"]
	return PackedFloat32Array()


## Index into v_ref of absolute road distance s.
func _ref_index(s: float) -> int:
	if track.closed:
		return wrapi(int(fposmod(s, track.length) / _ref_step), 0, _ref.size())
	return clampi(int((s - track.first_s) / _ref_step), 0, _ref.size() - 1)


func _race(step: float) -> void:
	var pos := car.global_position
	var i := sense.hint
	var s := track.abs_s(i, pos)
	var lat := track.lateral(i, pos)
	var v := car.linear_velocity.dot(track.forward(i))
	var lat_v := car.linear_velocity.dot(track.right(i))
	var limit := _limit(s)
	_see(s, pos)
	_pedals(lat, lat_v, v)
	_pace(v, limit)
	_steer_lane(lat, v, limit, _room(i), step)
	_rescue(s, lat, i, step)


## The pace limit at s: pace x v_ref, brought forward by braking at PACE_DECEL over the next
## PACE_LOOK_M; INF without a reference.
func _limit(s: float) -> float:
	if _ref.is_empty():
		return INF
	var lowest := INF
	var k := _ref_index(s)
	var n := _ref.size()
	for m in int(PACE_LOOK_M / _ref_step) + 1:
		var v := pace * (_ref[wrapi(k + m, 0, n)] if track.closed else _ref[mini(k + m, n - 1)])
		lowest = minf(lowest, sqrt(v * v + 2.0 * PACE_DECEL * m * _ref_step))
	return lowest


## Lane room: how far the lane may move off the centre line, over the stretch around sample i.
func _room(i: int) -> float:
	var room := INF
	for k in range(-int(ROOM_BEHIND_M / track.spacing), int(ROOM_AHEAD_M / track.spacing) + 1):
		room = minf(room, track.half_width(i + k))
	return maxf(room - LANE_HALF_WIDTH, 0.0)


## The other cars of `field` near it, in road coordinates, into _near: [ds (m ahead), lateral,
## speed along the road, lateral speed, car, lane]. The lane is where a RaceBot means to be (its
## `lane`: the racing line swings metres either side of it, but two bots' lines swing alike), and
## the lateral position for any other car.
func _see(s: float, pos: Vector3) -> void:
	_near.clear()
	for other in field:
		if other == car or not is_instance_valid(other) or not other.is_inside_tree():
			continue
		var id := other.get_instance_id()
		var op := other.global_position
		var h: int = _hints.get(id, -1)
		if h >= 0 and op.distance_squared_to(track.point(h)) > 400.0:
			h = -1 # it was put back somewhere else
		h = track.nearest(op, h, DriveSense.SEARCH_WINDOW)
		_hints[id] = h
		if absf(op.y - pos.y) > 5.0:
			continue # on a bridge over this spot, or under one
		var ds := track.abs_s(h, op) - s
		if track.closed:
			ds = wrapf(ds, -track.length * 0.5, track.length * 0.5)
		if ds < -SEE_BEHIND_M or ds > SEE_AHEAD_M:
			continue
		var o_lat := track.lateral(h, op)
		var o_lane := o_lat
		for c in other.get_children():
			if c is RaceBot:
				o_lane = (c as RaceBot).lane
				break
		_near.append([ds, o_lat, other.linear_velocity.dot(track.forward(h)),
				other.linear_velocity.dot(track.right(h)), other, o_lane])


## Brake assist: the car in its path ahead (laterally within CAR_WIDTH now, or where both will be
## within the time to collision, up to a second: it by its lateral speed, this car by its lateral
## speed or towards the lane it is moving to) sets a following distance: closer, or LIFT_TTC_S
## from it, the throttle goes; BRAKE_TTC_S from it, or needing more than BRAKE_NEED m/s² to
## match its speed a metre short, the brakes stop it short.
func _pedals(lat: float, lat_v: float, v: float) -> void:
	var thr := hands.throttle_target
	var brk := hands.brake_target
	_blocked = false
	for o in _near:
		var ds: float = o[0]
		if ds <= 0.0:
			continue
		var gap := ds - CAR_LENGTH
		var closing: float = v - float(o[2])
		var ttc := gap / closing if closing > 0.1 else INF
		var horizon := clampf(ttc, 0.0, 1.0)
		var o_lat: float = o[1]
		var o_lat_v: float = o[3]
		var shift := lat_v * horizon
		if absf(_lane_target - lat) > 0.5:
			shift = clampf(_lane_target - lat, -LANE_RATE * horizon, LANE_RATE * horizon)
		if absf(o_lat - lat) > CAR_WIDTH and absf(o_lat + o_lat_v * horizon - lat - shift) > CAR_WIDTH:
			continue
		var follow := FOLLOW_M + FOLLOW_S * maxf(v, 0.0)
		if gap < follow + 4.0 and v < STUCK_MPS * 2.0:
			_blocked = true
		if gap < follow or ttc < LIFT_TTC_S:
			thr = 0.0
		if closing > 0.1:
			var need := closing * closing / (2.0 * maxf(gap - 1.0, 0.3))
			if need > BRAKE_NEED or ttc < BRAKE_TTC_S:
				brk = maxf(brk, clampf(need / BRAKE_DECEL, 0.2, 1.0))
	held = thr < hands.throttle_target or brk > hands.brake_target
	hands.throttle_target = thr
	hands.brake_target = brk


## Pace limiter: throttle faded out over PACE_BAND below the limit; from PACE_BRAKE above it the
## brake comes in, reaching PACE_BRAKE_MAX PACE_BRAKE_SPAN m/s further (lifting off alone slows
## the car by only 1-2 m/s², less than the braking the limit assumes).
func _pace(v: float, limit: float) -> void:
	if v > limit - PACE_BAND:
		hands.throttle_target *= clampf((limit - v) / PACE_BAND, 0.0, 1.0)
	if v > limit + PACE_BRAKE:
		hands.brake_target = maxf(hands.brake_target, clampf((v - limit - PACE_BRAKE) / PACE_BRAKE_SPAN, 0.15, PACE_BRAKE_MAX))


## Picks the lane target (home, a passing side, out of the way of a faster car behind) and moves
## the lane towards it at LANE_RATE, never towards a car alongside, and only while the car stays
## within LANE_KEEP of it (on the carriageway it sees). Cars are compared by lane (_see()).
func _steer_lane(lat: float, v: float, limit: float, room: float, step: float) -> void:
	var cur := sense.lane
	var target := 0.0
	if room > 0.3:
		var want := minf(limit, v + 10.0)
		var pass_car: Array = []
		var behind: Array = []
		for o in _near:
			var ds: float = o[0]
			var o_v: float = o[2]
			if ds > 0.0 and ds < PASS_LOOK_M and absf(float(o[5]) - _lane_target) < SIDE_CLEAR \
					and (o_v < want - PASS_MARGIN or v - o_v > PASS_MARGIN) \
					and (pass_car.is_empty() or ds < float(pass_car[0])):
				pass_car = o
			elif ds <= CAR_LENGTH and ds > -SEE_BEHIND_M and (o_v > v + 0.3 or ds > -CAR_LENGTH) \
					and (behind.is_empty() or absf(ds) < absf(float(behind[0]))):
				behind = o
		if not pass_car.is_empty():
			target = _pass_side(pass_car, room)
		elif not behind.is_empty():
			# a faster car behind or one alongside: make room on the side away from it, or while it
			# is still straight behind on the side this car is on (the side _pass_side() leaves it)
			var o_lane: float = behind[5]
			var side := (-room if o_lane > cur else room) if absf(o_lane - cur) > 0.5 else (room if cur >= 0.0 else -room)
			target = side if _side_clear(side, -SEE_BEHIND_M, CAR_LENGTH, behind[4]) else _lane_target
		elif _lane_target != 0.0 and not _side_clear(0.0, -CAR_LENGTH - 2.0, PASS_LOOK_M, null):
			target = _lane_target # home is taken for now
	for o in _near:
		var o_lane: float = o[5]
		if absf(float(o[0])) < CAR_LENGTH + 1.0 and signf(o_lane - cur) == signf(target - cur) \
				and absf(o_lane - cur) < SIDE_CLEAR + 0.5:
			target = cur # never towards a car alongside
			break
	_lane_target = target
	var next := move_toward(cur, clampf(target, -room, room), LANE_RATE * step)
	if absf(next - lat) > LANE_KEEP and absf(next - lat) > absf(cur - lat):
		next = cur
	sense.lane = next


## The side (±room) to pass `o` on: the side already chosen, else the one further from its lane
## (left of a car on the centre line, which makes room to the right), when that side is at least
## SIDE_CLEAR from it and free; else the lane it is in now (it follows, the car ahead makes room).
func _pass_side(o: Array, room: float) -> float:
	var o_lane: float = o[5]
	var gap: float = o[0]
	var first := -room if o_lane >= 0.0 else room
	if absf(_lane_target) > 0.3:
		first = signf(_lane_target) * room
	for side: float in [first, -first]:
		if absf(side - o_lane) >= SIDE_CLEAR * 0.8 and _side_clear(side, -CAR_LENGTH - 4.0, gap + 15.0, o[4]):
			return side
	return _lane_target


## True when no car but `except` has its lane within SIDE_CLEAR of `side` from `from` to `to`
## metres ahead.
func _side_clear(side: float, from: float, to: float, except: Variant) -> bool:
	for o in _near:
		if o[4] != except and float(o[0]) > from and float(o[0]) < to and absf(float(o[5]) - side) < SIDE_CLEAR:
			return false
	return true


func _rescue(s: float, lat: float, i: int, step: float) -> void:
	if car.launch_hold:
		_trouble = 0.0
		_last_s = s
		return
	var ds := 0.0 if is_nan(_last_s) else s - _last_s
	if track.closed:
		ds = wrapf(ds, -track.length * 0.5, track.length * 0.5)
	_last_s = s
	var off := absf(lat) > track.half_width(i) + track.verge + OFF_ROAD_M
	var stuck := ds < STUCK_MPS * step and not _blocked
	var rolled := car.global_basis.y.y < 0.3
	_trouble = _trouble + step if off or stuck or rolled else 0.0
	if _trouble > RESCUE_S:
		_put_back(s)


## Back on the road behind `s`, clear of every other car (see RESCUE_*), facing along it.
func _put_back(s: float) -> void:
	var room := _room(track.index_at_abs(s))
	var lats: Array[float] = [0.0]
	if room >= 1.0:
		lats.append_array([-room, room])
	var rs := s
	var rl := 0.0
	var found := false
	for k in RESCUE_TRIES:
		rs = s - RESCUE_BACK_M - k * RESCUE_STEP_M
		if not track.closed:
			rs = maxf(rs, track.first_s + 2.0)
		for l in lats:
			if _spot_clear(rs, l):
				rl = l
				found = true
				break
		if found:
			break
	car.reset_to(track.transform_at_abs(rs, rl, 0.35))
	sense.reset(rs)
	sense.lane = rl
	_lane_target = rl
	_last_pos = car.global_position
	_trouble = 0.0
	_last_s = NAN
	rescues += 1


func _spot_clear(rs: float, rl: float) -> bool:
	var p := track.position_at_abs(rs, rl)
	for other in field:
		if other == car or not is_instance_valid(other):
			continue
		var op := other.global_position
		if op.distance_to(p) < RESCUE_CLEAR_M:
			return false
		var h: int = _hints.get(other.get_instance_id(), -1)
		if h < 0:
			continue
		var ds := rs - track.abs_s(h, op)
		if track.closed:
			ds = wrapf(ds, -track.length * 0.5, track.length * 0.5)
		# a car coming up behind the spot in that lane
		if ds > 0.0 and ds < RESCUE_CLEAR_M + RESCUE_CLEAR_S * maxf(other.linear_velocity.length(), 0.0) \
				and absf(track.lateral(h, op) - rl) < SIDE_CLEAR:
			return false
	return true
