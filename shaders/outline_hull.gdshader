// Inverted-hull outline: back faces pushed out along the normal in clip space,
// so hero objects keep a near-constant pixel-width inked contour.
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled, fog_disabled;

uniform float width = 1.6; // pixels at 1080p
uniform vec4 ink : source_color = vec4(0.165, 0.133, 0.208, 1.0);
uniform float near_scale_dist = 9.0;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	vec3 n_view = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec2 n_clip = (PROJECTION_MATRIX * vec4(n_view, 0.0)).xy;
	float len = length(n_clip);
	if (len > 0.0001) {
		n_clip /= len;
	}
	float px = width * max(VIEWPORT_SIZE.y / 1080.0, 1.0);
	float dist_scale = clamp(near_scale_dist / max(clip.w, 0.01), 0.45, 1.0);
	clip.xy += n_clip * px * dist_scale * clip.w * 2.0 / VIEWPORT_SIZE;
	POSITION = clip;
}

void fragment() {
	ALBEDO = ink.rgb;
}
