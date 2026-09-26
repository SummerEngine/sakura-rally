extends Button
## Paper pill button with springy focus / press motion. Mouse hover grabs focus so the
## single glide-ring focus indicator (UIFocusRing) follows mouse, keyboard and gamepad alike.

const UIMotion := preload("res://scripts/ui/ui_motion.gd")
const UIApi := preload("res://scripts/ui/ui_api.gd")

@export var press_sound: StringName = &"click"
@export var focus_scale := 1.045

var _scale_target := 1.0
var _scale := 1.0
var _scale_vel := 0.0


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(_on_mouse_entered)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(func() -> void: _scale_target = 1.0)
	button_down.connect(func() -> void: _scale = 0.94)
	pressed.connect(_on_pressed)
	resized.connect(func() -> void: pivot_offset = size * 0.5)
	pivot_offset = size * 0.5


func _on_mouse_entered() -> void:
	if not disabled and focus_mode != Control.FOCUS_NONE:
		grab_focus()


func _on_focus_entered() -> void:
	_scale_target = focus_scale
	if is_visible_in_tree():
		UIApi.ui_sound(&"hover")


func _on_pressed() -> void:
	if press_sound != &"":
		UIApi.ui_sound(press_sound)


func _process(delta: float) -> void:
	# Critically-underdamped spring: a soft bounce, frame-rate independent.
	var d := minf(UIMotion.real_delta(delta), 0.05)
	var k := 420.0
	var c := 22.0
	_scale_vel += ((_scale_target - _scale) * k - _scale_vel * c) * d
	_scale += _scale_vel * d
	scale = Vector2(_scale, _scale)
