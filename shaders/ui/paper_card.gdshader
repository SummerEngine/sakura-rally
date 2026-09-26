// Frosted washi-paper card: blurred backdrop tinted with paper, grain, inner highlight,
// hairline ink border and a soft violet drop shadow. Drawn by UIPaperCard over a rect that
// extends `pad` pixels beyond the card on every side (room for the shadow).
shader_type canvas_item;
render_mode blend_mix;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec2 card_size = vec2(400.0, 300.0);
uniform float radius = 26.0;
uniform vec4 paper : source_color = vec4(0.984, 0.961, 0.925, 0.86);
uniform float blur_lod = 3.5;
uniform float shadow_alpha = 0.2;
uniform float shadow_size = 44.0;
uniform vec2 shadow_offset = vec2(0.0, 16.0);
uniform float grain = 0.05;
uniform float inner_glow = 0.4;
uniform vec4 wash : source_color = vec4(1.0, 1.0, 1.0, 0.0);
uniform float lift = 0.0;
uniform float reveal = 1.0;
uniform float reveal_angle = 0.35;

varying vec2 local;

void vertex() {
	local = VERTEX;
}

void fragment() {
	vec2 half_size = card_size * 0.5;
	vec2 p = local - half_size;
	float d = ui_sd_round_box(p, half_size, radius);
	float inside = clamp(0.5 - d, 0.0, 1.0);

	float s_size = shadow_size * (1.0 + 0.45 * lift);
	vec2 s_off = shadow_offset * (1.0 + 0.6 * lift);
	float ds = ui_sd_round_box(p - s_off, half_size - vec2(10.0), radius);
	float sh = (1.0 - smoothstep(-s_size * 0.35, s_size, ds)) * shadow_alpha * (1.0 + 0.35 * lift);

	vec3 back = textureLod(screen_tex, SCREEN_UV, blur_lod).rgb;
	vec3 col = mix(back, paper.rgb, paper.a);
	col = mix(col, wash.rgb, wash.a * smoothstep(card_size.y * 1.1, -card_size.y * 0.2, local.y));
	col -= (ui_washi(local) - 0.5) * grain;
	float rim = smoothstep(-9.0, -1.5, d) * (1.0 - smoothstep(-1.5, 0.0, d));
	col = mix(col, vec3(1.0), rim * inner_glow);
	float hair = 1.0 - smoothstep(0.0, 1.3, abs(d + 0.7));
	col = mix(col, UI_INK, hair * 0.09);

	// Brush reveal: a ragged diagonal front that washes the card in.
	float u = (local.x + local.y * reveal_angle) / (card_size.x + card_size.y * reveal_angle);
	u += (ui_fbm(local * 0.02) - 0.5) * 0.12;
	float m = smoothstep(u - 0.04, u + 0.01, reveal * 1.15 - 0.05);

	float a = inside + sh * (1.0 - inside);
	vec3 rgb = (col * inside + UI_INK * sh * (1.0 - inside)) / max(a, 1e-4);
	COLOR = vec4(rgb, a * m * COLOR.a);
}
