extends SceneTree
## Offscreen preview of a car GLB as imported by Godot. Steers the front wheels to verify the
## wheel rest bases.
##
## Run (rendered, never in a plain window): $S --summer-offscreen --audio-driver Dummy
##     --disable-crash-handler --path . -s res://tools/car_check/preview_car.gd
##     [-- [res://assets/models/car/<car>.glb] [--livery=Sakura,Sora] [--popups=<degrees>]]
##
## Without --livery: stock StandardMaterial3D (no toon conversion) on a flat backdrop — catches
## import problems Blender renders cannot: flipped normals, culled faces, wrong axes, material
## slots. Writes docs/renders/<stem>_godot_<view>.png.
## With --livery: the in-game look instead — toon materials and inked hulls as CarLook sets them,
## the named Game.CAR_COLORS livery on Paint / Paint2, the spring_noon atmosphere and the PostFX
## ink + grade. Writes docs/renders/<stem>_godot_<livery>_<view>.png per livery.
## --popups raises PopUp_L / PopUp_R by that many degrees about their local +X.
## <stem> is "car" for rally_car.glb and "car_<name>" for any other <name>.glb.

const DEFAULT_CAR := "res://assets/models/car/rally_car.glb"
const STEER_ANGLE := 0.35
const VIEWS := {
	"front34": [Vector3(-4.2, 1.6, -4.8), Vector3(0.0, 0.55, -0.2)],
	"rear34": [Vector3(4.4, 2.2, 5.2), Vector3(0.0, 0.6, 0.2)],
}


func _initialize() -> void:
	var car_path := DEFAULT_CAR
	var liveries: PackedStringArray = []
	var popup_deg := 0.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--livery="):
			liveries = arg.trim_prefix("--livery=").split(",", false)
		elif arg.begins_with("--popups="):
			popup_deg = arg.trim_prefix("--popups=").to_float()
		else:
			car_path = arg
	var base_name := car_path.get_file().get_basename()
	var stem := "car" if base_name == "rally_car" else "car_" + base_name

	var scene_root := Node3D.new()
	root.add_child(scene_root)
	var toon := not liveries.is_empty()
	if toon:
		await _toon_stage(scene_root)
	else:
		_plain_stage(scene_root)

	var car := (load(car_path) as PackedScene).instantiate() as Node3D
	scene_root.add_child(car)
	for wheel_name in ["Wheel_FL", "Wheel_FR", "Caliper_FL", "Caliper_FR"]:
		var w := car.find_child(wheel_name, true, false) as Node3D
		w.basis = Basis(Vector3.UP, STEER_ANGLE) * w.basis
	for popup_name in ["PopUp_L", "PopUp_R"]:
		var p := car.find_child(popup_name, true, false) as Node3D
		if p != null:
			p.basis = p.basis * Basis(Vector3.RIGHT, deg_to_rad(popup_deg))

	var cam := Camera3D.new()
	cam.fov = 40.0
	scene_root.add_child(cam)
	cam.make_current()

	var out_dir := ProjectSettings.globalize_path("res://docs/renders")
	var runs: Array = liveries if toon else [""]
	for livery_name: String in runs:
		var tag := ""
		if toon:
			var livery := _livery(livery_name)
			if livery.is_empty():
				push_error("unknown livery '%s' (see Game.CAR_COLORS)" % livery_name)
				continue
			_convert_toon(car, livery["primary"], livery["secondary"])
			tag = String(livery["name"]).to_lower() + "_"
		for view_name: String in VIEWS:
			var v: Array = VIEWS[view_name]
			cam.look_at_from_position(v[0], v[1], Vector3.UP)
			for i in 12:
				await process_frame
			var img := root.get_viewport().get_texture().get_image()
			var path := out_dir.path_join("%s_godot_%s%s.png" % [stem, tag, view_name])
			img.save_png(path)
			print("saved ", path)
	root.get_node("Game").request_quit(0)


func _plain_stage(scene_root: Node3D) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("dce8f0")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("c9c4e6")
	env.ambient_light_energy = 0.8
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	scene_root.add_child(world_env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	scene_root.add_child(sun)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(40.0, 40.0)
	ground.mesh = plane
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color("cfd6c4")
	ground.material_override = ground_mat
	scene_root.add_child(ground)


func _toon_stage(scene_root: Node3D) -> void:
	var atmosphere := Atmosphere.new()
	scene_root.add_child(atmosphere)
	atmosphere.build("spring_noon")
	var post := PostFX.new()
	scene_root.add_child(post)
	await process_frame   # PostFX builds its passes in _ready
	post.apply_preset(atmosphere.preset, atmosphere.sun_direction())

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	ground.material_override = ToonMaterials.make(Color("505669"), {"ramp": "terrain", "grain": 0.06})
	scene_root.add_child(ground)


func _livery(livery_name: String) -> Dictionary:
	var game := root.get_node("Game")
	for c: Dictionary in game.CAR_COLORS:
		if String(c["name"]).to_lower() == livery_name.to_lower():
			return c
	return {}


## Same per-material options and ink hulls as CarLook.apply, with the livery baked into Paint /
## Paint2 (the in-game path duplicates and recolours them per car instance afterwards).
func _convert_toon(car: Node3D, primary: Color, secondary: Color) -> void:
	for node in car.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if src == null:
				continue
			var n := src.resource_name.to_lower()
			var color := src.albedo_color
			if n.contains("paint2"):
				color = secondary
			elif n.contains("paint"):
				color = primary
			var mat: Material = ToonMaterials.make(color, CarLook._opts(n, src))
			for key: String in CarLook.OUTLINED:
				if n.contains(key):
					mat = ToonMaterials.with_outline(mat, 1.5 if key != "rubber" else 1.3)
					break
			mi.set_surface_override_material(s, mat)
