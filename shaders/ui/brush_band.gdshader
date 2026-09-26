// A single horizontal brush swash (sumi-e / hanko-red paint stroke) filling its rect.
// progress 0 -> 1 paints it left to right with a round wet head and dry-brush streaks;
// fade_out 0 -> 1 dries it away (streaks first).
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform vec4 paint : source_color = vec4(0.91, 0.318, 0.486, 1.0);
uniform float progress = 1.0;
uniform float fade_out = 0.0;
uniform float seed = 1.0;
uniform vec2 rect_size = vec2(800.0, 120.0);
uniform float taper = 0.35; // how much the stroke thins towards its tail

void fragment() {
	vec2 uv = UV;
	float x = uv.x;
	float head_x = progress * 1.12 - 0.06;
	// Body thickness: slight belly, taper at the end, wobbling edges.
	float thick = 0.42 * (1.0 - taper * smoothstep(0.55, 1.0, x)) * (0.9 + 0.1 * sin(x * 7.0 + seed));
	float centre = 0.5 + (ui_noise(vec2(x * 3.0, seed)) - 0.5) * 0.12 - x * 0.05;
	float edge_noise = (ui_fbm(vec2(x * rect_size.x * 0.02, uv.y * 4.0 + seed)) - 0.5) * 0.12;
	float dy = abs(uv.y - centre);
	float body = 1.0 - smoothstep(thick - 0.02, thick + 0.01, dy + edge_noise);
	// Dry brush streaks along the stroke direction.
	float streak = ui_noise(vec2(x * 3.0 + seed, uv.y * rect_size.y * 0.35));
	float dryness = smoothstep(0.55, 1.0, x) * 0.7 + smoothstep(0.25, 0.4, dy / max(thick, 0.01)) * 0.4;
	float dry = smoothstep(dryness * 0.8 - 0.1, dryness * 0.8 + 0.1, streak + 0.25);
	// Round head where the brush currently is.
	float aspect = rect_size.x / max(rect_size.y, 1.0);
	float head = smoothstep(0.0, 0.015, head_x - x + (dy * dy) * 0.25 / aspect);
	float a = body * dry * head;
	// Fading: streaks disappear first.
	a *= smoothstep(fade_out * 1.2 - 0.1, fade_out * 1.2 + 0.05, streak * 0.8 + 0.2 * (1.0 - x));
	// Pigment pooling: darker at the start and edges.
	vec3 col = paint.rgb * (1.0 - 0.12 * smoothstep(0.2, 0.0, x) - 0.08 * smoothstep(0.5, 1.0, dy / max(thick, 0.01)));
	col += (ui_washi(UV * rect_size) - 0.5) * 0.06;
	COLOR = vec4(col, paint.a * a * COLOR.a);
}
