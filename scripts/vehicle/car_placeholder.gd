class_name CarPlaceholder
extends RefCounted
## Code-built low-poly rally hatchback used until `assets/models/car/rally_car.glb` exists.
## Same node and material names as the real model (docs/CONTRACTS.md), faceted flat shading.

## Loft sections: z, y_bottom, y_belt, y_top, half-width bottom, belt, top.
const SECTIONS: Array[PackedFloat32Array] = [
	[-2.10, 0.36, 0.62, 0.68, 0.78, 0.82, 0.70],
	[-1.88, 0.25, 0.76, 0.82, 0.86, 0.89, 0.80],
	[-0.72, 0.23, 0.86, 0.97, 0.88, 0.90, 0.80],
	[-0.20, 0.23, 0.90, 1.37, 0.88, 0.90, 0.64],
	[1.18, 0.23, 0.92, 1.39, 0.88, 0.90, 0.64],
	[1.98, 0.29, 0.88, 1.02, 0.86, 0.88, 0.74],
	[2.10, 0.38, 0.80, 0.88, 0.82, 0.84, 0.72],
]
const WHEELS: Array[Vector3] = [
	Vector3(-0.78, 0.33, -1.27), Vector3(0.78, 0.33, -1.27), Vector3(-0.78, 0.33, 1.28), Vector3(0.78, 0.33, 1.28),
]
const WHEEL_NAMES: Array[String] = ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
const CALIPER_NAMES: Array[String] = ["Caliper_FL", "Caliper_FR", "Caliper_RL", "Caliper_RR"]


static func build() -> Node3D:
	var mats := {
		"Paint": _mat("Paint", Color("f6f1e8")),
		"Paint2": _mat("Paint2", Color("e8517c")),
		"Trim": _mat("Trim", Color("2b2a33")),
		"Glass": _mat("Glass", Color("3a4660")),
		"Rubber": _mat("Rubber", Color("26242b")),
		"Rim": _mat("Rim", Color("d9d4cc")),
		"Chrome": _mat("Chrome", Color("b9bcc4")),
		"HeadLight": _mat("HeadLight", Color("fff4d6"), true),
		"TailLight": _mat("TailLight", Color("e8323a"), true),
		"Caliper": _mat("Trim", Color("d9402e")),
	}
	var root := Node3D.new()
	root.name = "Model"
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	var shell := MeshInstance3D.new()
	shell.name = "Shell"
	shell.mesh = _build_shell(mats)
	body.add_child(shell)
	_add_details(body, mats)
	for i in 4:
		root.add_child(_build_wheel(i, mats))
		root.add_child(_build_caliper(i, mats))
	return root


