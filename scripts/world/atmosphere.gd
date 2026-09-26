class_name Atmosphere
extends Node3D
## Sun, painted sky, aerial fog, ambient and global cel-shading parameters for a
## time-of-day preset. The same preset drives the colour grade (PostFX reads
## `grade`), so a map's whole palette lives in one dictionary.

const SKY_SHADER := preload("res://shaders/sky.gdshader")

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


func _ready() -> void:
	if sun == null:
		build(preset_name)


func build(name_: String) -> void:
	preset_name = name_
	preset = PRESETS.get(name_, PRESETS["spring_noon"])
	for c in get_children():
		c.queue_free()

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(preset["sun_pitch"], preset["sun_yaw"], 0.0)
	sun.light_color = preset["sun_color"]
	sun.light_energy = preset["sun_energy"]
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
	sky_material.set_shader_parameter("sky_top", preset["sky_top"])
	sky_material.set_shader_parameter("sky_mid", preset["sky_mid"])
	sky_material.set_shader_parameter("sky_haze", preset["sky_haze"])
	sky_material.set_shader_parameter("ground", preset["sky_ground"])
	sky_material.set_shader_parameter("sun_color", preset["sky_sun"])
	sky_material.set_shader_parameter("halo", preset["halo"])
	sky_material.set_shader_parameter("horizon_band", preset["horizon_band"])
	var sky := Sky.new()
	sky.sky_material = sky_material
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	sky.radiance_size = Sky.RADIANCE_SIZE_256

	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_color = preset["ambient_color"]
	environment.ambient_light_energy = preset["ambient_energy"]
	environment.ambient_light_sky_contribution = preset["ambient_sky"]
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.tonemap_exposure = preset["exposure"]
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
	environment.fog_light_color = preset["fog_color"]
	environment.fog_light_energy = 1.0
	environment.fog_sun_scatter = preset["fog_sun_scatter"]
	environment.fog_depth_begin = preset["fog_begin"]
	environment.fog_depth_end = preset["fog_end"]
	environment.fog_depth_curve = preset["fog_curve"]
	environment.fog_aerial_perspective = preset["fog_aerial"]
	environment.fog_sky_affect = preset["fog_sky_affect"]
	environment.fog_height = preset["fog_height"]
	environment.fog_height_density = preset["fog_height_density"]
	environment.fog_density = 1.0

	world_env = WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = environment
	add_child(world_env)

	RenderingServer.global_shader_parameter_set("sr_shade_tint", preset["shade_tint"])
	RenderingServer.global_shader_parameter_set("sr_rim_color", preset["rim_color"])
	RenderingServer.global_shader_parameter_set("sr_wind", preset["wind"])
	RenderingServer.global_shader_parameter_set("sr_glow", preset["glow"])


func sun_direction() -> Vector3:
	## Direction TOWARD the sun (world space).
	## The rig sits at the origin unrotated, so the local basis is the world basis.
	return sun.transform.basis.z.normalized() if sun else Vector3.UP
