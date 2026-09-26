// Map card art: the top-down render filling its rect, rounded on the chosen corners and zoomed
// about the centre (the card's focus zoom; the route overlay applies the same zoom).
// `saturation` lets resting cards sit back a little.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform sampler2D image : source_color, filter_linear_mipmap, repeat_disable;
uniform vec2 rect_size = vec2(452.0, 260.0);
uniform float radius = 26.0;
uniform vec4 corner_mask = vec4(1.0, 1.0, 0.0, 0.0); // tl, tr, br, bl
uniform float zoom = 1.0;
uniform float saturation = 1.0;

void fragment() {
	vec2 uv = (UV - 0.5) / max(zoom, 1.0) + 0.5;
	vec3 col = texture(image, uv).rgb;
	float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
	col = mix(vec3(l), col, saturation);
	vec2 h = rect_size * 0.5;
	vec2 q = UV * rect_size - h;
	float r = q.x < 0.0 ? (q.y < 0.0 ? corner_mask.x : corner_mask.w) : (q.y < 0.0 ? corner_mask.y : corner_mask.z);
	float d = ui_sd_round_box(q, h, radius * r);
	COLOR = vec4(col, clamp(0.5 - d, 0.0, 1.0) * COLOR.a);
}
