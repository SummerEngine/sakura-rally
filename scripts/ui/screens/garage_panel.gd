extends Control
## Garage page of the title hub: a washi card on the left with the chosen car's details
## (widgets/car_info: name, kanji, tagline, spec, stat bars), the livery picker (Game.CAR_COLORS)
## and Back, and the car strip across the bottom of the screen (widgets/car_selector: a card per
## car in Game.CARS). The menu car stands on the right, on the garage's display spot (Main's
## MenuStage, while Game.menu_view is "garage"). Choices save at once through
## Game.set_setting("car_id" / "car_color") and show on the car straight away: a car pick sends
## the old car off and brings the new one in. Focus: the strip on entry; Up the livery picker,
## Up again Back. Back / Esc returns to the hub (the title screen handles Esc).

signal back_requested

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const CarSelector := preload("res://scripts/ui/widgets/car_selector.gd")
const CarInfo := preload("res://scripts/ui/widgets/car_info.gd")
const LiveryPicker := preload("res://scripts/ui/widgets/livery_picker.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")

const MARGIN := Vector2(72, 56)
## The car strip sits this far above the bottom edge.
const STRIP_MARGIN := 40.0

## The car strip (bottom of the screen).
var car_selector: CarSelector
var car_info: CarInfo
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
	_card.padding = Vector4(40, 30, 40, 30)
	_card.paper_alpha = 0.9
	_card.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_card.offset_left = MARGIN.x
	_card.offset_top = MARGIN.y
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
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	push.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(push)
	back_button = InkButton.new()
	back_button.text = "‹  Back"
	back_button.theme_type_variation = &"QuietButton"
	back_button.add_theme_font_size_override("font_size", 20)
	back_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	back_button.press_sound = &"back"
	back_button.pressed.connect(func() -> void: back_requested.emit())
	header.add_child(back_button)
	_sections.append(header)

	var game := UIApi.game()
	for c: Dictionary in game.CARS:
		if ResourceLoader.exists(str(c["scene"])):
			_cars.append(c)
	car_info = CarInfo.new()
	col.add_child(_divider())
	col.add_child(car_info)
	_sections.append(car_info)

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

	car_selector = CarSelector.new()
	car_selector.setup(_cars, _car_index())
	car_selector.changed.connect(_on_car_picked)
	add_child(car_selector)
	# Fixed size (a card per car), centred on the bottom edge.
	var strip := car_selector.custom_minimum_size
	car_selector.anchor_left = 0.5
	car_selector.anchor_right = 0.5
	car_selector.anchor_top = 1.0
	car_selector.anchor_bottom = 1.0
	car_selector.offset_left = -strip.x * 0.5
	car_selector.offset_right = strip.x * 0.5
	car_selector.offset_top = -strip.y - STRIP_MARGIN
	car_selector.offset_bottom = -STRIP_MARGIN
	_sections.append(car_selector)

	car_selector.focus_neighbor_top = livery_picker.get_path()
	car_selector.focus_neighbor_bottom = car_selector.get_path()
	livery_picker.focus_neighbor_top = back_button.get_path()
	livery_picker.focus_neighbor_bottom = car_selector.get_path()
	back_button.focus_neighbor_top = back_button.get_path()
	back_button.focus_neighbor_bottom = livery_picker.get_path()
	for c: Control in [car_selector, livery_picker, back_button]:
		c.focus_neighbor_left = c.get_path()
		c.focus_neighbor_right = c.get_path()
	game.settings_changed.connect(_sync_car)
	visible = false


## A car chosen elsewhere (a tool, another screen) shows on the strip and the card.
func _sync_car() -> void:
	var i := _car_index()
	if i == car_selector.selected or _cars.is_empty():
		return
	var dir := signf(float(i - car_selector.selected)) if visible else 0.0
	car_selector.set_selected(i)
	car_info.show_car(_cars[i], dir)


func _on_car_picked(i: int) -> void:
	var before := _car_index()
	car_info.show_car(_cars[i], signf(float(i - before)) if i != before else 1.0)
	UIApi.game().set_setting("car_id", str(_cars[i]["id"]))


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


## Washes the card and the strip in and focuses the strip. `delay` lets the screen wipe land first.
func enter(delay: float = 0.0) -> void:
	visible = true
	modulate.a = 1.0
	car_selector.set_selected(_car_index())
	if not _cars.is_empty():
		car_info.show_car(_cars[_car_index()])
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
