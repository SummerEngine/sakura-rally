extends PanelContainer

const UITheme := preload("res://scripts/ui/ui_theme.gd")
## Frosted washi-paper card (see shaders/ui/paper_card.gdshader). Lays out children like a
## PanelContainer with `padding`; draws the card plus its soft shadow behind them.

const SHADER := preload("res://shaders/ui/paper_card.gdshader")
const SHADOW_PAD := 72.0

@export var padding := Vector4(34, 30, 34, 30) ## left, top, right, bottom
@export var radius := 26.0
@export var paper_alpha := 0.86:
	set(v):
		paper_alpha = v
		_push("paper", Color(UITheme.PAPER, v))
@export var lift := 0.0:
	set(v):
		lift = v
		_push("lift", v)
@export var reveal := 1.0:
	set(v):
		reveal = v
		_push("reveal", v)

var _mat: ShaderMaterial


func _init() -> void:
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	material = _mat
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _ready() -> void:
	var sb := StyleBoxEmpty.new()
	sb.content_margin_left = padding.x
	sb.content_margin_top = padding.y
	sb.content_margin_right = padding.z
	sb.content_margin_bottom = padding.w
	add_theme_stylebox_override("panel", sb)
	_push("radius", radius)
	_push("paper", Color(UITheme.PAPER, paper_alpha))
	_push("lift", lift)
	_push("reveal", reveal)
	resized.connect(_on_resized)
	_on_resized()


func set_wash(c: Color) -> void:
	_push("wash", c)


func set_shadow(alpha: float, size_px: float, offset: Vector2) -> void:
	_push("shadow_alpha", alpha)
	_push("shadow_size", size_px)
	_push("shadow_offset", offset)


func _push(param: String, value: Variant) -> void:
	if _mat != null:
		_mat.set_shader_parameter(param, value)


func _on_resized() -> void:
	_push("card_size", size)
	queue_redraw()


func _draw() -> void:
	# The rect extends past the card for the shadow; the shader's `local` is card-relative.
	draw_rect(Rect2(-Vector2.ONE * SHADOW_PAD, size + Vector2.ONE * SHADOW_PAD * 2.0), Color.WHITE)
