extends ColorRect
## ColorRect running a UI shader, keeping its `rect_size` uniform in sync with its size and
## exposing a `set_param()` shortcut (usable from tween_method).

var mat := ShaderMaterial.new()


func _init(shader: Shader = null) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	color = Color.WHITE
	mat.shader = shader
	material = mat
	resized.connect(func() -> void: mat.set_shader_parameter("rect_size", size))


func set_param(param: StringName, value: Variant) -> void:
	mat.set_shader_parameter(param, value)


func param_setter(param: StringName) -> Callable:
	return func(v: Variant) -> void: mat.set_shader_parameter(param, v)