static func _mat(mat_name: String, colour: Color, emissive: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = mat_name
	m.albedo_color = colour
	m.roughness = 0.55
	if emissive:
		m.emission_enabled = true
		m.emission = colour
		m.emission_energy_multiplier = 1.5
	return m


static func _ring(sec: PackedFloat32Array) -> Array[Vector3]:
	var z := sec[0]
	return [
		Vector3(-sec[4], sec[1], z), Vector3(-sec[5], sec[2], z), Vector3(-sec[6], sec[3], z),
		Vector3(sec[6], sec[3], z), Vector3(sec[5], sec[2], z), Vector3(sec[4], sec[1], z),
	]


static func _build_shell(mats: Dictionary) -> ArrayMesh:
	var paint := SurfaceTool.new()
	var glass := SurfaceTool.new()
	var trim := SurfaceTool.new()
	var paint2 := SurfaceTool.new()
	var lights := SurfaceTool.new()
	var tails := SurfaceTool.new()
	for st in [paint, glass, trim, paint2, lights, tails]:
		(st as SurfaceTool).begin(Mesh.PRIMITIVE_TRIANGLES)
	var rings: Array = []
	for sec in SECTIONS:
		rings.append(_ring(sec))
	for s in SECTIONS.size() - 1:
		var a: Array[Vector3] = rings[s]
		var b: Array[Vector3] = rings[s + 1]
		for k in 6:
			var k1 := (k + 1) % 6
			var target := paint
			var is_side_upper := k == 1 or k == 3
			var is_top := k == 2
			if k == 5 or k == 0 or k == 4:
				target = paint if k != 5 else trim
			if is_side_upper and s >= 2 and s <= 4:
				target = glass
			if is_top and (s == 2 or s == 4):
				target = glass
			var centre := (a[k] + a[k1] + b[k] + b[k1]) * 0.25
			var outward := centre - Vector3(0.0, 0.62, centre.z)
			_quad(target, a[k], a[k1], b[k1], b[k], outward)
	# End caps.
	_cap(paint, rings[0], Vector3.FORWARD)
	_cap(paint, rings[rings.size() - 1], Vector3.BACK)
	# Livery stripe over hood and roof.
	for s: int in [1, 3]:
		var a: Array[Vector3] = rings[s]
		var b: Array[Vector3] = rings[s + 1]
		var lift := Vector3(0.0, 0.006, 0.0)
		for side: float in [-1.0, 1.0]:
			var off := 0.2 * side
			var inner := 0.07 * side
			var p0 := _lerp_top(a, off) + lift
			var p1 := _lerp_top(a, inner) + lift
			var p2 := _lerp_top(b, inner) + lift
			var p3 := _lerp_top(b, off) + lift
			_quad(paint2, p0, p1, p2, p3, Vector3.UP)
	# Headlights and tail lights on the end caps.
	for side: float in [-1.0, 1.0]:
		var x := 0.55 * side
		_quad(lights, Vector3(x - 0.17, 0.52, -2.115), Vector3(x + 0.17, 0.52, -2.115),
				Vector3(x + 0.15, 0.63, -2.115), Vector3(x - 0.15, 0.63, -2.115), Vector3.FORWARD)
		_quad(tails, Vector3(x - 0.14, 0.62, 2.115), Vector3(x + 0.14, 0.62, 2.115),
				Vector3(x + 0.14, 0.76, 2.115), Vector3(x - 0.14, 0.76, 2.115), Vector3.BACK)
	var mesh := ArrayMesh.new()
	var order := [[paint, "Paint"], [paint2, "Paint2"], [glass, "Glass"], [trim, "Trim"],
			[lights, "HeadLight"], [tails, "TailLight"]]
	for entry in order:
		var st: SurfaceTool = entry[0]
		st.commit(mesh)
		mesh.surface_set_material(mesh.get_surface_count() - 1, mats[entry[1]])
	return mesh


static func _lerp_top(ring: Array[Vector3], x: float) -> Vector3:
	var l := ring[2]
	var r := ring[3]
	return l.lerp(r, (x - l.x) / (r.x - l.x))


## Emits a flat-shaded quad whose front face points along `outward` (Godot front faces are clockwise).
static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, outward: Vector3) -> void:
	var n := (b - a).cross(c - a)
	if n.length_squared() < 1e-10:
		n = (c - a).cross(d - a)
	if n.dot(outward) > 0.0:
		var t := b
		b = d
		d = t
		n = -n
	var normal := -n.normalized()
	for p in [a, b, c, a, c, d]:
		st.set_normal(normal)
		st.add_vertex(p)


static func _cap(st: SurfaceTool, ring: Array[Vector3], outward: Vector3) -> void:
	var centre := Vector3.ZERO
	for p in ring:
		centre += p
	centre /= ring.size()
	for k in ring.size():
		var a := ring[k]
		var b := ring[(k + 1) % ring.size()]
		_quad(st, centre, a, b, centre, outward)


