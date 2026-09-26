extends CanvasLayer
## The whole UI layer (scenes/ui/ui_root.tscn). The Main scene instantiates it once; it
## follows the Game autoload (state_changed, session_started, countdown_tick,
## checkpoint_passed, race_finished, paused_changed, notice) and switches screens itself.
##
## API for Main (see docs/UI.md):
##   await ui.transition_out(map_id)  # ink covers the screen; load / unload behind it
##   await ui.transition_in()         # ink lifts off
##   ui.set_hud_visible(bool)         # race HUD only (e.g. for replays / photo mode)
##   ui.set_ui_visible(bool)          # everything (F1 toggles this for clean capture)
## The UI owns the `pause` action: it calls Game.set_paused() while driving.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const TitleScreen := preload("res://scripts/ui/screens/title_screen.gd")
const SettingsPanel := preload("res://scripts/ui/screens/settings_panel.gd")
const RaceIntro := preload("res://scripts/ui/screens/race_intro.gd")
const Hud := preload("res://scripts/ui/screens/hud.gd")
const ResultsScreen := preload("res://scripts/ui/screens/results_screen.gd")
const PauseMenu := preload("res://scripts/ui/screens/pause_menu.gd")
const TransitionLayer := preload("res://scripts/ui/screens/transition_layer.gd")
const FocusRing := preload("res://scripts/ui/widgets/focus_ring.gd")

const SHAKE_TIME := 0.38

var title: TitleScreen
var settings: SettingsPanel
var race_intro: RaceIntro
var hud: Hud
var results: ResultsScreen
var pause_menu: PauseMenu
var transition: TransitionLayer

var _root := Control.new() ## everything that shakes (all but the transition)
var _hud_wanted := true
var _split_deltas: Array = []
var _shake_t := 0.0
var _shake_strength := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	layer = 10
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = UITheme.get_theme()
	add_child(_root)

	hud = Hud.new()
	race_intro = RaceIntro.new()
	results = ResultsScreen.new()
	title = TitleScreen.new()
	pause_menu = PauseMenu.new()
	settings = SettingsPanel.new()
	for c: Control in [hud, race_intro, results, title, pause_menu, settings]:
		_root.add_child(c)
	_root.add_child(FocusRing.new())
	transition = TransitionLayer.new()
	transition.theme = _root.theme
	add_child(transition)

	title.settings_requested.connect(settings.open)
	title.shake_requested.connect(shake)
	results.shake_requested.connect(shake)
	pause_menu.settings_requested.connect(settings.open)

	var game := UIApi.game()
	game.state_changed.connect(_on_state_changed)
	game.start_requested.connect(_on_start_requested)
	game.session_started.connect(_on_session_started)
	game.countdown_tick.connect(_on_countdown_tick)
	game.checkpoint_passed.connect(_on_checkpoint_passed)
	game.race_finished.connect(_on_race_finished)
	game.paused_changed.connect(_on_paused_changed)
	game.notice.connect(_on_notice)
	_on_state_changed(int(game.state), int(game.state))


# ---------------------------------------------------------------- public API

## Cover the screen with the ink wipe (with the map's kanji + name on the loading card when
## `map_id` is given). Returns a signal that fires once the screen is fully covered.
func transition_out(map_id: String = "") -> Signal:
	var m: Dictionary = UIApi.game().get_map(map_id) if map_id != "" else {}
	if m.is_empty():
		transition.set_loading_label("桜", "Sakura Rally")
	else:
		transition.set_loading_label(str(m.get("name_jp", "")), str(m.get("name", "")))
	return transition.cover()


## Lift the ink off. Returns a signal that fires once the screen is clear.
func transition_in() -> Signal:
	return transition.reveal()


func is_screen_covered() -> bool:
	return transition.is_covered


func set_hud_visible(value: bool) -> void:
	_hud_wanted = value
	hud.modulate.a = 1.0 if value else 0.0


func set_ui_visible(value: bool) -> void:
	visible = value


## Small screen shake of the UI (stamp impacts, finish slam). strength ~0..1.
func shake(strength: float) -> void:
	_shake_strength = maxf(_shake_strength if _shake_t > 0.0 else 0.0, strength)
	_shake_t = SHAKE_TIME


# ---------------------------------------------------------------- Game events

func _on_state_changed(new_state: int, _old_state: int) -> void:
	var game := UIApi.game()
	var state_name := str((game.State as Dictionary).find_key(new_state))
	match state_name:
		"MENU":
			hud.hide_hud(true)
			results.hide_result(true)
			race_intro.reset()
			pause_menu.close()
			title.enter()
		"LOADING":
			title.leave()
			pause_menu.close()
		"INTRO":
			title.leave(true)
			results.hide_result(true)
			hud.hide_hud(true)
			race_intro.setup(str(game.map_id), str(game.mode))
			race_intro.show_card()
		"COUNTDOWN":
			title.leave(true)
			results.hide_result(true)
			_show_hud()
		"RACING", "FREE_ROAM":
			title.leave(true)
			results.hide_result(true)
			race_intro.hide_card()
			_show_hud()
		"FINISHED":
			hud.hide_hud()


func _show_hud() -> void:
	hud.show_hud()
	hud.modulate.a = 1.0 if _hud_wanted else 0.0


func _on_start_requested(_map_id: String, _mode: String) -> void:
	title.leave()


func _on_session_started(map_id: String, mode: String) -> void:
	_split_deltas.clear()
	results.hide_result(true)
	race_intro.reset()
	hud.hide_hud(true)
	hud.setup(map_id, mode)
	race_intro.setup(map_id, mode)
	if int(UIApi.game().state) == UIApi.state("INTRO"):
		race_intro.show_card()


func _on_countdown_tick(value: int) -> void:
	race_intro.tick(value)


func _on_checkpoint_passed(index: int, total: int, split_time: float, delta_to_best: float) -> void:
	while _split_deltas.size() <= index:
		_split_deltas.append(NAN)
	_split_deltas[index] = delta_to_best
	hud.on_checkpoint(index, total, split_time, delta_to_best)


func _on_race_finished(result: Dictionary) -> void:
	hud.hide_hud()
	results.show_result(result, _split_deltas.duplicate())


func _on_paused_changed(paused: bool) -> void:
	if paused:
		pause_menu.open()
	else:
		if settings.is_open:
			settings.close()
		pause_menu.close()


func _on_notice(text: String) -> void:
	if hud.shown:
		hud.on_notice(text)


# ---------------------------------------------------------------- input / frame

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_F1:
		set_ui_visible(not visible)
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	var game := UIApi.game()
	if bool(game.paused):
		if settings.is_open:
			return
		if event.is_action_pressed("pause") or event.is_action_pressed("ui_cancel"):
			UIApi.ui_sound(&"back")
			game.set_paused(false)
			get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed("pause"):
		var s := int(game.state)
		if s == UIApi.state("RACING") or s == UIApi.state("FREE_ROAM") or s == UIApi.state("COUNTDOWN"):
			UIApi.ui_sound(&"click")
			game.set_paused(true)
			get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _shake_t <= 0.0:
		return
	_shake_t -= UIMotion.real_delta(delta)
	if _shake_t <= 0.0:
		_root.position = Vector2.ZERO
		return
	var k := _shake_t / SHAKE_TIME
	var amp := 14.0 * _shake_strength * k * k
	_root.position = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * amp
