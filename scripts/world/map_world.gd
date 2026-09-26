class_name MapWorld
extends Node3D
## Builds a playable map from the compiled pack written by tools/mapgen/mapgen.py:
## assets/maps/<id>/map.json (descriptors, track, instances) + map.bin (arrays).
##
## After `build()` finishes: `track`, `spawn`, `checkpoints`, `atmosphere` and
## `sun_dir` are ready for the race session, the car and the camera. Open roads
## (liaisons, `closed == false`) also have an arrival zone: `arrival` (on the road,
## facing along it) and `arrival_radius`, reached at progress `arrival_progress`.
##
## Course dressing is soft (`soft_course`, scripts/world/soft_course.gd): SMASHABLE props get
## no collider and break when a car drives through them, the start/finish arch legs wobble, and
## fabric gates stand at the checkpoints (the pack's `checkpoint_gate` instances are skipped).

signal build_progress(fraction: float, label: String)
signal built

const MANIFEST_PATH := "res://assets/models/props/manifest.json"
const CHUNK := 160.0
## Road sign debris: triangles reaching down below this share of the sign's height are the posts.
const SIGN_POST_SHARE := 0.4
const TERRAIN_SHADER := preload("res://shaders/terrain.gdshader")
const ROAD_SHADER := preload("res://shaders/road.gdshader")
const WATER_SHADER := preload("res://shaders/water.gdshader")
const BACKDROP_SHADER := preload("res://shaders/backdrop.gdshader")
const SkyRigScript := preload("res://scripts/world/sky_rig.gd")
const TerrainBodyScript := preload("res://scripts/world/terrain_body.gd")
const GameScript := preload("res://scripts/autoload/game.gd")
const FONT_LATIN := preload("res://assets/fonts/DelaGothicOne-Regular.ttf")
const FONT_JP := preload("res://assets/fonts/YujiSyuku-Regular.ttf")
const INK := Color("2a2235")

## Parked-car models by car id (the Game.CARS ids).
const PARKED_MODELS := {
	"sakura": "res://assets/models/car/rally_car.glb",
	"hayate": "res://assets/models/car/hayate.glb",
}

const LAYER_WORLD := 1
const LAYER_PROPS := 4 # bit 3

## Season look: fallen litter colours on the ground and road.
const SEASONS := {
	"spring": {
		"litter": [Color("f7c3d3"), Color("fde4ec"), Color("f09bb8")],
		"terrain_litter": 0.55, "road_litter": 0.32,
	},
	"summer": {
		# a few green leaves and clover heads under the trees, nothing on the move
		"litter": [Color("7fae55"), Color("a4c86a"), Color("eef0dc")],
		"terrain_litter": 0.22, "road_litter": 0.1,
	},
	"autumn": {
		"litter": [Color("dc4a2c"), Color("ef8a36"), Color("f1bf45")],
		"terrain_litter": 0.62, "road_litter": 0.4,
	},
}

## Visibility range (m, 0 = unlimited) and shadow casting per manifest category.
const CATEGORY_VIEW := {
	"ground_cover": [85.0, false],
	"vegetation": [210.0, true],
	"rock": [420.0, true],
	"tree": [1300.0, true],
	"building": [900.0, true],
	"village": [500.0, true],
	"roadside": [450.0, true],
	"rally": [500.0, true],
	"spectator": [260.0, true],
	"vehicle": [500.0, true],
}

@export var map_id: String = "hanami"
@export var build_on_ready: bool = false

var info: Dictionary = {}
var bin: PackedByteArray
var manifest: Dictionary = {}
var track: Track
var atmosphere: Atmosphere
var sky_rig: Node3D
var spawn: Transform3D
var start_line: Transform3D
var closed: bool = true
var arrival: Transform3D
var arrival_radius: float = 0.0
var arrival_progress: float = 0.0
var checkpoints: Array[Dictionary] = []
var soft_course: SoftCourse
var terrain_body: StaticBody3D
var sun_dir: Vector3 = Vector3.UP
var season: Dictionary = {}
var materials: Dictionary = {}
var stats: Dictionary = {}
var is_built: bool = false
var _arches := PackedVector3Array()


func _ready() -> void:
	if build_on_ready:
		build()


