class_name RoadGate
extends Node3D
## A closed road (通行止め) across a branch: two striped barricade wings hinged at the road
## edges, a white board with the closed-road notice, amber lamps and a marshal beside it.
## Closed, the wings are rigid (AnimatableBody3D on the props layer): a car driven into them
## stops. `set_open(true)` swings them back along the verges (their colliders follow, so they
## become a short rail at the road edge) and the marshal steps off; `opened` fires when the
## road is clear.
##
## Frame: the origin is the road centre on the ground, -Z points along the route through the
## gate (the way a car drives through once it is open), +X is the route's right.

signal opened

const LAYER_PROPS := 4
## Wing rails: heights of the two striped boards (m), board height and depth.
const RAIL_Y := [0.42, 0.92]
const RAIL_H := 0.26
const RAIL_D := 0.07
const STRIPE := 0.5
const RED := Color("d8333a")
const WHITE := Color("f4f1ea")
const POST := Color("3a3542")
const AMBER := Color("ffb42e")
## Gap between the carriageway edge and a wing's hinge post (m).
const HINGE_OUT := 0.6
const SWING_TIME := 1.8
const MARSHAL_STEP := 1.8
const VIEW_RANGE := 600.0
const FONT_LATIN := preload("res://assets/fonts/DelaGothicOne-Regular.ttf")
const FONT_JP := preload("res://assets/fonts/YujiSyuku-Regular.ttf")
const INK := Color("2a2235")

var id: String = ""
var route: String = ""
var width: float = 7.0
var is_open: bool = false
## The wings' hinge frames (left, right) and the bodies swinging about them.
var wings: Array[AnimatableBody3D] = []
var marshal: Node3D
var _marshal_closed: Vector3
var _tween: Tween


## Builds the gate. `material` is a vertex-colour toon material (MapWorld's props_vc);
## `marshal_mesh` the person standing by it (null: nobody).
func setup(gate_id: String, route_id: String, xf: Transform3D, road_width: float,
		material: Material, marshal_mesh: Mesh) -> void:
	id = gate_id
	route = route_id
	width = road_width
	name = "RoadGate_%s" % gate_id
	transform = xf
	var hinge_x := width * 0.5 + HINGE_OUT
	# each wing reaches from its hinge past the centre line, so the two overlap in the middle
	var length := hinge_x + 0.25
	for side in [-1, 1]:
		var body := AnimatableBody3D.new()
		body.name = "Wing_%s" % ("L" if side < 0 else "R")
		body.sync_to_physics = true
		body.collision_layer = LAYER_PROPS
		body.collision_mask = 0
		body.set_meta(&"surface", &"tarmac")
		body.position = Vector3(side * hinge_x, 0.0, 0.0)
		add_child(body)
		var mi := MeshInstance3D.new()
		mi.name = "Mesh"
		mi.mesh = _wing_mesh(side, length, material, side < 0)
		mi.visibility_range_end = VIEW_RANGE
		body.add_child(mi)
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		# deeper than the boards, so a fast car cannot slip through between two ticks
		box.size = Vector3(length, 1.3, 0.6)
		cs.shape = box
		cs.position = Vector3(-side * length * 0.5, 0.65, 0.0)
		body.add_child(cs)
		wings.append(body)
		if side < 0:
			_add_notice(body, length)
	if marshal_mesh != null:
		marshal = MeshInstance3D.new()
		marshal.name = "Marshal"
		(marshal as MeshInstance3D).mesh = marshal_mesh
		(marshal as MeshInstance3D).visibility_range_end = VIEW_RANGE * 0.5
		# beside the right hinge on the approach side, facing the traffic coming up the road
		_marshal_closed = Vector3(hinge_x + 0.9, 0.0, 1.2)
		marshal.position = _marshal_closed
		marshal.rotation.y = PI
		add_child(marshal)


## Opens or closes the road. Animated: the wings swing over SWING_TIME, `opened` fires at the end.
func set_open(open: bool, animate := true) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	is_open = open
	var angle := PI * 0.5 if open else 0.0
	var m_to := _marshal_closed + (Vector3(MARSHAL_STEP, 0.0, -0.8) if open else Vector3.ZERO)
	if not animate or not is_inside_tree():
		for i in wings.size():
			wings[i].rotation.y = _wing_angle(i, angle)
		if marshal != null:
			marshal.position = m_to
			marshal.rotation.y = PI * 0.5 if open else PI
		if open:
			opened.emit()
		return
	_tween = create_tween().set_process_mode(Tween.TWEEN_PROCESS_PHYSICS)
	_tween.set_parallel(true)
	for i in wings.size():
		_tween.tween_property(wings[i], "rotation:y", _wing_angle(i, angle), SWING_TIME) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT).set_delay(0.15 * i)
	if marshal != null:
		_tween.tween_property(marshal, "position", m_to, SWING_TIME * 0.8) \
				.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_tween.tween_property(marshal, "rotation:y", PI * 0.5 if open else PI, SWING_TIME * 0.4)
	_tween.set_parallel(false)
	if open:
		_tween.tween_callback(opened.emit)


