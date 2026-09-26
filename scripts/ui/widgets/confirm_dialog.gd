extends Control
## Modal yes / no question on a washi card over a soft ink scrim (e.g. "Start a new journey?").
## Focus starts on the safe choice; Esc / B picks it too. `ask()` returns after the answer:
##   if await dialog.ask("Start a new journey?", "...", "Keep journey", "Start over"): ...

signal answered(yes: bool)

const UITheme := preload("res://scripts/ui/ui_theme.gd")
const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")
const PaperCard := preload("res://scripts/ui/widgets/paper_card.gd")
const InkButton := preload("res://scripts/ui/widgets/ink_button.gd")

var is_open := false

var _scrim := ColorRect.new()
var _card: PaperCard
var _title: Label
var _body: Label
var _no: Button
var _yes: Button
var _return_focus: Control
var _tween: Tween


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.color = Color(UITheme.INK, 0.32)
	_scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_card = PaperCard.new()
	_card.padding = Vector4(44, 36, 44, 34)
	_card.paper_alpha = 0.96
	center.add_child(_card)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 12)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_card.add_child(col)
	_title = UITheme.make_label("", UITheme.FONT_TITLE, 34, UITheme.INK)
	col.add_child(_title)
	_body = UITheme.make_label("", UITheme.FONT_UI_MEDIUM, 19, UITheme.INK_SOFT)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.custom_minimum_size = Vector2(520, 0)
	col.add_child(_body)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 10)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.alignment = BoxContainer.ALIGNMENT_END
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)
	_no = InkButton.new()
	_no.press_sound = &"back"
	_no.pressed.connect(_answer.bind(false))
	row.add_child(_no)
	_yes = InkButton.new()
	_yes.theme_type_variation = &"PrimaryButton"
	_yes.press_sound = &"start"
	_yes.pressed.connect(_answer.bind(true))
	row.add_child(_yes)
	_no.focus_neighbor_right = _yes.get_path()
	_yes.focus_neighbor_left = _no.get_path()
	for b: Button in [_no, _yes]:
		b.focus_neighbor_top = b.get_path()
		b.focus_neighbor_bottom = b.get_path()
	_no.focus_neighbor_left = _no.get_path()
	_yes.focus_neighbor_right = _yes.get_path()
	visible = false


func ask(title: String, body: String, no_text: String, yes_text: String) -> bool:
	_title.text = title
	_body.text = body
	_no.text = no_text
	_yes.text = yes_text
	is_open = true
	visible = true
	_return_focus = get_viewport().gui_get_focus_owner()
	UIMotion.kill(_tween)
	_scrim.modulate.a = 0.0
	_tween = UIMotion.tween(self)
	_tween.tween_property(_scrim, "modulate:a", 1.0, 0.3)
	_no.grab_focus()
	UIMotion.layout_now(self)
	_card.reveal = 0.0
	UIMotion.tween(_card).tween_property(_card, "reveal", 1.0, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	UIMotion.rise_in(_card, 0.0, 26.0, 0.5)
	var yes: bool = await answered
	return yes


func _answer(yes: bool) -> void:
	if not is_open:
		return
	is_open = false
	UIMotion.kill(_tween)
	_tween = UIMotion.tween(self)
	_tween.set_parallel(true)
	_tween.tween_property(_scrim, "modulate:a", 0.0, 0.22)
	_tween.tween_property(_card, "modulate:a", 0.0, 0.18)
	_tween.chain().tween_callback(hide)
	if not yes and _return_focus != null and is_instance_valid(_return_focus) and _return_focus.is_visible_in_tree():
		_return_focus.grab_focus()
	answered.emit(yes)


func _unhandled_input(event: InputEvent) -> void:
	if is_open and event.is_action_pressed("ui_cancel"):
		UIApi.ui_sound(&"back")
		_answer(false)
		get_viewport().set_input_as_handled()
