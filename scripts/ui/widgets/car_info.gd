extends Control
## Garage car details (Game.CARS entry): name, brush kanji, tagline, spec line and four stat bars
## (speed, acceleration, grip, drift). Not a focus stop: the car strip picks, this shows. A new car
## slides its name in from the side the pick came from and runs the bars to the new values.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")

const WIDTH := 548.0
const STATS := [["speed", "SPEED"], ["acceleration", "ACCELERATION"], ["grip", "GRIP"], ["drift", "DRIFT"]]
const BAR_W := 300.0
const BAR_H := 10.0

var _info := VBoxContainer.new()
var _name: Label
var _kanji: Label
var _tagline: Label
var _spec: Label
var _bars := Control.new()
var _car: Dictionary = {}
var _values := PackedFloat32Array([0, 0, 0, 0])
var _targets := PackedFloat32Array([0, 0, 0, 0])
var _starts := PackedFloat32Array([0, 0, 0, 0])
var _bar_t := 1.0
var _swap_t := 1.0
var _swap_dir := 1.0
var _label_font: Font = UITheme.tracked(UITheme.FONT_UI_BLACK, 2)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_theme_constant_override("separation", 6)
	add_child(_info)
	var name_row := HBoxContainer.new()
	name_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_row.add_theme_constant_override("separation", 14)
	_info.add_child(name_row)
	_name = UITheme.make_label("", UITheme.FONT_TITLE, 50, UITheme.INK)
	name_row.add_child(_name)
	_kanji = UITheme.make_label("", UITheme.FONT_BRUSH, 44, UITheme.VERMILION)
	_kanji.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	name_row.add_child(_kanji)
	_tagline = UITheme.make_label("", UITheme.FONT_UI_MEDIUM, 18, UITheme.INK_SOFT)
	_tagline.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tagline.custom_minimum_size = Vector2(WIDTH, 0)
	_info.add_child(_tagline)
	_spec = UITheme.make_label("", UITheme.tracked(UITheme.FONT_UI_BLACK, 2), 13, Color(UITheme.INK, 0.72))
	_info.add_child(_spec)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_info.add_child(gap)
	_bars.custom_minimum_size = Vector2(WIDTH, STATS.size() * 28.0)
	_bars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars.draw.connect(_draw_bars)
	_info.add_child(_bars)
	_info.minimum_size_changed.connect(func() -> void:
		custom_minimum_size = Vector2(WIDTH, _info.get_combined_minimum_size().y))
	_show(false)


## Shows `car`; `dir` (-1 / +1) animates the swap from that side, 0 shows it at once.
func show_car(car: Dictionary, dir: float = 0.0) -> void:
	_car = car
	_swap_dir = dir
	_show(dir != 0.0)


func _show(animate: bool) -> void:
	if _name == null or _car.is_empty():
		return
	_name.text = str(_car.get("name", ""))
	_kanji.text = str(_car.get("name_jp", ""))
	_tagline.text = str(_car.get("tagline", ""))
	_spec.text = str(_car.get("spec", "")).to_upper()
	var stats: Dictionary = _car.get("stats", {})
	for k in STATS.size():
		_starts[k] = _values[k]
		_targets[k] = float(stats.get(STATS[k][0], 0.0))
	_bar_t = 0.0 if animate else 1.0
	_swap_t = 0.0 if animate else 1.0
	if not animate:
		_values = _targets.duplicate()
		for l: Control in [_name, _kanji, _tagline, _spec]:
			l.modulate.a = 1.0
		_name.position.x = 0.0
	_bars.queue_redraw()


func _process(delta: float) -> void:
	var d := minf(UIMotion.real_delta(delta), 0.05)
	if _swap_t < 1.0:
		# Name block: out-expo slide in from the side the pick came from.
		_swap_t = minf(_swap_t + d / 0.42, 1.0)
		var e := UIMotion.out_expo(_swap_t)
		for l: Control in [_name, _kanji, _tagline, _spec]:
			l.modulate.a = e
		_name.position.x = 40.0 * _swap_dir * (1.0 - e)
	if _bar_t < 1.0:
		_bar_t = minf(_bar_t + d, 1.0)
		for k in STATS.size():
			var t := UIMotion.out_expo(clampf((_bar_t - k * 0.06) / 0.7, 0.0, 1.0))
			_values[k] = lerpf(_starts[k], _targets[k], t)
		_bars.queue_redraw()


func _draw_bars() -> void:
	var f := _label_font
	var label_w := WIDTH - BAR_W
	for k in STATS.size():
		var y := k * 28.0 + 14.0
		_bars.draw_string(f, Vector2(0, y + 5), STATS[k][1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, UITheme.INK_SOFT)
		var track := Rect2(label_w, y - BAR_H * 0.5, BAR_W, BAR_H)
		_bars.draw_rect(track, Color(UITheme.INK, 0.1))
		var fill := Rect2(track.position, Vector2(BAR_W * clampf(_values[k], 0.0, 1.0), BAR_H))
		_bars.draw_rect(fill, UITheme.VERMILION.lerp(UITheme.SAKURA, float(k) / 3.0 * 0.5))
		# Gauge notches every 10 %, cut in paper.
		for n in range(1, 10):
			var x := label_w + BAR_W * n * 0.1
			_bars.draw_line(Vector2(x, track.position.y), Vector2(x, track.end.y), UITheme.PAPER, 2.0)