## Swing of wing `i` (0 left, 1 right) for an opening angle: both fold forward along the road.
func _wing_angle(i: int, angle: float) -> float:
	return angle if i == 0 else -angle


# ------------------------------------------------------------------ geometry

## One wing in its hinge frame: a post at the hinge, two striped boards running towards the
## road centre (-side * x), a foot at the free end and an amber lamp on the hinge post.
func _wing_mesh(side: int, length: float, material: Material, lamp_on_end: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dir := -float(side)
	# posts and feet: at the hinge and at the free end
	for x in [0.0, length - 0.1]:
		_box(st, Vector3(dir * x, 0.6, 0.0), Vector3(0.1, 1.2, 0.1), POST)
		_box(st, Vector3(dir * x, 0.04, 0.0), Vector3(0.14, 0.08, 0.7), POST)
	# striped boards, stripes counted from the hinge
	var n := int(ceil(length / STRIPE))
	for y: float in RAIL_Y:
		for k in n:
			var x0 := k * STRIPE
			var x1 := minf((k + 1) * STRIPE, length)
			_box(st, Vector3(dir * (x0 + x1) * 0.5, y, 0.06), Vector3(x1 - x0, RAIL_H, RAIL_D),
					RED if k % 2 == 0 else WHITE)
	# amber lamp on top of a post
	var lx := dir * (length - 0.1) if lamp_on_end else 0.0
	_box(st, Vector3(lx, 1.3, 0.0), Vector3(0.18, 0.2, 0.18), AMBER)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, material)
	return mesh


## An axis-aligned box of flat-shaded faces in one vertex colour.
func _box(st: SurfaceTool, c: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1)],
		[Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, -1)],
		[Vector3(0, 1, 0), Vector3(0, 0, 1), Vector3(1, 0, 0)],
		[Vector3(0, -1, 0), Vector3(0, 0, -1), Vector3(1, 0, 0)],
		[Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0)],
		[Vector3(0, 0, -1), Vector3(-1, 0, 0), Vector3(0, 1, 0)],
	]
	for f in faces:
		var n: Vector3 = f[0]
		var u: Vector3 = f[1]
		var v: Vector3 = f[2]
		var o := c + n * h
		var du := u * h
		var dv := v * h
		var quad := [o - du - dv, o + du - dv, o + du + dv, o - du + dv]
		# u x v = n: the quad runs counter-clockwise seen from outside; Godot's front faces are
		# clockwise, so walk it backwards
		for k in [0, 2, 1, 0, 3, 2]:
			st.set_color(color)
			st.add_vertex(quad[k])


## The closed-road board on the left wing, facing the approaching traffic (+Z): white with a
## red border, 通行止め in red brush letters over ROAD CLOSED.
func _add_notice(body: Node3D, length: float) -> void:
	var holder := Node3D.new()
	holder.name = "Notice"
	holder.position = Vector3(length * 0.55, 1.62, 0.1)
	body.add_child(holder)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0.0, 0.0, 0.0), Vector3(1.9, 1.0, 0.05), RED)
	_box(st, Vector3(0.0, 0.0, 0.015), Vector3(1.74, 0.84, 0.05), WHITE)
	_box(st, Vector3(-0.6, -0.72, -0.02), Vector3(0.07, 0.6, 0.07), POST)
	_box(st, Vector3(0.6, -0.72, -0.02), Vector3(0.07, 0.6, 0.07), POST)
	st.generate_normals()
	var mesh := st.commit()
	mesh.surface_set_material(0, (body.get_node("Mesh") as MeshInstance3D).mesh.surface_get_material(0))
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.visibility_range_end = VIEW_RANGE
	holder.add_child(mi)
	for line in [["通行止め", FONT_JP, 0.13, RED, 0.12], ["ROAD CLOSED", FONT_LATIN, 0.0, INK, 0.2]]:
		var l := Label3D.new()
		l.text = line[0]
		l.font = line[1]
		l.font_size = 128
		l.outline_size = 0 if line[3] == INK else 10
		l.outline_modulate = WHITE
		l.pixel_size = 0.0034 if line[3] == RED else 0.0016
		l.modulate = line[3]
		l.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		l.double_sided = false
		l.shaded = true
		l.alpha_cut = Label3D.ALPHA_CUT_OPAQUE_PREPASS
		l.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		l.visibility_range_end = VIEW_RANGE * 0.6
		l.position = Vector3(0.0, line[2] - (0.26 if line[3] == INK else 0.0), 0.045)
		holder.add_child(l)
