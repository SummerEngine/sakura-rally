// Cumulus cards (atlas from tools/build/gen_clouds.py: R lit, G underside, A cover).
// Colours come from the time of day, never from the texture. COLOR.r = haze.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, fog_disabled, shadows_disabled;

uniform sampler2D atlas : filter_linear_mipmap, repeat_disable;
uniform vec4 lit : source_color = vec4(1.0);
uniform vec4 shade : source_color = vec4(0.66, 0.71, 0.85, 1.0);
uniform vec4 deep_shade : source_color = vec4(0.55, 0.58, 0.77, 1.0);
uniform vec4 haze : source_color = vec4(0.93, 0.95, 0.94, 1.0);
uniform float opacity = 1.0;

void fragment() {
	vec4 t = texture(atlas, UV);
	float l = smoothstep(0.42, 0.58, t.r);
	vec3 c = mix(shade.rgb, lit.rgb, l);
	c = mix(c, deep_shade.rgb, t.g * (1.0 - l) * 0.8);
	c = mix(c, haze.rgb, COLOR.r);
	float a = smoothstep(0.2, 0.6, t.a) * opacity;
	if (a < 0.01) {
		discard;
	}
	ALBEDO = c;
	ALPHA = a;
}
