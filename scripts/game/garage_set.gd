class_name GarageSet
extends Node3D
## The Sakura Rally service workshop by the Hanami start straight: MapWorld adds it when the pack
## has a "garage" entry (tools/mapgen/lib/garage.py), so it stands in the world for the menu and
## for every drive past it. Sits at MapWorld.garage, the display spot on the paved lay-by, in the
## garage frame: -Z along the road (the car's heading), +X toward the road.
##
## Builds the workshop (assets/models/props/garage_*.glb, cel-converted), its warm lamps and
## chochin glow, service banners and tyre piles along the lay-by, and rigid colliders for the
## walls, posts and furniture (layer 3, like the map's rigid props) plus the floor slab (layer 1).
## For MenuStage it answers where the menu car stands (`display`), the road the cars drive off
## along (`leave_path`) and the way a new car arrives and parks (`arrive_start`, `arrive_path`).

const WORKSHOP := preload("res://assets/models/props/garage_workshop.glb")
const NOBORI := preload("res://assets/models/props/garage_nobori.glb")
const TYRES := preload("res://assets/models/props/garage_tyres.glb")

## Workshop footprint in its own frame (tools/blender/props/garage.py: W, D, H, SLAB, POSTS_X;
## Godot axes: the open front faces -Z).
const WORKSHOP_W := 14.0
const WORKSHOP_D := 8.0
const WORKSHOP_H := 4.0
const WORKSHOP_SLAB := 0.08
const WORKSHOP_POSTS_X: Array[float] = [-7.0, -2.3333, 2.3333, 7.0]
## Rigid furniture inside the workshop, own frame: [centre, size] boxes (workbench, roll cab,
## compressor, tyre rack, tyre stacks and drums).
const WORKSHOP_FURNITURE := [
	[Vector3(-4.4, 0.5, 3.35), Vector3(4.2, 1.0, 0.9)],
	[Vector3(-1.3, 0.6, 3.45), Vector3(1.0, 1.2, 0.6)],
	[Vector3(0.9, 0.4, 3.3), Vector3(1.1, 0.8, 0.6)],
	[Vector3(4.6, 1.1, 3.45), Vector3(3.3, 2.2, 0.8)],
	[Vector3(5.65, 0.5, -0.9), Vector3(1.9, 1.0, 4.2)],
]
## Warm lamp light: colour, energy, range; chochin glow the same for the eave lanterns.
const LAMP_COLOR := Color("ffc987")
const LAMP_ENERGY := 2.4
const LAMP_RANGE := 8.5
const LANTERN_COLOR := Color("ff9a6a")
const LANTERN_ENERGY := 0.7
const LANTERN_RANGE := 3.2
## Lights fade out beyond this distance from the camera (a drive past at race speed).
const LIGHT_FADE := 70.0
## Service banners and tyre piles along the lay-by's back edge (garage frame, yaw in degrees).
const NOBORI_AT := [Vector3(-6.4, 0.0, 9.0), Vector3(-6.4, 0.0, -9.0), Vector3(-6.2, 0.0, 14.5),
		Vector3(-6.2, 0.0, -14.5)]
const TYRES_AT := [[Vector3(-5.8, 0.0, 11.6), 25.0], [Vector3(-6.0, 0.0, -11.8), -40.0]]

## Left-hand traffic: the lane the cars drive in, metres left of the road centreline.
const LANE := -1.75
## Arriving cars start this far back along the road from the display spot (out of the shot).
const ARRIVE_BACK := 52.0
## Leaving cars follow the road this far past the lay-by before they are gone.
const LEAVE_ROAD := 150.0

var map: MapWorld
## The display spot (the menu car's pose on the lay-by, heading along the road).
var display := Transform3D.IDENTITY
## Garage-frame x of the road centreline (the lay-by is on the -X side of it).
var road_x := 11.0
var workshop: Node3D
var lights: Array[Light3D] = []


func setup(p_map: MapWorld, info: Dictionary) -> GarageSet:
	map = p_map
	name = "GarageSet"
	display = Transform3D(Basis(Vector3.UP, float(info["yaw"])),
			Vector3(info["pos"][0], info["pos"][1], info["pos"][2]))
	transform = display
	var shop: Array = info.get("workshop", [-11.0, 0.0])
	road_x = _road_x(info)
	_build_workshop(Vector3(float(shop[0]), 0.0, float(shop[1])))
	for p: Vector3 in NOBORI_AT:
		_prop(NOBORI, p, -PI * 0.5, 0.06)
	for t: Array in TYRES_AT:
		_prop(TYRES, t[0], deg_to_rad(t[1]), 0.75)
	return self


## Garage-frame x of the road centreline, from the lay-by rectangle (its road-side edge is 3 m
## short of the centreline, garage.py) or the default layout.
func _road_x(info: Dictionary) -> float:
	var lot: Array = info.get("lot", [])
	if lot.size() >= 3:
		return float(lot[0]) + float(lot[2]) + 3.0
	return 11.0


# ---------------------------------------------------------------- building

