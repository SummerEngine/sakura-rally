// Tyre marks: instanced road-aligned quads (MultiMesh ring buffer in CarFX).
// Instance colour carries tint and strength; edges are soft across the width.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, shadows_disabled, fog_disabled;

void fragment() {
	float edge = 1.0 - smoothstep(0.3, 0.5, abs(UV.x - 0.5));
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a * edge;
}
