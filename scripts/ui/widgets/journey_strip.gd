extends Control
## The campaign's legs as a small road map under the hub's Campaign item: a stamp per stage, a
## diamond per liaison road, joined by a brush line (dashed along liaison roads), each tinted by
## its map's season. Driven legs are filled, the next one pulses in a ring, the rest wait hollow.
## Codes (SS1, L1, SS2) sit under the marks.

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

const STEP := 74.0
const MARK_Y := 11.0
const STAGE_R := 8.0
const LIAISON_R := 6.5

var _codes: PackedStringArray = []
var _liaison: Array[bool] = []
var _colors: PackedColorArray = []
var _next := 0
var _time := 0.0
var _font: Font = UITheme.tracked(UITheme.FONT_UI_BLACK, 2)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## `legs` = Game.CAMPAIGN, `next` = index of the next leg (legs.size() once all are driven).
func setup(legs: Array, next: int) -> void:
	var game := UIApi.game()
	_codes.clear()
	_liaison.clear()
	_colors.clear()
	for leg: Dictionary in legs:
		_codes.append(str(leg.get("code", "")))
		_liaison.append(str(leg.get("kind", "")) == "liaison")
		var m: Dictionary = game.get_map(str(leg.get("map", "")))
		_colors.append(UITheme.season_accent(str(m.get("season", ""))))
	_next = next
	custom_minimum_size = Vector2(maxf(legs.size() - 1, 0) * STEP + 2.0 * STAGE_R + 16.0, 36.0)
	queue_redraw()


func _process(delta: float) -> void:
	if _next < _codes.size() and is_visible_in_tree():
		_time += UIMotion.real_delta(delta)
		queue_redraw()


func _mark_x(i: int) -> float:
	return STAGE_R + 2.0 + i * STEP


func _draw() -> void:
	var ink := Color(UITheme.INK, 0.72)
	var faint := Color(UITheme.INK, 0.28)
	# Roads between the marks: solid ink once driven, dashed ahead; liaison legs dash always.
	for i in _codes.size() - 1:
		var a := Vector2(_mark_x(i) + STAGE_R + 4.0, MARK_Y)
		var b := Vector2(_mark_x(i + 1) - STAGE_R - 4.0, MARK_Y)
		var driven := i + 1 <= _next
		var col := ink if driven else faint
		if _liaison[i] or _liaison[i + 1] or not driven:
			draw_dashed_line(a, b, col, 2.0, 5.0, true, true)
		else:
			draw_line(a, b, col, 2.0, true)
	var asc := _font.get_ascent(11)
	for i in _codes.size():
		var c := Vector2(_mark_x(i), MARK_Y)
		var done := i < _next
		var current := i == _next
		var accent := _colors[i]
		var r := LIAISON_R if _liaison[i] else STAGE_R
		if current:
			var pulse := 0.5 + 0.5 * sin(_time * 3.4)
			draw_circle(c, r + 4.0 + pulse * 2.5, Color(accent, 0.18 + 0.12 * pulse))
		if _liaison[i]:
			var pts := PackedVector2Array([c + Vector2(0, -r), c + Vector2(r, 0), c + Vector2(0, r), c + Vector2(-r, 0)])
			if done or current:
				draw_colored_polygon(pts, accent if done else Color(UITheme.PAPER, 0.95))
			pts.append(pts[0])
			draw_polyline(pts, ink if (done or current) else faint, 2.0, true)
		else:
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