## Builds everything. Awaits a frame between phases so a loading screen can animate.
func build(yield_frames: bool = false) -> void:
	var t0 := Time.get_ticks_msec()
	_load_pack()
	season = SEASONS.get(info.get("season", "spring"), SEASONS["spring"])
	build_progress.emit(0.05, "sky")
	atmosphere = Atmosphere.new()
	atmosphere.name = "Atmosphere"
	add_child(atmosphere)
	atmosphere.build(info.get("atmosphere", "spring_noon"))
	sun_dir = atmosphere.sun_direction()
	_make_materials()
	if yield_frames:
		await get_tree().process_frame
	build_progress.emit(0.15, "terrain")
	_build_track()
	_build_meshes()
	if yield_frames:
		await get_tree().process_frame
	build_progress.emit(0.55, "props")
	_load_manifest()
	soft_course = SoftCourse.new()
	add_child(soft_course)
	_build_instances()
	if yield_frames:
		await get_tree().process_frame
	build_progress.emit(0.85, "details")
	_build_barriers()
	_build_checkpoints()
	soft_course.build_gates(checkpoints, track, closed, _arches)
	_build_signs()
	_build_parked()
	sky_rig = Node3D.new()
	sky_rig.set_script(SkyRigScript)
	sky_rig.name = "SkyRig"
	add_child(sky_rig)
	sky_rig.setup(atmosphere.preset, info.get("season", "spring"))
	stats["build_ms"] = Time.get_ticks_msec() - t0
	is_built = true
	build_progress.emit(1.0, "ready")
	built.emit()


# ------------------------------------------------------------------ pack

