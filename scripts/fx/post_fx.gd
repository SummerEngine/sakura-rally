class_name PostFX
extends Node3D
## Screen passes: depth-curvature ink lines (a full-screen quad drawn first in the
## transparent pass) and the anime colour grade (a CanvasLayer under the UI).
## Also owns speed lines, letterbox, fades and the painted sun glow position.
## The grade and the sun follow the Atmosphere in the scene (group "atmosphere") whenever its
## preset changes, so the season blend at the camera reaches the grade without a caller.

const INK_SHADER := preload("res://shaders/post_ink.gdshader")
const GRADE_SHADER := preload("res://shaders/post_grade.gdshader")
const GRADE_LAYER := 0 ## UI layers must be above this

var ink_quad: MeshInstance3D
var ink_material: ShaderMaterial
var grade_layer: CanvasLayer
var grade_rect: ColorRect
var grade_material: ShaderMaterial
var sun_dir: Vector3 = Vector3.UP
var occlusion_mask: int = 1

## Driven by gameplay/cinematics, eased every frame.
var speed_target: float = 0.0
var letterbox_target: float = 0.0
var fade_target: float = 0.0
var _speed: float = 0.0
var _letterbox: float = 0.0
var _fade: float = 0.0
var _sun_vis: float = 0.0
var _atmosphere: Atmosphere
var _atmosphere_seen: int = -1


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	ink_material = ShaderMaterial.new()
	ink_material.shader = INK_SHADER
	ink_material.render_priority = -128
	var quad := QuadMesh.new()
	quad.size = Vector2(2.0, 2.0)
	quad.material = ink_material
	ink_quad = MeshInstance3D.new()
	ink_quad.name = "InkQuad"
	ink_quad.mesh = quad
	ink_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ink_quad.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	ink_quad.extra_cull_margin = 16384.0
	add_child(ink_quad)

	grade_layer = CanvasLayer.new()
	grade_layer.name = "GradeLayer"
	grade_layer.layer = GRADE_LAYER
	add_child(grade_layer)
	grade_material = ShaderMaterial.new()
	grade_material.shader = GRADE_SHADER
	grade_rect = ColorRect.new()
	grade_rect.name = "Grade"
	grade_rect.material = grade_material
	grade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grade_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	grade_layer.add_child(grade_rect)
	apply_quality("high")


func apply_preset(preset: Dictionary, sun_direction: Vector3) -> void:
	sun_dir = sun_direction.normalized()
	var g: Dictionary = preset.get("grade", {})
	for key in ["shadow_tint", "light_tint", "saturation", "lift", "warmth", "vignette", "sun_glow"]:
		if g.has(key):
			grade_material.set_shader_parameter(key, g[key])
	if g.has("grain"):
		grade_material.set_shader_parameter("grain_amount", g["grain"])


func _follow_atmosphere() -> void:
	if not is_instance_valid(_atmosphere) or not _atmosphere.is_inside_tree():
		_atmosphere = get_tree().get_first_node_in_group(&"atmosphere") as Atmosphere
		_atmosphere_seen = -1
		if _atmosphere == null:
			return
	if _atmosphere.changed != _atmosphere_seen and _atmosphere.sun != null:
		_atmosphere_seen = _atmosphere.changed
		apply_preset(_atmosphere.preset, _atmosphere.sun_direction())


func apply_quality(q: String) -> void:
	# The ink is part of the look on every preset; low only thins it.
	ink_material.set_shader_parameter("thickness", 1.0 if q == "low" else 1.25)


func set_enabled(on: bool) -> void:
	ink_quad.visible = on
	grade_material.set_shader_parameter("enabled", 1.0 if on else 0.0)


func snap() -> void:
	## Jump eased values to their targets (after a cut).
	_speed = speed_target
	_letterbox = letterbox_target
	_fade = fade_target


func _process(delta: float) -> void:
	var k := 1.0 - exp(-delta * 6.0)
	_speed = lerpf(_speed, speed_target, k)
	_letterbox = lerpf(_letterbox, letterbox_target, 1.0 - exp(-delta * 4.0))
	_fade = move_toward(_fade, fade_target, delta * 2.5)
	grade_material.set_shader_parameter("speed", _speed)
	grade_material.set_shader_parameter("letterbox", _letterbox)
	grade_material.set_shader_parameter("fade", _fade)
	_follow_atmosphere()
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	# Painted sun glow: screen position of the sun, faded when behind terrain.
	var fwd := -cam.global_transform.basis.z
	var facing := fwd.dot(sun_dir)
	var target_vis := 0.0
	var uv := Vector2(0.5, -1.0)
	if facing > 0.05:
		var world_sun := cam.global_position + sun_dir * 1000.0
		if not cam.is_position_behind(world_sun):
			var sp := cam.unproject_position(world_sun)
			var vs := get_viewport().get_visible_rect().size
			uv = sp / vs
			target_vis = smoothstep(0.05, 0.45, facing)
			var space := get_world_3d().direct_space_state
			var q := PhysicsRayQueryParameters3D.create(cam.global_position, cam.global_position + sun_dir * 900.0, occlusion_mask)
			if space.intersect_ray(q):
				target_vis *= 0.25
	_sun_vis = lerpf(_sun_vis, target_vis, 1.0 - exp(-delta * 5.0))
	grade_material.set_shader_parameter("sun_uv", uv)
	grade_material.set_shader_parameter("sun_vis", _sun_vis)
