extends Node3D
## Drives scenes/test/audio_test.tscn: a scripted rally run of the fake car (idle, free
## revs, launch with wheelspin, full-throttle upshifts with blow-off, rev limiter, overrun
## pops, downshifts, surface changes, slides, a jump, impacts, horn, slow motion) while
## AudioEffectRecord captures the Master bus.
##
## Steps are condition-based (e.g. "lift 1.2 s after the limiter first bounces"), so the
## run adapts to whatever the fake drivetrain does.
##
## Outputs (in tools/audio/renders/):
##   audio_test[_mix[_liaison]|_clean][_na4].wav          Master bus recording
##   audio_test[_mix[_liaison]|_clean][_na4]_events.json  [{"t": seconds since recording start, "label": ...}]
## User args (after `--`):
##   --mix    also plays drive music + hanami ambience during the run
##            (with --liaison: liaison music + natsu ambience instead).
##   --clean  tarmac only, no stones/pops/impacts/horn: for the click detector.
##   --na4    the fake car becomes the Hayate (engine_sound &"na4"); adds "_na4" to outputs.
##
## Run (headless is fine, audio still mixes):
##   $S --headless --disable-crash-handler --path . res://scenes/test/audio_test.tscn [-- --mix]

const OUT_DIR := "res://tools/audio/renders/"

@onready var car: Node3D = $FakeCar

var _t: float = 0.0
var _step_t: float = 0.0
var _steps: Array = []
var _log: Array = []
var _record: AudioEffectRecord
var _done: bool = false
var _mix: bool = false
var _clean: bool = false
var _frames: int = 0
var _limiter_hits: int = 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_mix = "--mix" in args
	_clean = "--clean" in args
	car.set(&"emit_pops", not _clean)
	car.connect(&"gear_changed", func(n: int, o: int) -> void: _mark("gear %d>%d" % [o, n]))
	car.connect(&"backfire", func() -> void: _mark("pop"))
	car.connect(&"rev_limiter", func() -> void: _limiter_hits += 1)
	_build_timeline()


func _start_recording() -> void:
	var master := AudioServer.get_bus_index("Master")
	_record = AudioEffectRecord.new()
	_record.format = AudioStreamWAV.FORMAT_16_BITS
	AudioServer.add_bus_effect(master, _record)
	_record.set_recording_active(true)
	if _mix:
		var sound := get_node("/root/Sound")
		var liaison := "--liaison" in OS.get_cmdline_user_args()
		sound.play_music(&"liaison" if liaison else &"drive", 0.5)
		sound.set_ambience_mix(Vector3(0.0, 1.0, 0.0) if liaison else Vector3(1.0, 0.0, 0.0))
		sound.play_ambience(0.5)


## Step: when `cond` is true (checked every frame, after `delay` s since the previous
## step fired), run `action`.
func _step(label: String, delay: float, action: Callable, cond: Callable = Callable()) -> void:
	_steps.append({"label": label, "delay": delay, "action": action, "cond": cond})


