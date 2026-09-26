extends Node3D
## Minimal stand-in for scripts/vehicle/car.gd that implements the car runtime API from
## docs/CONTRACTS.md with a toy drivetrain (6-speed box, turbo lag, wheelspin, limiter),
## so CarAudio can be exercised and recorded without the physics slice.
## Driven by setting input_* and the scripted fields below from a test driver.
## User arg `--na4` makes it the Hayate: engine_sound &"na4", 1000-8000 rpm, no turbo.

signal gear_changed(new_gear: int, old_gear: int)
signal backfire
signal rev_limiter
signal impact(strength: float, point: Vector3)
signal landed(strength: float)


const RATIOS: Array[float] = [3.4, 2.3, 1.7, 1.35, 1.1, 0.92]
const FINAL_DRIVE := 4.1
const WHEEL_RADIUS := 0.33
const MASS := 1250.0

# Car API state
var rpm: float = 900.0
var idle_rpm: float = 900.0
var max_rpm: float = 7800.0
var throttle: float = 0.0
var brake: float = 0.0
var handbrake: float = 0.0
var steer: float = 0.0
var gear: int = 0
var is_shifting: bool = false
var boost: float = 0.0
var speed_kmh: float = 0.0
var airborne_time: float = 0.0
var wheels: Array = []
var engine_sound: StringName = &"turbo4"
var turbo: bool = true

# Control inputs
var input_throttle: float = 0.0
var input_brake: float = 0.0
var input_steer: float = 0.0
var input_handbrake: bool = false
var controlled_by_player: bool = true

# Test-driver knobs
var auto_shift: bool = true
var shift_rpm: float = 7200.0
var extra_slip: float = 0.0 ## added to every wheel's combined slip (slides, wheelspin)
var airborne: bool = false
var emit_pops: bool = true ## overrun backfire signals (off for the click-detector run)

var _speed: float = 0.0 ## m/s
var _shift_timer: float = 0.0
var _pending_gear: int = 0
var _limiter_cut: float = 0.0
var _ecu_timer: float = 0.0


func _init() -> void:
	for i in 4:
		var w := WheelState.new() # the car's own per-wheel record (scripts/vehicle/wheel_state.gd)
		w.contact = true
		w.surface = &"gravel"
		w.load = 3065.0
		w.compression = 0.5
		wheels.append(w)
	# Read here, not in the driver: CarAudio (a child) picks its set in its own _ready,
	# which runs before any parent's _ready.
	if "--na4" in OS.get_cmdline_user_args():
		engine_sound = &"na4"
		turbo = false
		idle_rpm = 1000.0
		rpm = idle_rpm
		max_rpm = 8000.0
		shift_rpm = 7600.0


func set_surface(surface: StringName) -> void:
	for w in wheels:
		w.surface = surface


func shift_up() -> void:
	_request_gear(mini(gear + 1, RATIOS.size()))


func shift_down() -> void:
	_request_gear(maxi(gear - 1, 0))


func set_gear_now(g: int) -> void:
	_request_gear(g)


func reset_to(xform: Transform3D) -> void:
	global_transform = xform
	_speed = 0.0


func set_livery(_primary: Color, _secondary: Color) -> void:
	pass


func _request_gear(g: int) -> void:
	if g == gear or is_shifting:
		return
	_pending_gear = g
	_shift_timer = 0.12
	is_shifting = true


func _physics_process(dt: float) -> void:
	# ---- shifting: clutch in, throttle cut, then engage the new gear
	if is_shifting:
		_shift_timer -= dt
		if _shift_timer <= 0.0:
			var old := gear
			gear = _pending_gear
			is_shifting = false
			gear_changed.emit(gear, old)
	throttle = 0.0 if is_shifting else input_throttle
	brake = input_brake
	# ---- rev limiter: fuel cut for a few ms whenever rpm hits the ceiling
	_limiter_cut = maxf(_limiter_cut - dt, 0.0)
	if rpm >= max_rpm - 20.0 and throttle > 0.1:
		_limiter_cut = 0.035
		rev_limiter.emit()
	if _limiter_cut > 0.0:
		throttle = 0.0
	# ---- turbo: spools with rpm*throttle, lag ~0.6 s up, faster down
	var boost_target := clampf((rpm - 2600.0) / 2600.0, 0.0, 1.0) * throttle if turbo else 0.0
	boost = lerpf(boost, boost_target, 1.0 - exp(-dt / (0.55 if boost_target > boost else 0.25)))
	# ---- longitudinal dynamics
	var engaged := gear > 0 and not is_shifting
	var torque := throttle * 260.0 * (0.55 + 0.45 * boost) * clampf(1.2 - absf(rpm - 5200.0) / 9000.0, 0.5, 1.2)
	var force := 0.0
	if engaged:
		force = torque * RATIOS[gear - 1] * FINAL_DRIVE / WHEEL_RADIUS
		force -= (1.0 - throttle) * rpm * 0.25 * RATIOS[gear - 1] # engine braking
	force -= signf(_speed) * (0.42 * _speed * _speed + 180.0) + brake * 9000.0 * signf(_speed)
	var accel := clampf(force / MASS, -11.0, 7.5)
	if airborne:
		accel = -0.3
	_speed = maxf(_speed + accel * dt, 0.0)
	speed_kmh = _speed * 3.6
	# ---- rpm
	var wheel_rps := _speed / WHEEL_RADIUS
	var spin := wheel_rps * (1.0 + extra_slip * 0.35)
	if engaged and not airborne:
		var target := spin * RATIOS[gear - 1] * FINAL_DRIVE * 60.0 / TAU
		rpm = lerpf(rpm, maxf(target, idle_rpm), 1.0 - exp(-dt / 0.03))
	else:
		# free revving (neutral, clutch in, or wheels in the air)
		var free_target := idle_rpm + throttle * (max_rpm - idle_rpm + 200.0)
		rpm = lerpf(rpm, free_target, 1.0 - exp(-dt / (0.18 if free_target > rpm else 0.35)))
	rpm = clampf(rpm, idle_rpm * 0.95, max_rpm)
	# ---- overrun pops: lifting off at high rpm
	_ecu_timer -= dt
	if emit_pops and throttle < 0.05 and rpm > 4200.0 and _ecu_timer <= 0.0:
		_ecu_timer = randf_range(0.15, 0.6)
		if randf() < 0.45:
			backfire.emit()
	# ---- auto box
	if auto_shift and engaged and gear < RATIOS.size() and rpm >= shift_rpm and throttle > 0.5:
		shift_up()
	# ---- wheels
	airborne_time = airborne_time + dt if airborne else 0.0
	for w in wheels:
		w.contact = not airborne
		w.slip = extra_slip
		w.spin_speed = spin
