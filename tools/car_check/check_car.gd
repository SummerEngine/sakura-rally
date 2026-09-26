extends SceneTree
## Headless contract check for a car GLB (default assets/models/car/rally_car.glb).
## Run: $S --headless --disable-crash-handler --path . -s res://tools/car_check/check_car.gd
##      [-- res://assets/models/car/hayate.glb]
## Prints nodes, wheel origins in car space, body AABB, triangle counts and materials, then
## "CAR_CHECK PASS" or "CAR_CHECK FAIL: <reasons>" (compared against docs/CONTRACTS.md).
## Optional pop-up headlight nodes (PopUp_L / PopUp_R) must come as a pair with an identity
## rest rotation.

const DEFAULT_CAR := "res://assets/models/car/rally_car.glb"
const WHEEL_TOLERANCE := 0.01
const EXPECTED_WHEELS := {
	"Wheel_FL": Vector3(-0.78, 0.33, -1.27),
	"Wheel_FR": Vector3(0.78, 0.33, -1.27),
	"Wheel_RL": Vector3(-0.78, 0.33, 1.28),
	"Wheel_RR": Vector3(0.78, 0.33, 1.28),
}
const EXPECTED_MATERIALS: Array[String] = [
	"Paint", "Paint2", "Trim", "Chrome", "Glass", "Rubber", "Rim",
	"HeadLight", "TailLight", "Decal_White", "Number",
]
## Nominal body size per GLB file name (docs/CONTRACTS.md); anything else uses "rally_car".
const BODY_SIZES := {
	"rally_car": Vector3(1.80, 1.40, 4.20),
	"hayate": Vector3(1.70, 1.25, 4.15),
}
const BODY_SIZE_TOLERANCE := Vector3(0.25, 0.25, 0.25)
const BODY_TRI_BUDGET := 14000
const WHEEL_TRI_RANGE := Vector2i(1000, 1600)