func _build_timeline() -> void:
	var c := car
	var surface_main: StringName = &"tarmac" if _clean else &"gravel"
	_step("idle", 0.0, func() -> void: c.set_surface(surface_main))
	_step("free rev", 2.0, func() -> void: c.input_throttle = 1.0)
	_step("lift", 0.7, func() -> void: c.input_throttle = 0.0)
	_step("blip", 1.3, func() -> void: c.input_throttle = 0.7)
	_step("lift", 0.3, func() -> void: c.input_throttle = 0.0)
	_step("1st, launch wheelspin", 1.6, func() -> void:
		c.set_gear_now(1)
		c.input_throttle = 1.0
		c.extra_slip = 1.6)
	_step("grip", 1.2, func() -> void: c.extra_slip = 0.3)
	_step("slip 0", 1.0, func() -> void: c.extra_slip = 0.1)
	_step("hold 3rd to limiter", 0.0, func() -> void: c.auto_shift = false,
		func() -> bool: return c.gear == 3)
	_step("limiter", 0.0, func() -> void: pass, func() -> bool: return _limiter_hits > 0)
	_step("lift (overrun)", 1.3, func() -> void: c.input_throttle = 0.0)
	_step("downshift", 0.0, func() -> void: c.shift_down(), func() -> bool: return c.rpm < 4300.0)
	_step("tarmac, part throttle", 1.2, func() -> void:
		c.set_surface(&"tarmac")
		c.input_throttle = 0.6)
	_step("tarmac slide", 1.5, func() -> void: c.extra_slip = 1.4)
	_step("grip, full throttle", 1.8, func() -> void:
		c.extra_slip = 0.1
		c.input_throttle = 1.0
		c.auto_shift = true)
	_step("dirt", 1.5, func() -> void: c.set_surface(&"tarmac" if _clean else &"dirt"))
	_step("dirt slide", 1.2, func() -> void: c.extra_slip = 1.5)
	_step("grass", 1.8, func() -> void:
		c.extra_slip = 0.2
		c.set_surface(&"tarmac" if _clean else &"grass"))
	_step("jump", 1.5, func() -> void: c.airborne = true)
	_step("landed", 0.9, func() -> void:
		c.airborne = false
		if not _clean:
			c.emit_signal(&"landed", 0.85))
	if not _clean:
		_step("impact light", 1.0, func() -> void:
			c.emit_signal(&"impact", 0.25, c.global_position + Vector3(0.9, 0.4, -1.5)))
		_step("impact heavy", 1.0, func() -> void:
			c.emit_signal(&"impact", 0.95, c.global_position + Vector3(-0.9, 0.5, -1.8)))
		_step("horn", 1.0, func() -> void: Input.action_press(&"horn"))
		_step("horn off", 0.25, func() -> void: Input.action_release(&"horn"))
		_step("horn", 0.2, func() -> void: Input.action_press(&"horn"))
		_step("horn off", 0.75, func() -> void: Input.action_release(&"horn"))
	_step("brake, lift", 0.4, func() -> void:
		c.set_surface(surface_main)
		c.input_throttle = 0.0
		c.input_brake = 0.8
		c.auto_shift = false)
	for i in 3:
		_step("downshift", 0.35, func() -> void: c.shift_down(),
			func() -> bool: return c.rpm < 3800.0 and c.gear > 1 and not c.is_shifting)
	_step("throttle, slowmo 0.35", 0.8, func() -> void:
		c.input_brake = 0.0
		c.input_throttle = 1.0
		get_node("/root/Sound").set_slowmo(0.35))
	_step("slowmo off", 2.0, func() -> void: get_node("/root/Sound").set_slowmo(1.0))
	_step("neutral, idle", 1.0, func() -> void:
		c.input_throttle = 0.0
		c.set_gear_now(0))
	_step("end", 3.0, _finish)


func _mark(label: String) -> void:
	_log.append({"t": snappedf(_t, 0.001), "label": label})


func _process(delta: float) -> void:
	if _done:
		return
	_frames += 1
	if _frames < 5:
		return # let loading hitches pass before the clock starts
	if _frames == 5:
		_start_recording()
		return
	var dt := minf(delta, 0.05)
	_t += dt
	_step_t += dt
	if _t > 120.0:
		push_error("audio_test: timeline stalled at '%s'" % _steps[0]["label"])
		_finish()
		return
	while not _steps.is_empty():
		var s: Dictionary = _steps[0]
		if _step_t < float(s["delay"]):
			break
		var cond: Callable = s["cond"]
		if cond.is_valid() and not bool(cond.call()):
			break
		_steps.pop_front()
		_step_t = 0.0
		_mark(s["label"])
		(s["action"] as Callable).call()


func _finish() -> void:
	_done = true
	_record.set_recording_active(false)
	var wav := _record.get_recording()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var args := OS.get_cmdline_user_args()
	var suffix := ("_mix" if _mix else ("_clean" if _clean else "")) + ("_liaison" if _mix and "--liaison" in args else "") \
			+ ("_na4" if "--na4" in args else "")
	var path := ProjectSettings.globalize_path(OUT_DIR + "audio_test%s.wav" % suffix)
	if wav == null:
		push_error("audio_test: recording is empty")
	else:
		wav.save_to_wav(path)
		print("audio_test: wrote %s (%.2f s, %d Hz)" % [path, wav.get_length(), wav.mix_rate])
	var f := FileAccess.open(ProjectSettings.globalize_path(OUT_DIR + "audio_test%s_events.json" % suffix), FileAccess.WRITE)
	f.store_string(JSON.stringify(_log, "  "))
	f.close()
	get_node("/root/Game").request_quit()
