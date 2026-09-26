class_name ToonMaterials
extends RefCounted
## Toon material factory and the converter that swaps imported glTF
## StandardMaterial3Ds for the cel shader (see docs/CONTRACTS.md, "Material naming").

const TOON_SHADER := preload("res://shaders/toon.gdshader")
const OUTLINE_SHADER := preload("res://shaders/outline_hull.gdshader")

## Ramp presets: [edges (x, y), values (x, y, z)] in half-lambert space.
const RAMPS := {
	"cel": [Vector3(0.47, 0.62, 2.0), Vector3(0.50, 0.78, 1.0)],
	"soft": [Vector3(0.46, 0.63, 2.0), Vector3(0.60, 0.82, 1.0)],
	"hero": [Vector3(0.49, 0.72, 2.0), Vector3(0.55, 0.88, 1.0)],
	"foliage": [Vector3(0.44, 0.60, 2.0), Vector3(0.50, 0.80, 1.02)],
	"blossom": [Vector3(0.40, 0.58, 2.0), Vector3(0.66, 0.86, 1.0)],
	"terrain": [Vector3(0.45, 0.60, 2.0), Vector3(0.52, 0.80, 1.0)],
}

static var _cache: Dictionary = {}


## Build (or fetch from cache) a toon material.
## opts: ramp (String), vertex_color (bool), sway (float), sway_start, sway_end,
## receive_shadow (float), emission (Color), emission_energy (float), rim (float),
## spec (float), spec_size (float), grain (float), instance_tint (bool), gloss (float),
## wrap (float), shade_tint_amount (float), texture (Texture2D), cull (String: back/disabled)
static func make(color: Color, opts: Dictionary = {}) -> ShaderMaterial:
	var key := "%s|%s" % [color.to_html(), str(opts)]
	if _cache.has(key):
		return _cache[key]
	var m := ShaderMaterial.new()
	m.shader = TOON_SHADER
	var ramp: Array = RAMPS.get(opts.get("ramp", "cel"), RAMPS["cel"])
	m.set_shader_parameter("ramp_edges", ramp[0])
	m.set_shader_parameter("ramp_values", ramp[1])
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("use_vertex_color", opts.get("vertex_color", false))
	m.set_shader_parameter("sway_amount", opts.get("sway", 0.0))
	m.set_shader_parameter("sway_start", opts.get("sway_start", 0.5))
	m.set_shader_parameter("sway_end", opts.get("sway_end", 4.0))
	m.set_shader_parameter("receive_shadow", opts.get("receive_shadow", 1.0))
	m.set_shader_parameter("rim_strength", opts.get("rim", 0.0))
	m.set_shader_parameter("spec_strength", opts.get("spec", 0.0))
	m.set_shader_parameter("spec_size", opts.get("spec_size", 0.965))
	m.set_shader_parameter("grain_amount", opts.get("grain", 0.1))
	m.set_shader_parameter("use_instance_tint", opts.get("instance_tint", false))
	m.set_shader_parameter("gloss_band", opts.get("gloss", 0.0))
	m.set_shader_parameter("wrap_light", opts.get("wrap", 0.0))
	m.set_shader_parameter("shade_tint_amount", opts.get("shade_tint_amount", 1.0))
	if opts.has("emission"):
		m.set_shader_parameter("emission", opts["emission"])
		m.set_shader_parameter("emission_energy", opts.get("emission_energy", 1.0))
	if opts.has("texture"):
		m.set_shader_parameter("albedo_texture", opts["texture"])
		m.set_shader_parameter("use_texture", true)
	_cache[key] = m
	return m


## Options for an imported material name (keyword table in CONTRACTS.md).
static func opts_for_name(mat_name: String, has_vertex_color: bool) -> Dictionary:
	var n := mat_name.to_lower()
	var o := {"vertex_color": has_vertex_color}
	if n.contains("blossom"):
		o.merge({"ramp": "blossom", "receive_shadow": 0.25, "sway": 0.8, "sway_start": 1.2, "sway_end": 6.0, "wrap": 0.35, "grain": 0.08, "shade_tint_amount": 0.8})
	elif n.contains("leaf") or n.contains("leaves") or n.contains("foliage") or n.contains("needle") or n.contains("grass"):
		o.merge({"ramp": "foliage", "receive_shadow": 0.85, "sway": 0.7, "sway_start": 0.8, "sway_end": 6.0, "wrap": 0.2, "grain": 0.1})
	elif n.contains("glass"):
		o.merge({"ramp": "hero", "gloss": 0.55, "spec": 1.2, "spec_size": 0.985, "grain": 0.0})
	elif n.contains("light") or n.contains("emit") or n.contains("lamp") or n.contains("lantern"):
		o.merge({"ramp": "soft", "emission_energy": 0.6, "grain": 0.0})
	elif n.contains("paint") or n.contains("accent"):
		o.merge({"ramp": "hero", "spec": 0.8, "spec_size": 0.975, "rim": 0.5, "grain": 0.0})
	elif n.contains("chrome") or n.contains("metal"):
		o.merge({"ramp": "hero", "spec": 1.4, "spec_size": 0.94, "grain": 0.0})
	elif n.contains("water"):
		o.merge({"ramp": "soft", "gloss": 0.4, "spec": 2.0, "spec_size": 0.99})
	return o


## Replace every BaseMaterial3D under `root` with a toon ShaderMaterial.
## overrides: material name -> Color, to recolour (car livery).
static func convert_tree(root: Node, overrides: Dictionary = {}, extra: Dictionary = {}) -> void:
	for node in _all_meshes(root):
		var mi := node as MeshInstance3D
		var mesh := mi.mesh
		if mesh == null:
			continue
		for s in mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(s)
			if src == null:
				src = mesh.surface_get_material(s)
			if src == null or src is ShaderMaterial:
				continue
			var base := src as BaseMaterial3D
			var mat_name := src.resource_name
			var color := base.albedo_color if base else Color.WHITE
			if overrides.has(mat_name):
				color = overrides[mat_name]
			var am := mesh as ArrayMesh
			var has_vc: bool = am != null and (am.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR) != 0
			var o := opts_for_name(mat_name, has_vc)
			o.merge(extra, true)
			if base and o.has("emission_energy") and not o.has("emission"):
				o["emission"] = base.emission if base.emission_enabled else color
			mi.set_surface_override_material(s, make(color, o))


static func _all_meshes(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	if root is MeshInstance3D:
		out.append(root)
	for c in root.get_children():
		out.append_array(_all_meshes(c))
	return out


## Inverted-hull outline pass appended to a material (hero objects: the car).
## width is in pixels at 1080p (see shaders/outline_hull.gdshader).
static func with_outline(mat: Material, width: float = 1.6, color: Color = Color("2a2235")) -> Material:
	var o := ShaderMaterial.new()
	o.shader = OUTLINE_SHADER
	o.set_shader_parameter("width", width)
	o.set_shader_parameter("ink", color)
	var dup := mat.duplicate()
	dup.next_pass = o
	return dup
