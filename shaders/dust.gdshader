// Low-poly dust puff / gravel chip. Opaque faceted shapes that grow and shrink
// (particle scale curve) instead of fading, like dust painted in anime cels.
// Three flat tones from the sun direction (the shade tone takes the violet tint),
// and puffs shrink away as they near the camera so they never fill the frame.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque, shadows_disabled;

#include "res://shaders/inc/toon.gdshaderinc"

uniform vec3 sun_dir = vec3(0.45, 0.7, 0.3);
uniform float lit_boost = 1.07;
uniform float shade_mix = 0.75;
/// View distance (m) where a puff is gone / at full size.
uniform float near_fade_start = 1.6;
uniform float near_fade_end = 5.5;

varying vec3 v_normal_world;

void vertex() {
	v_normal_world = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 centre_view = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	VERTEX *= smoothstep(near_fade_start, near_fade_end, length(centre_view));
}

void fragment() {
	vec3 base = COLOR.rgb;
	float nl = dot(normalize(v_normal_world), normalize(sun_dir));
	vec3 shade = mix(base, base * sr_shade_tint.rgb, shade_mix);
	vec3 mid = mix(base, shade, 0.45);
	vec3 c = nl < -0.05 ? shade : (nl < 0.45 ? mid : base * lit_boost);
	// top facets catch a warm rim like the terrain
	c = mix(c, c * sr_rim_color.rgb * 1.08, smoothstep(0.6, 0.9, v_normal_world.y) * step(0.45, nl) * 0.35);
	ALBEDO = c;
}
