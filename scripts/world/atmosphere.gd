class_name Atmosphere
extends Node3D
## Sun, painted sky, aerial fog, ambient and global cel-shading parameters for a
## time-of-day preset. The same preset drives the colour grade (PostFX reads
## `grade`), so a map's whole palette lives in one dictionary.
##
## In the world the look follows the season at the camera: `set_weights(w)` blends the three
## season presets (SEASON_PRESETS, weights spring / summer / autumn) into `preset` and applies it;
## `changed` counts the applications so PostFX and the sky rig can follow cheaply.

const SKY_SHADER := preload("res://shaders/sky.gdshader")
## The presets of the three seasons, in season-weight order (spring, summer, autumn).
const SEASON_PRESETS := ["spring_noon", "summer_afternoon", "autumn_golden"]
## Values a preset may leave out.
const DEFAULTS := {"cloud_tower": 1.0}

const PRESETS := {
	"spring_noon": {
		"sun_pitch": -50.0, "sun_yaw": 35.0,
		"sun_color": Color("fff3df"), "sun_energy": 1.0,
		"ambient_color": Color("b9b8dd"), "ambient_energy": 0.52, "ambient_sky": 0.35,
		"sky_top": Color("4f8fd8"), "sky_mid": Color("a4d2f0"), "sky_haze": Color("eef3ef"),
		"sky_ground": Color("c9d6d8"), "sky_sun": Color("fff2d8"), "halo": 1.0, "horizon_band": 0.22,
		"fog_color": Color("e2ebf0"), "fog_begin": 70.0, "fog_end": 1400.0, "fog_curve": 1.6,
		"fog_sun_scatter": 0.18, "fog_aerial": 0.55, "fog_height": -6.0, "fog_height_density": 0.0,
		"fog_sky_affect": 0.0,
		"shade_tint": Color("9a92c8"), "rim_color": Color("fff0dc"),
		"wind": Vector4(0.8, 0.6, 1.0, 0.37), "glow": 0.0,
		"exposure": 0.92,
		"grade": {
			"shadow_tint": Color("b3aed6"), "light_tint": Color("fff6ea"), "saturation": 1.08,
			"lift": 0.03, "warmth": 0.04, "vignette": 0.18, "sun_glow": Color("fff0d0"), "grain": 0.03,
		},
		"cloud_lit": Color("ffffff"), "cloud_shade": Color("a9b4d8"), "cloud_deep": Color("8c93c4"),
	},
	"autumn_golden": {
		"sun_pitch": -19.0, "sun_yaw": -62.0,
		"sun_color": Color("ffd4a4"), "sun_energy": 1.15,
		"ambient_color": Color("aea6d6"), "ambient_energy": 0.48, "ambient_sky": 0.35,
		"sky_top": Color("5a7fc8"), "sky_mid": Color("c9bad9"), "sky_haze": Color("ffdcbc"),
		"sky_ground": Color("c2aeb8"), "sky_sun": Color("ffcf98"), "halo": 1.3, "horizon_band": 0.4,
		"fog_color": Color("f4dcc2"), "fog_begin": 90.0, "fog_end": 1500.0, "fog_curve": 1.6,
		"fog_sun_scatter": 0.28, "fog_aerial": 0.5, "fog_height": -4.0, "fog_height_density": 0.0,
		"fog_sky_affect": 0.0,
		"shade_tint": Color("8d84c6"), "rim_color": Color("ffd6a6"),
		"wind": Vector4(0.9, 0.45, 1.1, 0.33), "glow": 0.15,
		"exposure": 0.95,
		"grade": {
			"shadow_tint": Color("a69ed6"), "light_tint": Color("ffe8cc"), "saturation": 1.12,
			"lift": 0.035, "warmth": 0.08, "vignette": 0.24, "sun_glow": Color("ffd8a8"), "grain": 0.03,
		},
		"cloud_lit": Color("fff1e2"), "cloud_shade": Color("b9a8cf"), "cloud_deep": Color("9486bf"),
	},
	"summer_afternoon": {
		# deep saturated sky, towering cumulus, a warm sun lowering into mid-afternoon,
		# crisp violet shade
		"sun_pitch": -33.0, "sun_yaw": -68.0,
		"sun_color": Color("ffe7c2"), "sun_energy": 1.12,
		"ambient_color": Color("aeb0e0"), "ambient_energy": 0.5, "ambient_sky": 0.3,
		"sky_top": Color("2f6fd0"), "sky_mid": Color("7fc0f0"), "sky_haze": Color("e4f0ec"),
		"sky_ground": Color("c4d4d2"), "sky_sun": Color("ffe8c4"), "halo": 1.1, "horizon_band": 0.26,
		"fog_color": Color("dcebef"), "fog_begin": 90.0, "fog_end": 1600.0, "fog_curve": 1.7,
		"fog_sun_scatter": 0.22, "fog_aerial": 0.5, "fog_height": -6.0, "fog_height_density": 0.0,
		"fog_sky_affect": 0.0,
		"shade_tint": Color("8a82cc"), "rim_color": Color("ffe4bc"),
		"wind": Vector4(0.7, 0.5, 0.9, 0.3), "glow": 0.08,
		"exposure": 0.93,
		"grade": {
			"shadow_tint": Color("a49ee0"), "light_tint": Color("fff1dc"), "saturation": 1.14,
			"lift": 0.025, "warmth": 0.06, "vignette": 0.2, "sun_glow": Color("ffe6c0"), "grain": 0.03,
		},
		"cloud_lit": Color("fffaf0"), "cloud_shade": Color("a3b0dc"), "cloud_deep": Color("848ec8"),
		"cloud_tower": 1.45,
	},
}

