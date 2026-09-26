// Pause backdrop: blurs whatever is on screen (mip-mapped screen texture, 9-tap), washes it
// towards warm paper, desaturates slightly and adds a soft violet vignette. `amount` 0 -> 1.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform float amount : hint_range(0.0, 1.0) = 1.0;
uniform vec4 paper : source_color = vec4(0.984, 0.961, 0.925, 1.0);
uniform vec4 shade : source_color = vec4(0.604, 0.573, 0.784, 1.0);

void fragment() {
	vec2 uv = SCREEN_UV;
	float lod = 3.2 * amount;
	vec2 px = SCREEN_PIXEL_SIZE * (1.0 + 5.0 * amount);
	vec3 acc = vec3(0.0);
	float wsum = 0.0;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			float w = (x == 0 && y == 0) ? 2.0 : 1.0;
			acc += textureLod(screen_tex, uv + vec2(float(x), float(y)) * px * 4.0, lod).rgb * w;
			wsum += w;
		}
	}
	vec3 col = acc / wsum;
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(lum), 0.25 * amount);
	col = mix(col, paper.rgb, 0.28 * amount);
	vec2 q = uv - 0.5;
	float vig = smoothstep(0.35, 0.95, length(q * vec2(1.2, 1.0)));
	col = mix(col, col * shade.rgb, vig * 0.5 * amount);
	col += (ui_hash(FRAGCOORD.xy) - 0.5) * 0.015 * amount;
	COLOR = vec4(col, amount);
}