func _load_pack() -> void:
	var json_path := "res://assets/maps/%s/map.json" % map_id
	var text := FileAccess.get_file_as_string(json_path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("MapWorld: cannot parse %s" % json_path)
		return
	info = parsed
	bin = FileAccess.get_file_as_bytes(info["bin"])
	if bin.is_empty():
		push_error("MapWorld: empty mesh pack %s" % info["bin"])


func _raw(name_: String) -> Dictionary:
	for r in info["raw"]:
		if r["name"] == name_:
			return r
	return {}


func _mesh_arrays(d: Dictionary) -> Array:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	var off: int = d["offset"]
	var vc: int = d["vcount"]
	for a in d["attrs"]:
		match a:
			"pos":
				arr[Mesh.ARRAY_VERTEX] = bin.slice(off, off + vc * 12).to_vector3_array()
				off += vc * 12
			"nrm":
				arr[Mesh.ARRAY_NORMAL] = bin.slice(off, off + vc * 12).to_vector3_array()
				off += vc * 12
			"col":
				arr[Mesh.ARRAY_COLOR] = bin.slice(off, off + vc * 16).to_color_array()
				off += vc * 16
			"uv":
				arr[Mesh.ARRAY_TEX_UV] = bin.slice(off, off + vc * 8).to_vector2_array()
				off += vc * 8
			"idx":
				var ic: int = d["icount"]
				arr[Mesh.ARRAY_INDEX] = bin.slice(off, off + ic * 4).to_int32_array()
				off += ic * 4
	if d.has("uv2_raw"):
		var r := _raw(d["uv2_raw"])
		arr[Mesh.ARRAY_TEX_UV2] = bin.slice(r["offset"], r["offset"] + r["bytes"]).to_vector2_array()
	return arr


# ------------------------------------------------------------------ materials

func _make_materials() -> void:
	var mats: Dictionary = info.get("materials", {})
	var litter: Array = season["litter"]

	var terrain := ShaderMaterial.new()
	terrain.shader = TERRAIN_SHADER
	var ramp: Array = ToonMaterials.RAMPS["terrain"]
	terrain.set_shader_parameter("ramp_edges", ramp[0])
	terrain.set_shader_parameter("ramp_values", ramp[1])
	terrain.set_shader_parameter("litter_a", litter[0])
	terrain.set_shader_parameter("litter_b", litter[1])
	terrain.set_shader_parameter("litter_c", litter[2])
	terrain.set_shader_parameter("litter_density", season["terrain_litter"])
	materials["terrain"] = terrain

	var rm: Dictionary = mats.get("road", {})
	var road := ShaderMaterial.new()
	road.shader = ROAD_SHADER
	road.set_shader_parameter("ramp_edges", ramp[0])
	road.set_shader_parameter("ramp_values", ramp[1])
	road.set_shader_parameter("half_width_m", info.get("road_half_width", 3.5))
	if rm.has("tarmac_color"):
		road.set_shader_parameter("tarmac_color", Color(rm["tarmac_color"]))
		road.set_shader_parameter("tarmac_patch", Color(rm["tarmac_color"]).darkened(0.12))
	if rm.has("gravel_color"):
		road.set_shader_parameter("gravel_color", Color(rm["gravel_color"]))
	if rm.has("gravel_dark"):
		road.set_shader_parameter("gravel_dark", Color(rm["gravel_dark"]))
	if rm.has("line_color"):
		road.set_shader_parameter("line_color", Color(rm["line_color"]))
	if rm.has("centre_line"):
		road.set_shader_parameter("centre_color", Color(rm["centre_line"]))
	road.set_shader_parameter("litter_a", litter[0])
	road.set_shader_parameter("litter_b", litter[1])
	road.set_shader_parameter("litter_c", litter[2])
	road.set_shader_parameter("litter_density", season["road_litter"])
	materials["road"] = road
	# paved lots (turn-arounds, service parks): the same surface without lane markings
	var lot := road.duplicate() as ShaderMaterial
	lot.set_shader_parameter("lot_mode", true)
	materials["lot"] = lot

	var wm: Dictionary = mats.get("water", {})
	for kind in ["water", "water_river"]:
		var w := ShaderMaterial.new()
		w.shader = WATER_SHADER
		w.set_shader_parameter("ramp_edges", ToonMaterials.RAMPS["soft"][0])
		w.set_shader_parameter("ramp_values", ToonMaterials.RAMPS["soft"][1])
		w.set_shader_parameter("sun_dir", sun_dir)
		w.set_shader_parameter("flow", 1.0 if kind == "water_river" else 0.0)
		w.set_shader_parameter("receive_shadow", 0.7)
		if wm.has("shallow"):
			w.set_shader_parameter("shallow", Color(wm["shallow"]))
		if wm.has("deep"):
			w.set_shader_parameter("deep", Color(wm["deep"]))
		var p: Dictionary = atmosphere.preset
		w.set_shader_parameter("sky_reflect", (p["sky_mid"] as Color).lerp(p["sky_haze"], 0.35))
		w.render_priority = 1
		materials[kind] = w

	var bd := ShaderMaterial.new()
	bd.shader = BACKDROP_SHADER
	bd.set_shader_parameter("ramp_edges", ToonMaterials.RAMPS["soft"][0])
	bd.set_shader_parameter("ramp_values", ToonMaterials.RAMPS["soft"][1])
	bd.set_shader_parameter("receive_shadow", 0.0)
	bd.set_shader_parameter("haze", atmosphere.preset["sky_haze"])
	bd.set_shader_parameter("haze_sun", atmosphere.preset["fog_color"].lerp(atmosphere.preset["sky_sun"], 0.5))
	bd.set_shader_parameter("sun_dir", sun_dir)
	materials["backdrop"] = bd

	materials["props_vc"] = ToonMaterials.make(Color.WHITE, {"vertex_color": true, "ramp": "cel", "grain": 0.05})


# ------------------------------------------------------------------ track

func _build_track() -> void:
	var r := _raw("track")
	closed = info.get("closed", true)
	track = Track.new()
	track.setup(bin.slice(r["offset"], r["offset"] + r["bytes"]).to_float32_array(), info["road"], closed)
	var sp: Dictionary = info["spawn"]
	var sp_pos := Vector3(sp["pos"][0], sp["pos"][1], sp["pos"][2])
	spawn = Transform3D(Basis(Vector3.UP, sp["yaw"]), sp_pos)
	var st: Dictionary = info["road"]["start"]
	start_line = Transform3D(Basis(Vector3.UP, st["yaw"]), Vector3(st["pos"][0], st["pos"][1], st["pos"][2]))
	var ar: Dictionary = info.get("arrival", {})
	if not closed and not ar.is_empty():
		arrival = Transform3D(Basis(Vector3.UP, ar["yaw"]), Vector3(ar["pos"][0], ar["pos"][1], ar["pos"][2]))
		arrival_radius = ar["radius"]
		arrival_progress = track.length


# ------------------------------------------------------------------ meshes and colliders

func _build_meshes() -> void:
	var terrain_root := Node3D.new()
	terrain_root.name = "Terrain"
	add_child(terrain_root)
	terrain_body = StaticBody3D.new()
	terrain_body.set_script(TerrainBodyScript)
	terrain_body.name = "TerrainBody"
	terrain_body.collision_layer = LAYER_WORLD
	terrain_body.collision_mask = 0
	terrain_body.set_meta(&"surface", &"grass")
	add_child(terrain_body)
	var sg := _raw("surface_grid")
	if not sg.is_empty():
		terrain_body.setup(bin.slice(sg["offset"], sg["offset"] + sg["bytes"]), int(sg["shape"][0]),
			sg["origin"], sg["cell"], sg["codes"], track)

	var road_root := Node3D.new()
	road_root.name = "Road"
	add_child(road_root)
	var water_root := Node3D.new()
	water_root.name = "Water"
	add_child(water_root)
	var tris := 0
	for d in info["meshes"]:
		if d.get("local", false):
			continue # a road sign's own mesh, in its frame: _build_signs places it
		var arr := _mesh_arrays(d)
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		tris += int(d["icount"]) / 3
		var mat_key: String = d["material"]
		var mat: Material = materials.get(mat_key, materials["props_vc"])
		mesh.surface_set_material(0, mat)
		var mi := MeshInstance3D.new()
		mi.name = d["name"]
		mi.mesh = mesh
		var parent: Node3D = self
		match mat_key:
			"terrain":
				parent = terrain_root
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			"road", "lot":
				parent = road_root
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			"water", "water_river":
				parent = water_root
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			"backdrop":
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.extra_cull_margin = 2000.0
			_:
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		parent.add_child(mi)
		if d.get("collide", "none") == "trimesh":
			var shape := mesh.create_trimesh_shape()
			if mat_key == "terrain":
				var owner_id := terrain_body.create_shape_owner(mi)
				terrain_body.shape_owner_add_shape(owner_id, shape)
			else:
				var body := StaticBody3D.new()
				body.name = "%s_body" % d["name"]
				body.collision_layer = LAYER_WORLD
				body.collision_mask = 0
				body.set_meta(&"surface", StringName(d.get("surface", "tarmac")))
				var cs := CollisionShape3D.new()
				cs.shape = shape
				body.add_child(cs)
				road_root.add_child(body)
	stats["tris_static"] = tris


# ------------------------------------------------------------------ props

func _load_manifest() -> void:
	var text := FileAccess.get_file_as_string(MANIFEST_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("MapWorld: no props manifest at %s" % MANIFEST_PATH)
		return
	for p in parsed["props"]:
		manifest[p["name"]] = p


func _prop_mesh(name_: String) -> Mesh:
	var m: Dictionary = manifest.get(name_, {})
	var path: String = m.get("file", "res://assets/models/props/%s.glb" % name_)
	if not ResourceLoader.exists(path):
		push_warning("MapWorld: missing prop %s" % path)
		return null
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var root := scene.instantiate()
	var mi := _find_mesh(root)
	var mesh: Mesh = mi.mesh if mi else null
	if mesh:
		var cat: String = m.get("category", "")
		var extra := {}
		if cat == "ground_cover":
			extra = {"sway": 0.9, "sway_start": 0.02, "sway_end": 0.5}
		elif name_.begins_with("reeds") or name_.begins_with("fern"):
			extra = {"sway": 0.7, "sway_start": 0.1, "sway_end": 1.8}
		elif name_.begins_with("bush") or name_.begins_with("azalea"):
			extra = {"sway": 0.35, "sway_start": 0.2, "sway_end": 1.2}
		for s in mesh.get_surface_count():
			var src := mesh.surface_get_material(s)
			if src == null or src is ShaderMaterial:
				continue
			var base := src as BaseMaterial3D
			var mat_name := src.resource_name
			var color := base.albedo_color if base else Color.WHITE
			var am := mesh as ArrayMesh
			var has_vc: bool = am != null and (am.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR) != 0
			var o := ToonMaterials.opts_for_name(mat_name, has_vc)
			if o.has("sway"):
				o.merge(extra, true)
			if base and o.has("emission_energy") and not o.has("emission"):
				o["emission"] = base.emission if base.emission_enabled else color
			if mat_name.to_lower().contains("water"):
				o = {"ramp": "soft", "gloss": 0.3, "spec": 1.5, "spec_size": 0.99, "vertex_color": has_vc}
			mesh.surface_set_material(s, ToonMaterials.make(color, o))
	root.free()
	return mesh


func _find_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_mesh(c)
		if r:
			return r
	return null


func _build_instances() -> void:
	var inst: Dictionary = info.get("instances", {})
	var props_root := Node3D.new()
	props_root.name = "Props"
	add_child(props_root)
	var bodies := {}
	var total := 0
	var shapes := 0
	var smashables := 0
	var uprights := 0
	_arches.clear()
	for prop_name in inst.keys():
		if prop_name in SoftCourse.SKIPPED_PROPS:
			continue
		var smashable := SoftCourse.is_smashable(prop_name)
		var soft_legs: bool = prop_name in SoftCourse.SOFT_UPRIGHT_PROPS
		var mesh := _prop_mesh(prop_name)
		if mesh == null:
			continue
		var m: Dictionary = manifest.get(prop_name, {})
		var cat: String = m.get("category", "vegetation")
		var view: Array = CATEGORY_VIEW.get(cat, [600.0, true])
		var vis_end: float = view[0]
		if cat == "rock" and (m.get("size", [1, 1, 1])[0] as float) > 6.0:
			vis_end = 0.0 # cliffs stay visible
		var groups := {}
		for e in inst[prop_name]:
			var key := Vector2i(int(floor(e[0] / CHUNK)), int(floor(e[2] / CHUNK)))
			if not groups.has(key):
				groups[key] = []
			groups[key].append(e)
		for key in groups.keys():
			var list: Array = groups[key]
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = mesh
			mm.instance_count = list.size()
			for k in list.size():
				var e: Array = list[k]
				var sc: float = e[4]
				var b := Basis(Vector3.UP, e[3]).scaled(Vector3(sc, sc, sc))
				mm.set_instance_transform(k, Transform3D(b, Vector3(e[0], e[1], e[2])))
				if smashable:
					soft_course.add_smashable(prop_name, mesh, mm, k, e, m)
					smashables += 1
				elif soft_legs:
					uprights += soft_course.add_soft_uprights(mm, k, e, m)
					_arches.append(Vector3(e[0], e[1], e[2]))
			var mmi := MultiMeshInstance3D.new()
			mmi.name = "%s_%d_%d" % [prop_name, key.x, key.y]
			mmi.multimesh = mm
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if view[1] else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if vis_end > 0.0:
				mmi.visibility_range_end = vis_end
				mmi.visibility_range_end_margin = vis_end * 0.15
				mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			props_root.add_child(mmi)
			total += list.size()
		# collision: soft dressing has none, SoftCourse tests it against the cars itself
		var col: Dictionary = m.get("collision", {"type": "none"})
		if smashable or soft_legs or col.get("type", "none") == "none":
			continue
		for e in inst[prop_name]:
			var key := Vector2i(int(floor(e[0] / CHUNK)), int(floor(e[2] / CHUNK)))
			var body: StaticBody3D = bodies.get(key)
			if body == null:
				body = StaticBody3D.new()
				body.name = "PropBody_%d_%d" % [key.x, key.y]
				body.collision_layer = LAYER_PROPS
				body.collision_mask = 0
				body.set_meta(&"surface", &"dirt")
				props_root.add_child(body)
				bodies[key] = body
			shapes += _add_prop_shapes(body, col, e)
	stats["instances"] = total
	stats["prop_shapes"] = shapes
	stats["smashables"] = smashables
	stats["soft_uprights"] = uprights


func _add_prop_shapes(body: StaticBody3D, col: Dictionary, e: Array) -> int:
	var sc: float = e[4]
	var xf := Transform3D(Basis(Vector3.UP, e[3]), Vector3(e[0], e[1], e[2]))
	var owner_id := body.create_shape_owner(body)
	var n := 0
	if col["type"] == "cylinder":
		var shape := CylinderShape3D.new()
		shape.radius = maxf(0.05, float(col["radius"]) * sc)
		shape.height = maxf(0.1, float(col["height"]) * sc)
		var offsets: Array = col.get("offsets", [[0.0, 0.0, 0.0]])
		for o in offsets:
			var local := Transform3D(Basis(), Vector3(o[0], o[1], o[2]) * sc + Vector3(0, shape.height * 0.5, 0))
			var sub := body.create_shape_owner(body)
			body.shape_owner_add_shape(sub, shape)
			body.shape_owner_set_transform(sub, xf * local)
			n += 1
		body.remove_shape_owner(owner_id)
	elif col["type"] == "box":
		var shape := BoxShape3D.new()
		var sz: Array = col["size"]
		shape.size = Vector3(sz[0], sz[1], sz[2]) * sc
		var c: Array = col.get("center", [0.0, sz[1] * 0.5, 0.0])
		body.shape_owner_add_shape(owner_id, shape)
		body.shape_owner_set_transform(owner_id, xf * Transform3D(Basis(), Vector3(c[0], c[1], c[2]) * sc))
		n += 1
	return n


# ------------------------------------------------------------------ barriers and checkpoints

func _build_barriers() -> void:
	var boxes: Array = info.get("collision_boxes", [])
	if boxes.is_empty():
		return
	var body := StaticBody3D.new()
	body.name = "Barriers"
	body.collision_layer = LAYER_PROPS
	body.collision_mask = 0
	body.set_meta(&"surface", &"tarmac")
	add_child(body)
	for b in boxes:
		var shape := BoxShape3D.new()
		shape.size = Vector3(b[3], b[4], b[5])
		var owner_id := body.create_shape_owner(body)
		body.shape_owner_add_shape(owner_id, shape)
		body.shape_owner_set_transform(owner_id, Transform3D(Basis(Vector3.UP, b[6]), Vector3(b[0], b[1], b[2])))


func _build_checkpoints() -> void:
	checkpoints.clear()
	for c in info.get("checkpoints", []):
		checkpoints.append({
			"index": int(c["index"]),
			"progress": float(c["s"]),
			"position": Vector3(c["pos"][0], c["pos"][1], c["pos"][2]),
			"yaw": float(c["yaw"]),
			"half_width": float(c["half_width"]),
		})


# ------------------------------------------------------------------ signs and parked cars

## Painted text on the sign boards the compiler built into the dressing mesh: one
## Label3D per line, fixed to the board face (no billboard), depth-tested, ink outline.
func _build_signs() -> void:
	var signs: Array = info.get("signs", [])
	if signs.is_empty():
		return
	var root := Node3D.new()
	root.name = "Signs"
	add_child(root)
	var local_meshes := {}
	for d in info["meshes"]:
		if d.get("local", false):
			local_meshes[d["name"]] = d
	for i in signs.size():
		var s: Dictionary = signs[i]
		var face := Transform3D(Basis(Vector3.UP, s["yaw"]), Vector3(s["pos"][0], s["pos"][1], s["pos"][2]))
		var holder: Node3D = root
		if local_meshes.has(s.get("mesh", "")) and s.has("base") and s.has("collider"):
			# its own mesh and a soft collider: the sign breaks like the kit's dressing
			holder = Node3D.new()
			holder.name = "Sign_%d" % i
			root.add_child(holder)
			var xf := Transform3D(Basis(Vector3.UP, s["yaw"]), Vector3(s["base"][0], s["base"][1], s["base"][2]))
			var col: Dictionary = s["collider"]
			var size := Vector3(col["size"][0], col["size"][1], col["size"][2])
			var arr := _mesh_arrays(local_meshes[s["mesh"]])
			var mat: Material = materials["props_vc"]
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			mesh.surface_set_material(0, mat)
			var mi := MeshInstance3D.new()
			mi.name = "Mesh"
			mi.mesh = mesh
			mi.transform = xf
			holder.add_child(mi)
			soft_course.add_sign(holder, _sign_pieces(arr, size.y, mat), xf, size,
					Vector3(col["center"][0], col["center"][1], col["center"][2]))
		for ln in s["lines"]:
			var l := Label3D.new()
			l.text = ln["text"]
			l.font = FONT_JP if ln["font"] == "jp" else FONT_LATIN
			l.font_size = 96
			l.outline_size = 14
			l.pixel_size = float(ln["size"]) / 96.0
			l.modulate = Color(ln["color"])
			l.outline_modulate = INK
			l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
			l.double_sided = false
			l.no_depth_test = false
			l.shaded = true
			l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
			l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			l.visibility_range_end = 260.0
			l.transform = face * Transform3D(Basis(), Vector3(ln["offset"][0], ln["offset"][1], 0.004))
			holder.add_child(l)


## A sign's debris: the posts (triangles reaching down towards the ground) and the board.
func _sign_pieces(arr: Array, top: float, mat: Material) -> Array[Mesh]:
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var cut := top * SIGN_POST_SHARE
	var posts := PackedInt32Array()
	var board := PackedInt32Array()
	for t in range(0, idx.size(), 3):
		var y := minf(verts[idx[t]].y, minf(verts[idx[t + 1]].y, verts[idx[t + 2]].y))
		if y < cut:
			posts.append_array(idx.slice(t, t + 3))
		else:
			board.append_array(idx.slice(t, t + 3))
	var out: Array[Mesh] = []
	for part in [posts, board]:
		if part.is_empty():
			continue
		# compact: the piece's bounds (its debris box) cover only its own vertices
		var remap := {}
		var sub := []
		sub.resize(Mesh.ARRAY_MAX)
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var c := PackedColorArray()
		var ni := PackedInt32Array()
		for k in part:
			if not remap.has(k):
				remap[k] = v.size()
				v.append(verts[k])
				if arr[Mesh.ARRAY_NORMAL] != null:
					n.append(arr[Mesh.ARRAY_NORMAL][k])
				if arr[Mesh.ARRAY_COLOR] != null:
					c.append(arr[Mesh.ARRAY_COLOR][k])
			ni.append(remap[k])
		sub[Mesh.ARRAY_VERTEX] = v
		sub[Mesh.ARRAY_INDEX] = ni
		if not n.is_empty():
			sub[Mesh.ARRAY_NORMAL] = n
		if not c.is_empty():
			sub[Mesh.ARRAY_COLOR] = c
		var m := ArrayMesh.new()
		m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sub)
		m.surface_set_material(0, mat)
		out.append(m)
	return out


## Parked rally cars (service parks): static car models in a livery each, toon-converted
## like the player's car, without physics.
func _build_parked() -> void:
	var cars: Array = info.get("parked", [])
	if cars.is_empty():
		return
	var root := Node3D.new()
	root.name = "ParkedCars"
	add_child(root)
	var scenes := {}
	for c in cars:
		var path: String = PARKED_MODELS.get(c["car"], "")
		if path.is_empty() or not ResourceLoader.exists(path):
			push_warning("MapWorld: no model for parked car '%s'" % c["car"])
			continue
		if not scenes.has(path):
			scenes[path] = load(path)
		var model: Node3D = (scenes[path] as PackedScene).instantiate()
		var livery: Dictionary = GameScript.CAR_COLORS[clampi(int(c["livery"]), 0, GameScript.CAR_COLORS.size() - 1)]
		_dress_parked(model, livery["primary"], livery["secondary"])
		model.transform = Transform3D(Basis(Vector3.UP, c["yaw"]), Vector3(c["pos"][0], c["pos"][1], c["pos"][2]))
		root.add_child(model)


## Same cel conversion as the player's car (CarLook), with the livery baked into the paint.
func _dress_parked(model: Node, primary: Color, secondary: Color) -> void:
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		mi.visibility_range_end = CATEGORY_VIEW["vehicle"][0]
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s)
			if src == null or src is ShaderMaterial:
				continue
			var base := src as BaseMaterial3D
			var n := src.resource_name.to_lower()
			var color := base.albedo_color if base else Color.WHITE
			if n.contains("paint2"):
				color = secondary
			elif n.contains("paint"):
				color = primary
			var mat: Material = ToonMaterials.make(color, CarLook._opts(n, base))
			for key in CarLook.OUTLINED:
				if n.contains(key):
					mat = ToonMaterials.with_outline(mat, 1.5 if key != "rubber" else 1.3)
					break
			mi.set_surface_override_material(s, mat)


# ------------------------------------------------------------------ queries

## Ground height (terrain or road collider) under x, z via a physics ray.
func ground_height(x: float, z: float, from_y: float = 800.0) -> float:
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, from_y, z), Vector3(x, -200.0, z), LAYER_WORLD)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit["position"].y if hit else 0.0
