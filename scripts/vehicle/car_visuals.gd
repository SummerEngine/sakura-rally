class_name CarVisuals
extends Node3D
## Drives the car's visual model from the physics wheel state: wheel spin, steering and suspension
## travel, calipers (steer only) and a subtle visual body lean. Uses the car scene's model
## (`model_path`, node names per docs/CONTRACTS.md) when present, otherwise builds a low-poly
## placeholder hatchback from code.
##
## Updated in _physics_process so physics interpolation smooths it together with the body.

const WHEEL_NAMES: Array[StringName] = [&"Wheel_FL", &"Wheel_FR", &"Wheel_RL", &"Wheel_RR"]
const CALIPER_NAMES: Array[StringName] = [&"Caliper_FL", &"Caliper_FR", &"Caliper_RL", &"Caliper_RR"]

## The car's GLB (per car scene: rally_car.glb for the Sakura, hayate.glb for the Hayate).
@export_file("*.glb") var model_path: String = "res://assets/models/car/rally_car.glb"
## Visual-only body lean per g of acceleration (degrees) and its limit.
@export var lean_per_g_deg: float = 1.1
@export var max_lean_deg: float = 1.6
@export var lean_smoothing: float = 10.0
## Visual-only high-frequency bounce on rough surfaces (metres at full roughness and speed).
@export var surface_jiggle: float = 0.006

var model: Node3D
var body: Node3D
var using_placeholder: bool = false

var _car: Car
var _wheel_nodes: Array[Node3D] = [null, null, null, null]
var _caliper_nodes: Array[Node3D] = [null, null, null, null]
## Rest transforms relative to this node, and each node's parent transform relative to this node.
var _wheel_rest: Array[Transform3D] = []
var _wheel_parent: Array[Transform3D] = []
var _caliper_rest: Array[Transform3D] = []
var _caliper_parent: Array[Transform3D] = []
var _body_rest: Transform3D
var _body_parent: Transform3D
var _prev_velocity: Vector3 = Vector3.ZERO
var _lean: Vector2 = Vector2.ZERO ## x = pitch, y = roll (radians)
var _livery_cache: Dictionary = {} ## original material -> per-instance duplicate
var _time: float = 0.0


func _ready() -> void:
	_car = get_parent() as Car
	if ResourceLoader.exists(model_path):
		var scene := load(model_path) as PackedScene
		if scene != null:
			model = scene.instantiate() as Node3D
	if model == null:
		model = CarPlaceholder.build()
		using_placeholder = true
	model.name = "Model"
	add_child(model)
	_bind_nodes()
	if _car != null:
		apply_livery(_car.livery_primary, _car.livery_secondary)


func _bind_nodes() -> void:
	_wheel_rest.clear()
	_wheel_parent.clear()
	_caliper_rest.clear()
	_caliper_parent.clear()
	for i in 4:
		var wn := model.find_child(String(WHEEL_NAMES[i]), true, false) as Node3D
		_wheel_nodes[i] = wn
		_wheel_rest.append(_relative(wn))
		_wheel_parent.append(_relative(wn.get_parent_node_3d()) if wn != null else Transform3D.IDENTITY)
		var cn := model.find_child(String(CALIPER_NAMES[i]), true, false) as Node3D
		_caliper_nodes[i] = cn
		_caliper_rest.append(_relative(cn))
		_caliper_parent.append(_relative(cn.get_parent_node_3d()) if cn != null else Transform3D.IDENTITY)
	body = model.find_child("Body", true, false) as Node3D
	_body_rest = _relative(body)
	_body_parent = _relative(body.get_parent_node_3d()) if body != null else Transform3D.IDENTITY


## Transform of `node` relative to this node, computed through local transforms (works before the
## node is in a tree and regardless of where the car currently is).
func _relative(node: Node3D) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n := node
	while n != null and n != self:
		t = n.transform * t
		n = n.get_parent_node_3d()
	return t