static func _box(parent: Node3D, node_name: String, size: Vector3, pos: Vector3, mat: Material,
		rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	var bm := BoxMesh.new()
	bm.size = size
	bm.material = mat
	mi.mesh = bm
	mi.position = pos
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _add_details(body: Node3D, mats: Dictionary) -> void:
	_box(body, "BumperFront", Vector3(1.66, 0.16, 0.14), Vector3(0.0, 0.34, -2.1), mats["Trim"])
	_box(body, "BumperRear", Vector3(1.66, 0.16, 0.14), Vector3(0.0, 0.38, 2.1), mats["Trim"])
	for i in 4:
		var w := WHEELS[i]
		var side := signf(w.x)
		_box(body, "Arch%d" % i, Vector3(0.1, 0.09, 0.92), Vector3(side * 0.9, 0.7, w.z), mats["Trim"])
		_box(body, "Flap%d" % i, Vector3(0.22, 0.2, 0.02), Vector3(w.x, 0.2, w.z + 0.42), mats["Trim"])
	# Rear wing on the hatch.
	for side: float in [-0.52, 0.52]:
		_box(body, "WingPost", Vector3(0.05, 0.14, 0.12), Vector3(side, 1.45, 1.16), mats["Trim"])
	_box(body, "Wing", Vector3(1.42, 0.04, 0.34), Vector3(0.0, 1.53, 1.2), mats["Paint2"], Vector3(0.08, 0.0, 0.0))
	# Roof scoop, mirrors, grille and a spot-light pod.
	_box(body, "Scoop", Vector3(0.36, 0.08, 0.3), Vector3(0.0, 1.41, -0.02), mats["Trim"])
	for side: float in [-1.0, 1.0]:
		_box(body, "Mirror", Vector3(0.14, 0.08, 0.1), Vector3(side * 0.96, 0.98, -0.62), mats["Paint"])
		_box(body, "Spot", Vector3(0.16, 0.16, 0.06), Vector3(side * 0.26, 0.55, -2.19), mats["HeadLight"])
	_box(body, "Grille", Vector3(0.7, 0.1, 0.02), Vector3(0.0, 0.5, -2.12), mats["Trim"])


static func _build_wheel(i: int, mats: Dictionary) -> Node3D:
	var node := Node3D.new()
	node.name = WHEEL_NAMES[i]
	node.position = WHEELS[i]
	var side := signf(WHEELS[i].x)
	var tyre := MeshInstance3D.new()
	tyre.name = "Tyre"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.33
	cm.bottom_radius = 0.33
	cm.height = 0.24
	cm.radial_segments = 14
	cm.rings = 1
	cm.material = mats["Rubber"]
	tyre.mesh = cm
	tyre.rotation = Vector3(0.0, 0.0, PI * 0.5)
	node.add_child(tyre)
	var rim := MeshInstance3D.new()
	rim.name = "Rim"
	var rm := CylinderMesh.new()
	rm.top_radius = 0.21
	rm.bottom_radius = 0.21
	rm.height = 0.02
	rm.radial_segments = 14
	rm.rings = 1
	rm.material = mats["Rim"]
	rim.mesh = rm
	rim.rotation = Vector3(0.0, 0.0, PI * 0.5)
	rim.position = Vector3(side * 0.12, 0.0, 0.0)
	node.add_child(rim)
	for s in 5:
		var angle := TAU * s / 5.0
		var spoke := _box(node, "Spoke%d" % s, Vector3(0.03, 0.2, 0.05),
				Vector3(side * 0.132, 0.0, 0.0), mats["Trim"], Vector3(angle, 0.0, 0.0))
		spoke.position += Basis(Vector3.RIGHT, angle) * Vector3(0.0, 0.1, 0.0)
	_box(node, "Hub", Vector3(0.04, 0.07, 0.07), Vector3(side * 0.135, 0.0, 0.0), mats["Chrome"])
	return node


static func _build_caliper(i: int, mats: Dictionary) -> Node3D:
	var node := Node3D.new()
	node.name = CALIPER_NAMES[i]
	var w := WHEELS[i]
	var side := signf(w.x)
	node.position = w + Vector3(-side * 0.15, 0.1, 0.13)
	_box(node, "Pad", Vector3(0.06, 0.12, 0.16), Vector3.ZERO, mats["Caliper"], Vector3(-0.6, 0.0, 0.0))
	return node
