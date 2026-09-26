extends Node3D
## Camera-following sky dressing: a ring of painted cumulus cards (one mesh,
## drawn far to near so a single transparent draw sorts itself) and volumes of
## falling petals (spring), drifting seed fluff (summer) and maple leaves (autumn)
## around the camera.
##
## Seasons blend: the three particle volumes emit by the season weights (`set_weights`), so
## petals thin out as fluff drifts in; the cloud colours follow the Atmosphere preset and the
## cards morph towards the summer towers by the preset's `cloud_tower` (both positions are in
## the mesh, the shader mixes them).

const CLOUD_SHADER := preload("res://shaders/clouds.gdshader")
const PETAL_SHADER := preload("res://shaders/petals.gdshader")
const CLOUD_ATLAS := preload("res://assets/textures/clouds.png")
const PETAL_TEX := preload("res://assets/textures/petal.png")
const LEAF_TEX := preload("res://assets/textures/leaf.png")
const ATLAS_COLS := 3
const ATLAS_ROWS := 2
const SEASONS := ["spring", "summer", "autumn"]
## Cloud towers: the mesh holds the cards at `cloud_tower` 1 and at this value.
const TOWER_MAX := 1.45
## Below this weight a season's volume stops emitting.
const EMIT_MIN := 0.005

var clouds: MeshInstance3D
var cloud_material: ShaderMaterial
## One falling volume per season (spring, summer, autumn).
var particles: Array[GPUParticles3D] = []
var follow: Node3D ## camera to follow; defaults to the viewport camera
var atmosphere: Atmosphere
var _atmosphere_seen: int = -1


func setup(atmos: Atmosphere, weights: Vector3) -> void:
	atmosphere = atmos
	_build_clouds()
	_follow_atmosphere()
	for i in 3:
		var p := _build_particles(SEASONS[i], weights[i])
		particles.append(p)
		add_child(p)


## Season weights (spring, summer, autumn; summing to 1): how much each volume emits.
func set_weights(w: Vector3) -> void:
	for i in particles.size():
		var p := particles[i]
		p.amount_ratio = clampf(w[i], 0.0, 1.0)
		var on := w[i] > EMIT_MIN
		if p.emitting != on:
			p.emitting = on


func _process(_delta: float) -> void:
	_follow_atmosphere()
	var cam: Node3D = follow if follow else get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	if clouds:
		clouds.global_position = Vector3(p.x, 0.0, p.z)
	var at := p + Vector3(0.0, 4.0, 0.0) - cam.global_transform.basis.z * 14.0
	for v in particles:
		v.global_position = at


func _follow_atmosphere() -> void:
	if atmosphere == null or atmosphere.changed == _atmosphere_seen:
		return
	_atmosphere_seen = atmosphere.changed
	var preset := atmosphere.preset
	cloud_material.set_shader_parameter("lit", preset.get("cloud_lit", Color.WHITE))
	cloud_material.set_shader_parameter("shade", preset.get("cloud_shade", Color("a9b4d8")))
	cloud_material.set_shader_parameter("deep_shade", preset.get("cloud_deep", Color("8c93c4")))
	cloud_material.set_shader_parameter("haze", preset.get("sky_haze", Color("eef3ef")))
	cloud_material.set_shader_parameter("tower", clampf((float(preset.get("cloud_tower", 1.0)) - 1.0) / (TOWER_MAX - 1.0), 0.0, 1.0))


func _build_clouds() -> void:
	# Two layers: big cumulus high enough to clear the valley ridges (the reason
	# they exist), and a far low stratus band that shows through mountain gaps.
	# `cloud_tower` scales the cumulus up (big summer towers) and sits them lower so
	# their flat bases stay near the horizon: VERTEX holds the cards at tower 1, CUSTOM0 at
	# TOWER_MAX (the same random draws), the shader mixes them.
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var cards: Array[Dictionary] = []
	var high := 26
	var low := 16
	for i in high + low:
		var is_low := i >= high
		var k := i - high if is_low else i
		var n := low if is_low else high
		var a := float(k) / n * TAU + rng.randf_range(-0.09, 0.09) + (0.13 if is_low else 0.0)
		var r := rng.randf_range(6400.0, 8200.0) if is_low else rng.randf_range(3000.0, 5200.0)
		var elev := rng.randf_range(0.03, 0.09) if is_low else rng.randf_range(0.11, 0.3)
		var w := rng.randf_range(2400.0, 3600.0) if is_low else rng.randf_range(1100.0, 2000.0)
		var cell := rng.randi_range(4, 5) if is_low else rng.randi_range(0, 3)
		cards.append({
			"a": a, "r": r, "w": w, "elev": elev, "cell": cell, "low": is_low,
			"haze": rng.randf_range(0.45, 0.6) if is_low else rng.randf_range(0.0, 0.22),
			"flip": rng.randf() < 0.5,
		})
	cards.sort_custom(func(p: Dictionary, q: Dictionary) -> bool: return p["r"] > q["r"])
	var pos := PackedVector3Array()
	var tall := PackedFloat32Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	var idx := PackedInt32Array()
	for c in cards:
		var a: float = c["a"]
		var r: float = c["r"]
		var cell: int = c["cell"]
		var out := Vector3(sin(a), 0.0, cos(a)) # away from the viewer
		var t := Vector3(cos(a), 0.0, -sin(a)) # along the ring
		var u0 := float(cell % ATLAS_COLS) / ATLAS_COLS
		var v0 := float(cell / ATLAS_COLS) / ATLAS_ROWS
		var base := pos.size()
		var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]
		for tower: float in [1.0, TOWER_MAX]:
			var e: float = c["elev"] if c["low"] else float(c["elev"]) / lerpf(1.0, tower, 0.6)
			var w: float = c["w"] if c["low"] else float(c["w"]) * tower
			# card plane faces the viewer: vertical axis leans in by the elevation
			var up := Vector3.UP * cos(e) - out * sin(e)
			var centre := out * (r * cos(e)) + Vector3.UP * (r * sin(e))
			var hw := w * 0.5
			var hh := w * (0.32 if cell >= 4 else 0.5)
			var corners := [Vector2(-hw, 0.0), Vector2(hw, 0.0), Vector2(hw, hh), Vector2(-hw, hh)]
			for k in 4:
				var o: Vector2 = corners[k]
				var v: Vector3 = centre + t * o.x + up * (o.y - hh * 0.35)
				if tower == 1.0:
					pos.append(v)
				else:
					tall.append_array([v.x, v.y, v.z])
		for k in 4:
			var tc: Vector2 = uvs[k]
			if c["flip"]:
				tc.x = 1.0 - tc.x
			uv.append(Vector2(u0 + tc.x / ATLAS_COLS, v0 + tc.y / ATLAS_ROWS))
			col.append(Color(c["haze"], 0.0, 0.0, 1.0))
		idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pos
	arr[Mesh.ARRAY_TEX_UV] = uv
	arr[Mesh.ARRAY_COLOR] = col
	arr[Mesh.ARRAY_INDEX] = idx
	arr[Mesh.ARRAY_CUSTOM0] = tall
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {},
			Mesh.ARRAY_CUSTOM_RGB_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
	cloud_material = ShaderMaterial.new()
	cloud_material.shader = CLOUD_SHADER
	cloud_material.set_shader_parameter("atlas", CLOUD_ATLAS)
	cloud_material.render_priority = -100
	mesh.surface_set_material(0, cloud_material)
	clouds = MeshInstance3D.new()
	clouds.name = "Clouds"
	clouds.mesh = mesh
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	clouds.extra_cull_margin = 16384.0
	clouds.custom_aabb = AABB(Vector3(-9000, -100, -9000), Vector3(18000, 5000, 18000))
	add_child(clouds)


## One season's falling volume, emitting `weight` of its amount.
func _build_particles(season: String, weight: float) -> GPUParticles3D:
	var autumn := season == "autumn"
	var summer := season == "summer"
	var petals := GPUParticles3D.new()
	petals.name = "Particles_%s" % season
	petals.amount = 260 if autumn else (140 if summer else 420)
	petals.lifetime = 9.0
	petals.preprocess = 9.0
	petals.fixed_fps = 0
	petals.local_coords = false
	petals.visibility_aabb = AABB(Vector3(-60, -40, -60), Vector3(120, 60, 120))
	petals.amount_ratio = clampf(weight, 0.0, 1.0)
	petals.emitting = weight > EMIT_MIN
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(36.0, 10.0, 36.0)
	pm.direction = Vector3(1.0, -0.6, 0.4) if not summer else Vector3(1.0, 0.15, 0.4)
	pm.spread = 25.0 if not summer else 60.0
	pm.initial_velocity_min = 0.6 if not summer else 0.3
	pm.initial_velocity_max = 1.6 if not summer else 0.9
	# seed fluff floats: almost no fall, a slow updraft wander
	pm.gravity = Vector3(0.35, -0.9 if autumn else (0.02 if summer else -0.55), 0.2)
	pm.angular_velocity_min = -160.0 if not summer else -30.0
	pm.angular_velocity_max = 160.0 if not summer else 30.0
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.4 if not summer else 2.2
	pm.turbulence_noise_scale = 5.0
	pm.turbulence_influence_min = 0.06
	pm.turbulence_influence_max = 0.14 if not summer else 0.22
	pm.scale_min = 0.8
	pm.scale_max = 1.3
	var ramp := Gradient.new()
	if autumn:
		ramp.set_color(0, Color("d94a2b"))
		ramp.add_point(0.5, Color("ee8a35"))
		ramp.set_color(ramp.get_point_count() - 1, Color("f2c046"))
	elif summer:
		ramp.set_color(0, Color("fffbe8"))
		ramp.add_point(0.6, Color("f6f1d2"))
		ramp.set_color(ramp.get_point_count() - 1, Color("f3e6a8"))
	else:
		ramp.set_color(0, Color("f6bfd0"))
		ramp.add_point(0.5, Color("fde6ee"))
		ramp.set_color(ramp.get_point_count() - 1, Color("f0a3bd"))
	var gt := GradientTexture1D.new()
	gt.gradient = ramp
	pm.color_initial_ramp = gt
	petals.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.2, 0.2) if autumn else (Vector2(0.07, 0.07) if summer else Vector2(0.11, 0.11))
	var mat := ShaderMaterial.new()
	mat.shader = PETAL_SHADER
	mat.set_shader_parameter("tex", LEAF_TEX if autumn else PETAL_TEX)
	quad.material = mat
	petals.draw_pass_1 = quad
	petals.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return petals