@export var preset_name: String = "spring_noon"

var preset: Dictionary = {}
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var environment: Environment
var sky_material: ShaderMaterial
## Applications of a preset so far (build and every set_weights).
var changed: int = 0
var weights := Vector3(-1.0, -1.0, -1.0)


func _ready() -> void:
	add_to_group(&"atmosphere")
	if sun == null:
		build(preset_name)


## Builds the sun, sky and environment for one named preset.
func build(name_: String) -> void:
	preset_name = name_
	for c in get_children():
		c.queue_free()

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 0.6
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 320.0
	sun.directional_shadow_split_1 = 0.06
	sun.directional_shadow_split_2 = 0.18
	sun.directional_shadow_split_3 = 0.45
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_fade_start = 0.85
	sun.light_angular_distance = 0.4
	add_child(sun)

	sky_material = ShaderMaterial.new()
	sky_material.shader = SKY_SHADER
	var sky := Sky.new()
	sky.sky_material = sky_material
	# the same result as QUALITY, spread over a few frames when the season shifts the sky
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.glow_enabled = true
	environment.glow_intensity = 0.45
	environment.glow_strength = 1.0
	environment.glow_bloom = 0.0
	environment.glow_hdr_threshold = 1.05
	environment.glow_hdr_scale = 2.0
	environment.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	environment.set_glow_level(0, 0.0)
	environment.set_glow_level(1, 0.0)
	environment.set_glow_level(2, 1.0)
	environment.set_glow_level(3, 0.8)
	environment.set_glow_level(4, 0.6)
	environment.set_glow_level(5, 0.3)
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_energy = 1.0
	environment.fog_density = 1.0

	world_env = WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = environment
	add_child(world_env)
	_apply(PRESETS.get(name_, PRESETS["spring_noon"]))


## Blends the season presets by `w` (spring, summer, autumn; any scale) and applies the
## result. Cheap enough per frame; callers skip it while the weights hold still.
func set_weights(w: Vector3) -> void:
	weights = w
	_apply(blend(w))


