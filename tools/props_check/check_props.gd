extends SceneTree
## Loads every prop GLB listed in assets/models/props/manifest.json and validates it.
##
## Run after importing:
##   $S --headless --disable-crash-handler --path . -s res://tools/props_check/check_props.gd
## Prints one line per prop (name, triangles, AABB size, materials, marker nodes) and a summary.
## Fails a prop when the file is missing / does not load, when its AABB differs from the manifest
## size by more than 10 % on any axis, when it exceeds its category triangle budget, when a
## material is missing a name, when a surface lacks vertex colours (canopy/bark gradients), or
## when a listed marker node is absent.

const MANIFEST := "res://assets/models/props/manifest.json"
const SIZE_TOLERANCE := 0.10
const BUDGETS := {
	"tree": 1500, "vegetation": 1500, "ground_cover": 40, "rock": 300, "building": 3000,
	"village": 3000, "roadside": 3000, "rally": 3000, "vehicle": 3000, "spectator": 600,
}


func _initialize() -> void:
	var text := FileAccess.get_file_as_string(MANIFEST)
	if text.is_empty():
		push_error("props_check: manifest missing: " + MANIFEST)
		quit(1)
		return
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary) or not data.has("props"):
		push_error("props_check: manifest is not valid JSON with a 'props' array")
		quit(1)
		return
	var failures: PackedStringArray = []
	var total_tris := 0
	var props: Array = data["props"]
	for entry: Dictionary in props:
		var problems := _check_prop(entry)
		total_tris += int(entry.get("_tris", 0))
		if not problems.is_empty():
			failures.append("%s: %s" % [entry["name"], "; ".join(problems)])
	print("PROPS_CHECK props=%d total_tris=%d failures=%d" % [props.size(), total_tris, failures.size()])
	for f in failures:
		printerr("PROPS_CHECK FAIL " + f)
	quit(0 if failures.is_empty() else 1)


func _check_prop(entry: Dictionary) -> PackedStringArray:
	var problems: PackedStringArray = []
	var path: String = entry["file"]
	if not ResourceLoader.exists(path):
		problems.append("missing file " + path)
		return problems
	var packed := load(path) as PackedScene
	if packed == null:
		problems.append("failed to load " + path)
		return problems
	var root := packed.instantiate() as Node3D
	if root == null:
		problems.append("root is not Node3D")
		return problems
	var tris := 0
	var vcol := true
	var mats: PackedStringArray = []
	var aabb := AABB()
	var first := true
	for mi: MeshInstance3D in _mesh_instances(root):
		var mesh := mi.mesh
		var xf := _transform_to_root(mi, root)
		for s in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			tris += (idx.size() if idx.size() > 0 else verts.size()) / 3
			var cols: Variant = arrays[Mesh.ARRAY_COLOR]
			if cols == null or (cols as PackedColorArray).size() != verts.size():
				vcol = false
			var mat := mesh.surface_get_material(s)
			var mname := mat.resource_name if mat else "<none>"
			if mname.is_empty():
				problems.append("unnamed material on surface %d" % s)
			if not mats.has(mname):
				mats.append(mname)
		var box := xf * mesh.get_aabb()
		aabb = box if first else aabb.merge(box)
		first = false
	entry["_tris"] = tris
	var want: Array = entry["size"]
	for axis in 3:
		var w := float(want[axis])
		var got := aabb.size[axis]
		if absf(got - w) > maxf(w * SIZE_TOLERANCE, 0.02):
			problems.append("aabb axis %d = %.3f vs manifest %.3f" % [axis, got, w])
	var budget: int = BUDGETS.get(entry["category"], 3000)
	if not vcol:
		problems.append("missing vertex colours on some surface")
	if tris > budget:
		problems.append("tris %d > budget %d" % [tris, budget])
	if aabb.position.y > 0.05:
		problems.append("floats above origin (min y %.3f)" % aabb.position.y)
	var markers: PackedStringArray = []
	if entry.has("markers"):
		for marker_name: String in entry["markers"]:
			var n := root.find_child(marker_name, true, false) as Node3D
			if n == null:
				problems.append("marker %s missing" % marker_name)
			else:
				markers.append("%s@%s" % [marker_name, _fmt_v(_transform_to_root(n, root).origin)])
	print("PROP %-20s tris=%5d aabb=%s mats=[%s]%s" % [
		entry["name"], tris, _fmt_v(aabb.size), ", ".join(mats),
		("  markers=" + " ".join(markers)) if not markers.is_empty() else ""])
	root.free()
	return problems


func _mesh_instances(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(n)
	for c in n.get_children():
		out.append_array(_mesh_instances(c))
	return out


func _transform_to_root(n: Node3D, root: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur != null and cur != root:
		xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


func _fmt_v(v: Vector3) -> String:
	return "(%.2f, %.2f, %.2f)" % [v.x, v.y, v.z]
