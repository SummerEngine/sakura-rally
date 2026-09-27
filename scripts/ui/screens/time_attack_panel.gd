extends Control
## Time Attack page of the title hub: Time Trial / Free Roam picker and a map card per road
## (Time Trial: the timed stages, Game.stage_maps(); Free Roam: every map, the liaison road
## too). A card starts the drive with Game.request_start(map_id, mode); Back / Esc returns
## to the hub (the title screen handles Esc).

signal back_requested

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const MapCard := preload("res://scripts/ui/widgets/map_card.gd")
const Segmented := preload("res://scripts/ui/widgets/segmented.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")

const MODES := ["time_trial", "free_roam"]
const MODE_NOTES := [
	"One lap against the clock. Checkpoint splits, medals, records.",
	"No clock, no checkpoints. Every road is open, the summer road too.",
]
const MARGIN := Vector2(96, 64)

var cards: Array[MapCard] = []
var mode_picker: Segmented
var back_button: Button

var _col := VBoxContainer.new()
var _header := HBoxContainer.new()
var _mode_row := HBoxContainer.new()
var _note: Label
var _cards_row := HBoxContainer.new()
var _back_row := HBoxContainer.new()
var _last_card := 0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_col.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_col.offset_left = MARGIN.x
	_col.offset_right = MARGIN.x
	_col.offset_top = -MARGIN.y
	_col.offset_bottom = -MARGIN.y
	_col.add_theme_constant_override("separation", 18)
	_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_col)

	_header.add_theme_constant_override("separation", 18)
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(_header)
	var kanji := UITheme.make_label("時", UITheme.FONT_BRUSH, 70, UITheme.VERMILION)
	kanji.label_settings.outline_size = 12
	kanji.label_settings.outline_color = Color(1, 1, 1, 0.5)
	_header.add_child(kanji)
	var hcol := VBoxContainer.new()
	hcol.add_theme_constant_override("separation", 0)
	hcol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hcol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.add_child(hcol)
	var over := UITheme.make_label("TIME ATTACK", UITheme.tracked(UITheme.FONT_UI_BLACK, 4), 14, Color(UITheme.INK, 0.62))
	over.label_settings.outline_size = 8
	over.label_settings.outline_color = Color(1, 1, 1, 0.4)
	hcol.add_child(over)
	var title := UITheme.make_label("Choose a road", UITheme.FONT_TITLE, 44, UITheme.INK)
	title.label_settings.outline_size = 14
	title.label_settings.outline_color = Color(1, 1, 1, 0.45)
	hcol.add_child(title)

	_mode_row.add_theme_constant_override("separation", 22)
	_mode_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(_mode_row)
	mode_picker = Segmented.new()
	mode_picker.options = PackedStringArray(["Time Trial", "Free Roam"])
	mode_picker.min_segment_width = 150.0
	mode_picker.changed.connect(_on_mode_changed)
	_mode_row.add_child(mode_picker)
	_note = UITheme.make_label(MODE_NOTES[0], UITheme.FONT_UI_BOLD, 18, Color(UITheme.INK, 0.78))
	_note.label_settings.outline_size = 10
	_note.label_settings.outline_color = Color(1, 1, 1, 0.45)
	_note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_mode_row.add_child(_note)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 4)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(gap)

	_cards_row.add_theme_constant_override("separation", 26)
	_cards_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(_cards_row)
	for m: Dictionary in UIApi.game().MAPS:
		var card := MapCard.new()
		card.setup(m)
		card.pressed.connect(_on_card_pressed.bind(card))
		card.focus_entered.connect(func() -> void: _last_card = _visible_cards().find(card))
		_cards_row.add_child(card)
		cards.append(card)

	_back_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_col.add_child(_back_row)
	back_button = InkButton.new()
	back_button.text = "‹  Back"
	back_button.theme_type_variation = &"QuietButton"
	back_button.add_theme_font_size_override("font_size", 20)
	back_button.press_sound = &"back"
	back_button.pressed.connect(func() -> void: back_requested.emit())
	_back_row.add_child(back_button)
	_apply_mode(false)
	visible = false


func mode() -> String:
	return MODES[mode_picker.selected]


func _visible_cards() -> Array[MapCard]:
	var out: Array[MapCard] = []
	for c in cards:
		if c.visible:
			out.append(c)
	return out