## The three season presets mixed by `w`. A pure weight returns that preset's values.
static func blend(w: Vector3) -> Dictionary:
	var total := w.x + w.y + w.z
	var k := [w.x / total, w.y / total, w.z / total] if total > 0.0 else [1.0, 0.0, 0.0]
	var src: Array[Dictionary] = []
	for n: String in SEASON_PRESETS:
		src.append(PRESETS[n])
	var out := _mix(src, k)
	# the sun: mix directions, not angles (yaws wrap), then back to pitch / yaw
	var dir := Vector3.ZERO
	for i in 3:
		dir += _sun_vector(src[i]["sun_pitch"], src[i]["sun_yaw"]) * float(k[i])
	dir = dir.normalized()
	out["sun_pitch"] = rad_to_deg(asin(clampf(-dir.y, -1.0, 1.0)))
	out["sun_yaw"] = rad_to_deg(atan2(dir.x, dir.z))
	return out


static func _mix(src: Array[Dictionary], k: Array) -> Dictionary:
	var out := {}
	var keys: Array = src[0].keys()
	for d in src:
		for key in d:
			if not key in keys:
				keys.append(key)
	for key in keys:
		var first: Variant = src[0].get(key, DEFAULTS.get(key))
		match typeof(first):
			TYPE_DICTIONARY:
				var subs: Array[Dictionary] = []
				for d in src:
					subs.append(d[key])
				out[key] = _mix(subs, k)
			TYPE_COLOR:
				var c := Color(0, 0, 0, 0)
				for i in src.size():
					var ci: Color = src[i][key]
					c += ci * float(k[i])
				out[key] = c
			TYPE_VECTOR4:
				var v := Vector4.ZERO
				for i in src.size():
					v += (src[i][key] as Vector4) * float(k[i])
				out[key] = v
			_:
				var f := 0.0
				for i in src.size():
					f += float(src[i].get(key, DEFAULTS.get(key, 0.0))) * float(k[i])
				out[key] = f
	return out


## Direction toward the sun for a light rotated by (pitch, yaw) degrees.
static func _sun_vector(pitch: float, yaw: float) -> Vector3:
	return Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0.0)).z


func _apply(p: Dictionary) -> void:
	preset = p
	sun.rotation_degrees = Vector3(p["sun_pitch"], p["sun_yaw"], 0.0)
	sun.light_color = p["sun_color"]
	sun.light_energy = p["sun_energy"]

	sky_material.set_shader_parameter("sky_top", p["sky_top"])
	sky_material.set_shader_parameter("sky_mid", p["sky_mid"])
	sky_material.set_shader_parameter("sky_haze", p["sky_haze"])
	sky_material.set_shader_parameter("ground", p["sky_ground"])
	sky_material.set_shader_parameter("sun_color", p["sky_sun"])
	sky_material.set_shader_parameter("halo", p["halo"])
	sky_material.set_shader_parameter("horizon_band", p["horizon_band"])

	environment.ambient_light_color = p["ambient_color"]
	environment.ambient_light_energy = p["ambient_energy"]
	environment.ambient_light_sky_contribution = p["ambient_sky"]
	environment.tonemap_exposure = p["exposure"]
	environment.fog_light_color = p["fog_color"]
	environment.fog_sun_scatter = p["fog_sun_scatter"]
	environment.fog_depth_begin = p["fog_begin"]
	environment.fog_depth_end = p["fog_end"]
	environment.fog_depth_curve = p["fog_curve"]
	environment.fog_aerial_perspective = p["fog_aerial"]
	environment.fog_sky_affect = p["fog_sky_affect"]
	environment.fog_height = p["fog_height"]
	environment.fog_height_density = p["fog_height_density"]

	RenderingServer.global_shader_parameter_set("sr_shade_tint", p["shade_tint"])
	RenderingServer.global_shader_parameter_set("sr_rim_color", p["rim_color"])
	RenderingServer.global_shader_parameter_set("sr_wind", p["wind"])
	RenderingServer.global_shader_parameter_set("sr_glow", p["glow"])
	changed += 1


func sun_direction() -> Vector3:
	## Direction TOWARD the sun (world space).
	## The rig sits at the origin unrotated, so the local basis is the world basis.
	return sun.transform.basis.z.normalized() if sun else Vector3.UP
