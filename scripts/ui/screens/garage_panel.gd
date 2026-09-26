extends Control
## Garage page of the title hub: a washi card on the left with the car selector (Game.CARS,
## stat bars) and the livery picker (Game.CAR_COLORS), over the parked menu car on the right
## (Main's MenuStage parks it while Game.menu_view is "garage"). Choices save at once through
## Game.set_setting("car_id" / "car_color") and show on the car straight away. Back / Esc
## returns to the hub (the title screen handles Esc).

signal back_requested

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const CarSelector := preload("res://scripts/ui/widgets/car_selector.gd")
const LiveryPicker := preload("res://scripts/ui/widgets/livery_picker.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")

const MARGIN := Vector2(72, 64)

var car_selector: CarSelector
var livery_picker: LiveryPicker
var back_button: Button

## Game.CARS entries whose car scene is in the project.
var _cars: Array[Dictionary] = []
var _card: PaperCard
var _sections: Array[Control] = []


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card = PaperCard.new()
	_card.padding = Vector4(40, 34, 40, 30)
	_card.paper_alpha = 0.9
	_card.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT)
	_card.grow_vertical = Control.GROW_DIRECTION_BOTH
	_card.offset_left = MARGIN.x
	_card.offset_right = MARGIN.x
	add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(header)
	header.add_child(UITheme.make_label("車庫", UITheme.FONT_BRUSH, 56, UITheme.VERMILION))
	var hcol := VBoxContainer.new()
	hcol.add_theme_constant_override("separation", 0)
	hcol.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hcol.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(hcol)
	hcol.add_child(UITheme.make_label("GARAGE", UITheme.tracked(UITheme.FONT_UI_BLACK, 4), 14, Color(UITheme.INK, 0.62)))
	hcol.add_child(UITheme.make_label("Your car", UITheme.FONT_TITLE, 36, UITheme.INK))
	_sections.append(header)

	var game := UIApi.game()
	for c: Dictionary in game.CARS:
		if ResourceLoader.exists(str(c["scene"])):
			_cars.append(c)
	car_selector = CarSelector.new()
	car_selector.setup(_cars, _car_index())
	car_selector.changed.connect(func(i: int) -> void: game.set_setting("car_id", str(_cars[i]["id"])))
	col.add_child(_divider())
	col.add_child(car_selector)
	_sections.append(car_selector)

	var livery := VBoxContainer.new()
	livery.add_theme_constant_override("separation", 6)
	livery.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_divider())
	col.add_child(livery)
	livery.add_child(UITheme.make_label("LIVERY", UITheme.tracked(UITheme.FONT_UI_BLACK, 4), 14, Color(UITheme.INK, 0.62)))
	livery_picker = LiveryPicker.new()
	livery_picker.setup(game.CAR_COLORS, int(game.get_setting("car_color")))
	livery_picker.changed.connect(func(i: int) -> void: game.set_setting("car_color", i))
	livery.add_child(livery_picker)
	_sections.append(livery)

	var foot := HBoxContainer.new()
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(foot)
	back_button = InkButton.new()
	back_button.text = "‹  Back"
	back_button.theme_type_variation = &"QuietButton"
	back_button.add_theme_font_size_override("font_size", 20)
	back_button.press_sound = &"back"
	back_button.pressed.connect(func() -> void: back_requested.emit())
	foot.add_child(back_button)
	_sections.append(foot)

	car_selector.focus_neighbor_bottom = livery_picker.get_path()
	car_selector.focus_neighbor_top = back_button.get_path()
	livery_picker.focus_neighbor_top = car_selector.get_path()
	livery_picker.focus_neighbor_bottom = back_button.get_path()
	back_button.focus_neighbor_top = livery_picker.get_path()
	back_button.focus_neighbor_bottom = car_selector.get_path()
	for c: Control in [car_selector, livery_picker, back_button]:
		c.focus_neighbor_left = c.get_path()
		c.focus_neighbor_right = c.get_path()
	visible = false


func _divider() -> Control:
	var line := ColorRect.new()
	line.color = Color(UITheme.INK, 0.1)
	line.custom_minimum_size = Vector2(0, 2)
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return line


func _car_index() -> int:
	var id := str(UIApi.game().get_setting("car_id"))
	for i in _cars.size():
		if str(_cars[i]["id"]) == id:
			return i
	return 0


## Washes the card in and focuses the car selector. `delay` lets the screen wipe land first.
func enter(delay: float = 0.0) -> void:
	visible = true
	modulate.a = 1.0
	car_selector.set_selected(_car_index())
	livery_picker.set_selected(int(UIApi.game().get_setting("car_color")))
	UIMotion.layout_now(self)
	_card.reveal = 0.0
	UIMotion.tween(_card).tween_property(_card, "reveal", 1.0, 0.6).set_delay(delay) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	var d := delay + 0.12
	for s in _sections:
		UIMotion.rise_in(s, d, 22.0, 0.5)
		d += 0.07
	car_selector.grab_focus()


func leave() -> void:
	var tw := UIMotion.tween(self)
	tw.tween_property(self, "modulate:a", 0.0, 0.22)
	tw.tween_callback(func() -> void:
		visible = false
		modulate.a = 1.0)