func _build_workshop(at: Vector3) -> void:
	workshop = WORKSHOP.instantiate() as Node3D
	workshop.name = "Workshop"
	# Own front (-Z) toward the road (+X).
	workshop.transform = Transform3D(Basis(Vector3.UP, -PI * 0.5), at + Vector3.DOWN * 0.02)
	add_child(workshop)
	ToonMaterials.convert_tree(workshop)
	_cast_shadows(workshop)
	for n in workshop.find_children("Lamp_*", "", true, false):
		_light(n as Node3D, LAMP_COLOR, LAMP_ENERGY, LAMP_RANGE)
	for n in workshop.find_children("Lantern_*", "", true, false):
		_light(n as Node3D, LANTERN_COLOR, LANTERN_ENERGY, LANTERN_RANGE)
	var walls := _body("WorkshopWalls", MapWorld.LAYER_PROPS, workshop)
	var hw := WORKSHOP_W * 0.5
	var hd := WORKSHOP_D * 0.5
	_box(walls, Vector3(0.0, WORKSHOP_H * 0.5, hd - 0.12), Vector3(WORKSHOP_W, WORKSHOP_H, 0.3))
	for sx: float in [-1.0, 1.0]:
		_box(walls, Vector3(sx * (hw - 0.08), WORKSHOP_H * 0.5, 0.0), Vector3(0.24, WORKSHOP_H, WORKSHOP_D))
	for x: float in WORKSHOP_POSTS_X:
		_box(walls, Vector3(x, WORKSHOP_H * 0.5, -(hd - 0.14)), Vector3(0.4, WORKSHOP_H, 0.4))
	for f: Array in WORKSHOP_FURNITURE:
		_box(walls, f[0], f[1])
	var floor_body := _body("WorkshopFloor", MapWorld.LAYER_WORLD, workshop)
	floor_body.set_meta("surface", &"tarmac")
	_box(floor_body, Vector3(0.0, WORKSHOP_SLAB * 0.5 - 0.1, -0.1),
			Vector3(WORKSHOP_W + 0.5, WORKSHOP_SLAB + 0.2, WORKSHOP_D + 0.4))


func _prop(scene: PackedScene, at: Vector3, yaw: float, radius: float) -> void:
	var n := scene.instantiate() as Node3D
	n.transform = Transform3D(Basis(Vector3.UP, yaw), at)
	add_child(n)
	ToonMaterials.convert_tree(n)
	_cast_shadows(n)
	var body := _body("Body", MapWorld.LAYER_PROPS, n)
	var shape := CollisionShape3D.new()
	var c := CylinderShape3D.new()
	c.radius = radius
	c.height = 1.6
	shape.shape = c
	shape.position = Vector3(0.0, 0.8, 0.0)
	body.add_child(shape)


func _light(at: Node3D, color: Color, energy: float, reach: float) -> void:
	var l := OmniLight3D.new()
	l.light_color = color
	l.light_energy = energy
	l.omni_range = reach
	l.omni_attenuation = 1.1
	l.shadow_enabled = false
	l.distance_fade_enabled = true
	l.distance_fade_begin = LIGHT_FADE
	l.distance_fade_length = 15.0
	at.add_child(l)
	lights.append(l)


func _body(n: String, layer: int, parent: Node3D) -> StaticBody3D:
	var b := StaticBody3D.new()
	b.name = n
	b.collision_layer = layer
	b.collision_mask = 0
	parent.add_child(b)
	return b


func _box(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var s := CollisionShape3D.new()
	var b := BoxShape3D.new()
	b.size = size
	s.shape = b
	s.position = center
	body.add_child(s)


func _cast_shadows(root: Node) -> void:
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		mi.visibility_range_end = MapWorld.CATEGORY_VIEW["building"][0]


# ---------------------------------------------------------------- paths (world space)

## Garage-frame point to world.
func at(x: float, z: float) -> Vector3:
	return display * Vector3(x, 0.0, z)


## Road distance (Track abs s) of the display spot.
func display_s() -> float:
	var t := map.track
	return t.abs_s(t.nearest(display.origin), display.origin)


## The way a car on the lay-by leaves: forward out of the lay-by's far end, into the left lane
## and along the road until it is well out of the shot. Starts at `from` (the car's position).
func leave_path(from: Vector3) -> PackedVector3Array:
	var pts := PackedVector3Array([from])
	var lane := road_x + LANE
	for p: Vector2 in [Vector2(0.0, -6.0), Vector2(1.2, -11.0), Vector2(lane * 0.55, -16.5),
			Vector2(lane - 0.6, -22.0)]:
		var w := at(p.x, p.y)
		# A car that is past a point already (a re-routed arrival) skips it.
		if (w - from).dot(-display.basis.z) > 0.5:
			pts.append(w)
	var s0 := display_s() + 27.0
	var d := 0.0
	while d <= LEAVE_ROAD:
		pts.append(map.track.position_at_abs(s0 + d, LANE))
		d += 6.0
	return pts


## Where an arriving car starts: in the left lane, ARRIVE_BACK metres before the display spot.
func arrive_start() -> Transform3D:
	var s := display_s() - ARRIVE_BACK
	return map.track.transform_at_abs(s, LANE, 0.3)


## The arriving car's line: along the lane, into the lay-by's near end and onto the display
## spot, square to its heading for the last metres so it stops straight.
func arrive_path() -> PackedVector3Array:
	var pts := PackedVector3Array()
	var s := display_s()
	var d := -ARRIVE_BACK
	while d < -30.0:
		pts.append(map.track.position_at_abs(s + d, LANE))
		d += 6.0
	var lane := road_x + LANE
	# Turns in at the lay-by's near end (its paving joins the carriageway there), square to the
	# spot from 6 m out.
	for p: Vector2 in [Vector2(lane - 0.3, 26.0), Vector2(lane - 1.3, 19.0), Vector2(4.0, 14.5),
			Vector2(0.8, 10.0), Vector2(0.0, 6.0), Vector2(0.0, 0.0)]:
		pts.append(at(p.x, p.y))
	return pts
