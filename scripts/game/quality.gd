class_name Quality
extends RefCounted
## Render quality presets (Game setting "quality": "low" | "medium" | "high").
## Main applies them on every map load and whenever the settings change. The ink lines
## and the cel look stay on every preset; lower presets trade shadow resolution and
## reach, anti-aliasing, render scale, prop draw distance and particle counts.

## 3D pixels drawn per frame before a preset's own `scale`. Windows bigger than 1080p (a
## Retina window, fullscreen) render at this budget and FSR upscales the frame: the ink lines
## and cel bands survive the upscale, and the frame costs what a 1080p window does.
const RENDER_BUDGET_PX := 1920.0 * 1080.0

const PRESETS := {
	"high": {
		"msaa": Viewport.MSAA_4X, "fxaa": false, "scale": 1.0,
		"shadow_atlas": 8192, "shadow_splits": 4, "shadow_distance": 320.0,
		"view": 1.0, "vegetation_shadows": true, "glow": true,
	},
	"medium": {
		"msaa": Viewport.MSAA_2X, "fxaa": false, "scale": 1.0,
		"shadow_atlas": 4096, "shadow_splits": 4, "shadow_distance": 240.0,
		"view": 0.8, "vegetation_shadows": true, "glow": true,
	},
	"low": {
		"msaa": Viewport.MSAA_DISABLED, "fxaa": true, "scale": 0.75,
		"shadow_atlas": 2048, "shadow_splits": 2, "shadow_distance": 160.0,
		"view": 0.6, "vegetation_shadows": false, "glow": false,
	},
}


static func apply(q: String, window: Window, map: MapWorld) -> void:
	var p: Dictionary = PRESETS.get(q, PRESETS["high"])
	window.msaa_3d = p["msaa"]
	window.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if p["fxaa"] else Viewport.SCREEN_SPACE_AA_DISABLED
	apply_render_scale(q, window)
	RenderingServer.directional_shadow_atlas_set_size(p["shadow_atlas"], true)
	if map == null or not map.is_built:
		return
	var sun := map.atmosphere.sun
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS if p["shadow_splits"] == 4 \
			else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = p["shadow_distance"]
	map.atmosphere.environment.glow_enabled = p["glow"]
	var props := map.get_node_or_null(^"Props")
	if props == null:
		return
	for node in props.get_children():
		var mmi := node as MultiMeshInstance3D
		if mmi == null:
			continue
		# Node names are "<prop>_<chunk x>_<chunk z>" (MapWorld._build_instances).
		var prop := mmi.name.rsplit("_", true, 2)[0]
		var cat: String = (map.manifest.get(prop, {}) as Dictionary).get("category", "")
		if not mmi.has_meta(&"base_view"):
			mmi.set_meta(&"base_view", mmi.visibility_range_end)
			mmi.set_meta(&"base_shadow", mmi.cast_shadow)
		var base_view: float = mmi.get_meta(&"base_view")
		if base_view > 0.0:
			mmi.visibility_range_end = base_view * p["view"]
			mmi.visibility_range_end_margin = mmi.visibility_range_end * 0.15
		var base_shadow: int = mmi.get_meta(&"base_shadow")
		if cat == "vegetation" and not p["vegetation_shadows"]:
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		else:
			mmi.cast_shadow = base_shadow as GeometryInstance3D.ShadowCastingSetting


## The preset's 3D render scale within RENDER_BUDGET_PX at the window's current pixel size
## (the 3D render target under the canvas_items stretch). Main calls it again whenever the
## window is resized or goes fullscreen.
static func apply_render_scale(q: String, window: Window) -> void:
	var p: Dictionary = PRESETS.get(q, PRESETS["high"])
	var fit := minf(sqrt(RENDER_BUDGET_PX / maxf(window.size.x * window.size.y, 1.0)), 1.0)
	var s: float = p["scale"] * fit
	window.scaling_3d_scale = s
	window.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if s < 1.0 else Viewport.SCALING_3D_MODE_BILINEAR