func _allowed(card: MapCard) -> bool:
	return mode_picker.selected == 1 or not bool(card.map.get("liaison", false))


## Shows the cards of the current mode; `animate` slides roads in and out of the row.
func _apply_mode(animate: bool) -> void:
	_note.text = MODE_NOTES[mode_picker.selected]
	for c in cards:
		var want := _allowed(c)
		if want == c.visible:
			continue
		if want:
			c.visible = true
			if animate:
				c.modulate.a = 0.0
				# Wait for the row to place it, then rise in from where it landed.
				(func() -> void: UIMotion.rise_in(c, 0.05, 50.0, 0.6)).call_deferred()
		else:
			c.visible = false
	_link_focus()


func _link_focus() -> void:
	var vis := _visible_cards()
	mode_picker.focus_neighbor_bottom = vis[clampi(_last_card, 0, vis.size() - 1)].get_path()
	for i in vis.size():
		vis[i].focus_neighbor_top = mode_picker.get_path()
		vis[i].focus_neighbor_bottom = back_button.get_path()
		vis[i].focus_neighbor_left = vis[i - 1].get_path() if i > 0 else vis[i].get_path()
		vis[i].focus_neighbor_right = vis[i + 1].get_path() if i < vis.size() - 1 else vis[i].get_path()
	back_button.focus_neighbor_top = vis[clampi(_last_card, 0, vis.size() - 1)].get_path()
	back_button.focus_neighbor_bottom = back_button.get_path()


# ---------------------------------------------------------------- show / hide

## Slides the page in and focuses the card of the last map driven (or the first).
func enter(delay: float = 0.0) -> void:
	visible = true
	modulate.a = 1.0
	var game := UIApi.game()
	if str(game.map_id) != "":
		mode_picker.selected = maxi(MODES.find(str(game.mode)), 0)
	mode_picker.queue_redraw()
	_apply_mode(false)
	for c in cards:
		c.refresh()
		c.scale = Vector2.ONE
	# Undo the last exit's slide offsets before the entrance reads the laid-out positions.
	UIMotion.layout_now(self)
	var d := delay
	for r: Control in [_header, _mode_row]:
		UIMotion.rise_in(r, d, 26.0)
		d += 0.07
	for c in _visible_cards():
		UIMotion.rise_in(c, d, 60.0, 0.7)
		d += 0.1
	UIMotion.rise_in(_back_row, d, 20.0)
	var vis := _visible_cards()
	var idx := 0
	for i in vis.size():
		if str(vis[i].map.get("id", "")) == str(game.map_id):
			idx = i
	_last_card = idx
	_link_focus()
	vis[idx].grab_focus()


## Back to the hub: the page slides away to the right.
func leave() -> void:
	var tw := UIMotion.tween(self)
	tw.tween_property(self, "modulate:a", 0.0, 0.26)
	tw.tween_callback(func() -> void:
		visible = false
		modulate.a = 1.0)
	var i := 0
	for r: Control in [_header, _mode_row, _cards_row, _back_row]:
		UIMotion.slide_out(r, Vector2(60, 0), 0.02 * i, 0.24)
		i += 1


## A drive starts: the chosen card pops, the rest of the page falls away.
func leave_for_race() -> void:
	var vis := _visible_cards()
	var chosen: MapCard = vis[clampi(_last_card, 0, vis.size() - 1)]
	for i in vis.size():
		if vis[i] != chosen:
			UIMotion.slide_out(vis[i], Vector2(0, 60), 0.02 * i)
	for r: Control in [_header, _mode_row, _back_row]:
		UIMotion.slide_out(r, Vector2(-40, 0))
	chosen.pivot_offset = chosen.size * 0.5
	var ct := UIMotion.tween(chosen)
	ct.tween_property(chosen, "scale", Vector2(1.05, 1.05), 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	ct.tween_property(chosen, "modulate:a", 0.0, 0.3)


# ---------------------------------------------------------------- events

func _on_mode_changed(_index: int) -> void:
	_apply_mode(true)


func _on_card_pressed(card: MapCard) -> void:
	if not visible or modulate.a < 0.5:
		return
	UIApi.ui_sound(&"start")
	_last_card = _visible_cards().find(card)
	UIApi.game().request_start(str(card.map.get("id", "")), mode())
