class_name CarLook
extends RefCounted
## Converts a car's imported model to the cel look: per-material toon options
## (hero ramp on paint and decals so they band together), an inked hull on the
## body shell and tyres, and per-car brake/head light materials that CarFX drives.

const OUTLINED := ["paint", "trim", "rubber", "accent"]


## Returns {"tail": Array[ShaderMaterial], "head": Array[ShaderMaterial]} for CarFX.
static func apply(car: Car) -> Dictionary:
	var lights := {"tail": [], "head": []}
	var visuals := car.get_node_or_null(^"Visuals") as CarVisuals
	if visuals == null or visuals.model == null:
		return lights
	for node in visuals.model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var src: Material = mi.get_surface_override_material(s)
			if src == null:
				src = mi.mesh.surface_get_material(s)
			if src == null or src is ShaderMaterial:
				continue
			var base := src as BaseMaterial3D
			var n := src.resource_name.to_lower()
			var color := base.albedo_color if base else Color.WHITE
			var mat: Material = ToonMaterials.make(color, _opts(n, base))
			# make() returns a shared cached material; lights and outlined parts get their own copy.
			var own := false
			if n.contains("taillight") or n.contains("headlight"):
				mat = mat.duplicate()
				own = true
				lights["tail" if n.contains("taillight") else "head"].append(mat)
			for key in OUTLINED:
				if n.contains(key):
					mat = ToonMaterials.with_outline(mat, 1.5 if key != "rubber" else 1.3)
					own = true
					break
			# Keep the glTF name on the car's own copies: CarVisuals.apply_livery finds Paint /
			# Paint2 by name, so later livery changes recolour the converted toon paint.
			if own:
				mat.resource_name = src.resource_name
			mi.set_surface_override_material(s, mat)
	# re-apply the livery on top of the converted paint (duplicates per car)
	visuals.apply_livery(car.livery_primary, car.livery_secondary)
	return lights


static func _opts(n: String, base: BaseMaterial3D) -> Dictionary:
	if n.contains("paint") or n.contains("accent"):
		return {"ramp": "hero", "spec": 0.8, "spec_size": 0.975, "rim": 0.5, "grain": 0.0}
	if n.contains("decal") or n.contains("number"):
		return {"ramp": "hero", "rim": 0.5, "grain": 0.0}
	if n.contains("glass"):
		return {"ramp": "hero", "gloss": 0.55, "spec": 1.2, "spec_size": 0.985, "grain": 0.0}
	if n.contains("chrome"):
		return {"ramp": "hero", "spec": 1.4, "spec_size": 0.94, "grain": 0.0}
	if n.contains("rim"):
		return {"ramp": "hero", "spec": 1.0, "spec_size": 0.95, "rim": 0.3, "grain": 0.0}
	if n.contains("taillight"):
		var c := base.emission if base and base.emission_enabled else Color("ff3b3b")
		return {"ramp": "soft", "emission": c, "emission_energy": 0.35, "grain": 0.0}
	if n.contains("headlight"):
		var c := base.emission if base and base.emission_enabled else Color("fff4dc")
		return {"ramp": "soft", "emission": c, "emission_energy": 0.5, "grain": 0.0}
	if n.contains("rubber"):
		return {"ramp": "cel", "grain": 0.05}
	return {"ramp": "cel", "grain": 0.04}
