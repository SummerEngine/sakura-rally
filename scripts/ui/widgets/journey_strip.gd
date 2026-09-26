extends Control
## The campaign under the hub's Campaign item: a stamp per stage (SS1, SS2 under it), tinted by
## the stage's season, joined by the road between them (the liaison is that road, not a mark of
## its own). Driven stages are filled and a driven road is solid ink; the next stage pulses in a
## ring; when the road itself is next, it is inked up to a pulsing car dot halfway along.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

const STEP := 110.0
const MARK_Y := 11.0
const STAGE_R := 8.0

## Per stage: code, season tint, campaign leg index.
var _codes: PackedStringArray = []
var _colors: PackedColorArray = []
var _legs: PackedInt32Array = []
var _next := 0
var _time := 0.0
var _font: Font = UITheme.tracked(UITheme.FONT_UI_BLACK, 2)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## `legs` = Game.CAMPAIGN, `next` = index of the next leg (legs.size() once all are driven).
func setup(legs: Array, next: int) -> void:
	var game := UIApi.game()
	_codes.clear()
	_colors.clear()
	_legs.clear()
	for i in legs.size():
		var leg: Dictionary = legs[i]
		if str(leg.get("kind", "")) != "stage":
			continue
		_codes.append(str(leg.get("code", "")))
		var m: Dictionary = game.get_map(str(leg.get("map", "")))
		_colors.append(UITheme.season_accent(str(m.get("season", ""))))
		_legs.append(i)
	_next = next
	custom_minimum_size = Vector2(maxf(_codes.size() - 1, 0) * STEP + 2.0 * STAGE_R + 16.0, 36.0)
	queue_redraw()


func _process(delta: float) -> void:
	if _legs.size() > 0 and _next <= _legs[_legs.size() - 1] and is_visible_in_tree():
		_time += UIMotion.real_delta(delta)
		queue_redraw()


func _mark_x(i: int) -> float:
	return STAGE_R + 2.0 + i * STEP


func _draw() -> void:
	var ink := Color(UITheme.INK, 0.72)
	var faint := Color(UITheme.INK, 0.28)
	var pulse := 0.5 + 0.5 * sin(_time * 3.4)
	# The road between two stages: solid once driven, dashed ahead, inked up to the car while
	# it is the next thing to drive.
	for i in _codes.size() - 1:
		var a := Vector2(_mark_x(i) + STAGE_R + 4.0, MARK_Y)
		var b := Vector2(_mark_x(i + 1) - STAGE_R - 4.0, MARK_Y)
		var on_road := _next > _legs[i] and _next < _legs[i + 1]
		if _next >= _legs[i + 1]:
			draw_line(a, b, ink, 2.0, true)
		elif on_road:
			var m := a.lerp(b, 0.5)
			draw_line(a, m, ink, 2.0, true)
			draw_dashed_line(m, b, faint, 2.0, 5.0, true, true)
			var accent := _colors[i + 1]
			draw_circle(m, 6.0 + pulse * 2.0, Color(accent, 0.18 + 0.12 * pulse))
			draw_circle(m, 4.0, accent)
			draw_circle(m, 4.0, ink, false, 1.5, true)
		else:
			draw_dashed_line(a, b, faint, 2.0, 5.0, true, true)
	var asc := _font.get_ascent(11)
	for i in _codes.size():
		var c := Vector2(_mark_x(i), MARK_Y)
		var done := _legs[i] < _next
		var current := _legs[i] == _next
		var accent := _colors[i]
		var r := STAGE_R
		if current:
			draw_circle(c, r + 4.0 + pulse * 2.5, Color(accent, 0.18 + 0.12 * pulse))
		if done or current:
			draw_circle(c, r, accent if done else Color(UITheme.PAPER, 0.95))
		draw_circle(c, r, ink if (done or current) else faint, false, 2.0, true)
		if current:
			draw_circle(c, r * 0.42, accent)
		var code := _codes[i]
		var w := _font.get_string_size(code, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var tc := Color(UITheme.INK, 0.78) if (done or current) else Color(UITheme.INK, 0.4)
		draw_string_outline(_font, Vector2(c.x - w * 0.5, MARK_Y + r + 5.0 + asc), code, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 6, Color(1, 1, 1, 0.45))
		draw_string(_font, Vector2(c.x - w * 0.5, MARK_Y + r + 5.0 + asc), code, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, tc)
