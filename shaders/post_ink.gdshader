// Screen-space ink from the second difference of linear depth.
//
// A first difference smears ink across any surface that grazes the camera
// (the road); the second difference is zero across any plane however oblique,
// so lines fire only on silhouettes and real creases. Convex curvature (the
// near side of a silhouette, a ridge) inks strongly, concave corners faintly,
// like the lighter contact lines an animator draws. Lines fade with distance.
//
// Drawn on a full-screen quad at the very start of the transparent pass
// (render_priority -128), outputting only the lines with alpha, so particles
// and water drawn afterwards stay clean.
shader_type spatial;
render_mode unshaded, depth_test_disabled, depth_draw_never, cull_disabled, fog_disabled, blend_mix, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform vec3 ink : source_color = vec3(0.165, 0.133, 0.208);
uniform float thickness = 1.25;
uniform float sens = 0.06;
uniform float concave = 0.05;
uniform float concave_amount = 0.32;
uniform float fade_start = 90.0;
uniform float fade_end = 340.0;
uniform float strength = 0.9;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float view_z(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float raw = texture(depth_tex, uv).r;
	if (raw <= 0.0000001) {
		discard;
	}
	float px = thickness * max(VIEWPORT_SIZE.y / 1080.0, 1.0);
	vec2 t = px / VIEWPORT_SIZE;
	float zc = view_z(uv, INV_PROJECTION_MATRIX);
	float wc = 1.0 / zc;
	float wl = 1.0 / view_z(uv - vec2(t.x, 0.0), INV_PROJECTION_MATRIX);
	float wr = 1.0 / view_z(uv + vec2(t.x, 0.0), INV_PROJECTION_MATRIX);
	float wu = 1.0 / view_z(uv + vec2(0.0, t.y), INV_PROJECTION_MATRIX);
	float wd = 1.0 / view_z(uv - vec2(0.0, t.y), INV_PROJECTION_MATRIX);
	float wl2 = 1.0 / view_z(uv + vec2(-t.x, t.y), INV_PROJECTION_MATRIX);
	float wr2 = 1.0 / view_z(uv + vec2(t.x, -t.y), INV_PROJECTION_MATRIX);

	float sx = (wl + wr - 2.0 * wc) / wc;
	float sy = (wu + wd - 2.0 * wc) / wc;
	float sd = (wl2 + wr2 - 2.0 * wc) / wc;
	float convex = max(0.0, -sx) + max(0.0, -sy) + 0.5 * max(0.0, -sd);
	float concavity = max(0.0, sx) + max(0.0, sy);

	float edge = smoothstep(sens * 0.35, sens, convex);
	edge = max(edge, smoothstep(concave, concave * 3.5, concavity) * concave_amount);
	edge *= 1.0 - smoothstep(fade_start, fade_end, zc);
	edge = clamp(edge * strength, 0.0, 1.0);
	if (edge < 0.004) {
		discard;
	}
	vec3 col = texture(screen_tex, uv).rgb;
	ALBEDO = mix(ink, col * 0.38, 0.24);
	ALPHA = edge;
}