func _physics_process(delta: float) -> void:
	if _car == null or _car.wheels.size() != 4:
		return
	_time += delta
	var speed := absf(_car.speed_kmh) / 3.6
	for i in 4:
		var w: WheelState = _car.wheels[i]
		var jiggle := 0.0
		if w.contact:
			jiggle = sin(_time * (37.0 + i * 5.3)) * sin(_time * (23.0 + i * 3.1)) \
					* surface_jiggle * w.surface_roughness * clampf(speed / 20.0, 0.0, 1.0)
		var lift := Vector3(0.0, w.offset_y + jiggle, 0.0)
		var steer_basis := Basis(Vector3.UP, -w.steer_angle)
		var wn := _wheel_nodes[i]
		if wn != null:
			var rest := _wheel_rest[i]
			var rel := Transform3D(steer_basis * Basis(Vector3.RIGHT, -w.spin_angle) * rest.basis, rest.origin + lift)
			wn.transform = _wheel_parent[i].affine_inverse() * rel
		var cn := _caliper_nodes[i]
		if cn != null:
			var crest := _caliper_rest[i]
			var wheel_centre := _wheel_rest[i].origin
			var arm := crest.origin - wheel_centre
			var crel := Transform3D(steer_basis * crest.basis, wheel_centre + steer_basis * arm + lift)
			cn.transform = _caliper_parent[i].affine_inverse() * crel
	_update_lean(delta)


func _update_lean(delta: float) -> void:
	if body == null or delta <= 0.0:
		return
	var v := _car.linear_velocity
	var accel := (v - _prev_velocity) / delta
	_prev_velocity = v
	var local_acc := _car.global_transform.basis.inverse() * accel / 9.81
	var limit := deg_to_rad(max_lean_deg)
	var per_g := deg_to_rad(lean_per_g_deg)
	# Nose dips under braking (pitch forward), body rolls away from the turn.
	var target := Vector2(clampf(local_acc.z * per_g, -limit, limit), clampf(local_acc.x * per_g, -limit, limit))
	if _car.grounded_wheels == 0:
		target = Vector2.ZERO
	_lean = _lean.lerp(target, 1.0 - exp(-lean_smoothing * delta))
	var pivot := Vector3(0.0, 0.45, 0.0)
	var rot := Basis(Vector3.RIGHT, -_lean.x) * Basis(Vector3.BACK, _lean.y)
	var lean_xf := Transform3D(Basis.IDENTITY, pivot) * Transform3D(rot, Vector3.ZERO) * Transform3D(Basis.IDENTITY, -pivot)
	body.transform = _body_parent.affine_inverse() * (lean_xf * _body_rest)


## Recolours every material named Paint (primary) / Paint2 (secondary) on this car instance.
func apply_livery(primary: Color, secondary: Color) -> void:
	if model == null:
		return
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_surface_override_material(s)
			if mat == null:
				mat = mi.mesh.surface_get_material(s)
			if mat == null:
				continue
			var mat_name := mat.resource_name.to_lower()
			if not mat_name.contains("paint"):
				continue
			var colour := secondary if mat_name.contains("paint2") else primary
			var inst: Material = _livery_cache.get(mat)
			if inst == null:
				if _livery_cache.values().has(mat):
					inst = mat
				else:
					inst = mat.duplicate() as Material
					_livery_cache[mat] = inst
			_set_colour(inst, colour)
			mi.set_surface_override_material(s, inst)


static func _set_colour(mat: Material, colour: Color) -> void:
	if mat is BaseMaterial3D:
		(mat as BaseMaterial3D).albedo_color = colour
	elif mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		if sm.shader == null:
			return
		for u in sm.shader.get_shader_uniform_list():
			var uname: String = u["name"]
			if uname in ["albedo", "albedo_color", "base_color", "color", "paint_color"]:
				sm.set_shader_parameter(uname, colour)