func _initialize() -> void:
	var failures: PackedStringArray = []
	var args := OS.get_cmdline_user_args()
	var car_path: String = args[0] if not args.is_empty() else DEFAULT_CAR
	var body_size: Vector3 = BODY_SIZES.get(car_path.get_file().get_basename(), BODY_SIZES["rally_car"])
	print("CAR ", car_path)
	var packed := load(car_path) as PackedScene
	if packed == null:
		print("CAR_CHECK FAIL: cannot load ", car_path)
		quit(1)
		return
	var car: Node3D = packed.instantiate() as Node3D
	root.add_child(car)

	print("NODES")
	_print_tree(car, car, 1)

	var materials: Dictionary = {}
	var total_tris := 0
	var body_tris := 0
	print("MESHES")
	for mi: MeshInstance3D in _meshes(car):
		var tris := _triangles(mi.mesh)
		total_tris += tris
		var names: PackedStringArray = []
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			var mname := mat.resource_name if mat != null else "<none>"
			names.append(mname)
			materials[mname] = true
		var top := _owner_name(car, mi)
		var label := top if String(mi.name) == top else "%s/%s" % [top, mi.name]
		print("  %-14s tris=%6d materials=%s" % [label, tris, ", ".join(names)])
		if top == "Body":
			body_tris += tris
		if top.begins_with("Wheel_") and (tris < WHEEL_TRI_RANGE.x or tris > WHEEL_TRI_RANGE.y):
			failures.append("%s has %d tris (outside %s)" % [top, tris, WHEEL_TRI_RANGE])
	print("TOTAL_TRIS ", total_tris)
	if body_tris > BODY_TRI_BUDGET:
		failures.append("Body has %d tris (> %d)" % [body_tris, BODY_TRI_BUDGET])

	print("WHEELS (car space, Godot axes)")
	for wheel_name: String in EXPECTED_WHEELS:
		var node := car.find_child(wheel_name, true, false) as Node3D
		if node == null:
			failures.append("missing node " + wheel_name)
			continue
		var origin: Vector3 = _car_xform(car, node).origin
		var want: Vector3 = EXPECTED_WHEELS[wheel_name]
		var err := origin.distance_to(want)
		print("  %s origin=%s expected=%s error=%.4f m" % [wheel_name, origin, want, err])
		if err > WHEEL_TOLERANCE:
			failures.append("%s origin off by %.3f m" % [wheel_name, err])
		var wheel_aabb := _aabb(car, node)
		print("    aabb size=%s centre=%s" % [wheel_aabb.size, wheel_aabb.get_center()])
		if absf(wheel_aabb.size.y * 0.5 - 0.33) > 0.01 or absf(wheel_aabb.size.x - 0.24) > 0.02:
			failures.append("%s radius/width off: %s" % [wheel_name, wheel_aabb.size])
	for caliper_name in ["Caliper_FL", "Caliper_FR", "Caliper_RL", "Caliper_RR"]:
		var c := car.find_child(caliper_name, true, false) as Node3D
		if c != null:
			print("  %s origin=%s" % [caliper_name, _car_xform(car, c).origin])
	var popups := 0
	for popup_name in ["PopUp_L", "PopUp_R"]:
		var p := car.find_child(popup_name, true, false) as Node3D
		if p == null:
			continue
		popups += 1
		var xf := _car_xform(car, p)
		print("  %s hinge=%s parent=%s" % [popup_name, xf.origin, p.get_parent().name])
		if not xf.basis.is_equal_approx(Basis.IDENTITY):
			failures.append("%s rest basis is not identity" % popup_name)
		if (popup_name == "PopUp_L") != (xf.origin.x < 0.0):
			failures.append("%s is on the wrong side" % popup_name)
	if popups == 1:
		failures.append("only one of PopUp_L / PopUp_R present")

	var body := car.find_child("Body", true, false) as Node3D
	if body == null:
		failures.append("missing node Body")
	else:
		var box := _aabb(car, body)
		print("BODY_AABB position=%s size=%s end=%s" % [box.position, box.size, box.end])
		var d := (box.size - body_size).abs()
		if d.x > BODY_SIZE_TOLERANCE.x or d.y > BODY_SIZE_TOLERANCE.y or d.z > BODY_SIZE_TOLERANCE.z:
			failures.append("Body AABB size %s far from %s" % [box.size, body_size])
	var full := _aabb(car, car)
	print("CAR_AABB position=%s size=%s" % [full.position, full.size])
	if absf(full.position.y) > 0.005:
		failures.append("car does not sit on y=0 (min y %.4f)" % full.position.y)

	var mat_names: Array = materials.keys()
	mat_names.sort()
	print("MATERIALS ", ", ".join(PackedStringArray(mat_names)))
	for m in EXPECTED_MATERIALS:
		if not materials.has(m):
			failures.append("missing material " + m)

	if failures.is_empty():
		print("CAR_CHECK PASS")
	else:
		print("CAR_CHECK FAIL: ", "; ".join(failures))
	car.queue_free()
	quit(0 if failures.is_empty() else 1)


func _print_tree(base: Node, node: Node, depth: int) -> void:
	var extra := ""
	if node is Node3D and node != base:
		extra = " pos=%s" % [(node as Node3D).position]
	print("  ".repeat(depth), node.name, " (", node.get_class(), ")", extra)
	for child in node.get_children():
		_print_tree(base, child, depth + 1)


func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		out.append_array(_meshes(child))
	return out


func _owner_name(car: Node, mi: Node) -> String:
	var n := mi
	while n.get_parent() != car and n.get_parent() != null:
		n = n.get_parent()
	return String(n.name)


func _triangles(mesh: Mesh) -> int:
	var tris := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			tris += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
		else:
			tris += indices.size() / 3
	return tris


func _aabb(car: Node3D, node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for mi: MeshInstance3D in _meshes(node):
		var box: AABB = _car_xform(car, mi) * mi.mesh.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result


## Transform of `node` relative to `car`, composed from local transforms (the -s script runs
## before the scene tree is live, so global transforms are unavailable).
func _car_xform(car: Node3D, node: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != car:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf
