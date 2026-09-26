// Full-screen sumi brush transition. progress 0 -> 1: broad ink strokes sweep in from the
// left (with a sakura under-stroke peeking at the edges) until the screen is covered;
// 1 -> 2: the strokes lift off towards the right, revealing the new scene.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform float progress = 0.0;
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform vec4 ink : source_color = vec4(0.165, 0.133, 0.208, 1.0);
uniform vec4 accent : source_color = vec4(0.91, 0.318, 0.486, 1.0);
uniform float seed = 0.0;

const int BANDS = 7;

float ease_io(float t) {
	t = clamp(t, 0.0, 1.0);
	return t < 0.5 ? 4.0 * t * t * t : 1.0 - pow(-2.0 * t + 2.0, 3.0) * 0.5;
}

// Coverage of one brush band (0..1) at point p (x in 0..aspect, y in 0..1, skewed).
float band(vec2 p, float k, float delay, float h_scale, float aspect) {
	float yc = -0.08 + k * (1.16 / float(BANDS - 1));
	float h = (0.62 / float(BANDS)) * h_scale;
	float travel = aspect + 0.9;
	float t_in = ease_io((progress - delay) / 0.72);
	float t_out = ease_io((progress - 1.0 - delay) / 0.72);
	float front = -0.45 + travel * t_in;
	float back = -0.45 + travel * t_out;
	float dy = (p.y - yc) / h;
	// Ragged top / bottom edges, brush loses pressure towards the tail.
	float edge = 0.86 + 0.28 * ui_fbm(vec2(p.x * 2.6 + k * 7.1 + seed, k * 3.3));
	float body = 1.0 - smoothstep(edge - 0.06, edge, abs(dy));
	// Round brush head plus dry-brush bristle streaks near the leading edge.
	float head = front - 0.12 * dy * dy;
	float to_front = head - p.x;
	float streak = ui_fbm(vec2(p.x * 1.5 + seed, p.y * 55.0 + k * 11.0));
	float bristle = smoothstep(0.0, 0.3, to_front) + streak * 0.9 - 0.45;
	float lead = step(0.0, to_front) * smoothstep(0.0, 0.08, bristle + 0.04);
	// Trailing edge lifts with streaks too.
	float tail = back + 0.1 * dy * dy;
	float from_back = p.x - tail;
	float lift = smoothstep(0.0, 0.26, from_back) + streak * 0.9 - 0.45;
	float trail = step(0.0, from_back) * smoothstep(0.0, 0.08, lift + 0.04);
	return body * lead * trail;
}

void fragment() {
	float aspect = rect_size.x / max(rect_size.y, 1.0);
	vec2 p = vec2(UV.x * aspect, UV.y);
	// Slight diagonal for dynamism.
	float ang = -0.11;
	p = vec2(p.x * cos(ang) - (p.y - 0.5) * sin(ang), p.x * sin(ang) + (p.y - 0.5) * cos(ang) + 0.5);
	float ink_cov = 0.0;
	float pink_cov = 0.0;
	float shade = 0.0;
	for (int i = 0; i < BANDS; i++) {
		float k = float(i);
		float delay = abs(k - 3.0) * 0.045 + ui_hash(vec2(k, seed)) * 0.05;
		float b = band(p, k, delay + 0.05, 1.0, aspect);
		float u = band(p, k, delay, 1.12, aspect);
		if (b > ink_cov) {
			shade = ui_hash(vec2(k, 7.0 + seed));
		}
		ink_cov = max(ink_cov, b);
		pink_cov = max(pink_cov, u);
	}
	vec3 ink_col = ink.rgb * (0.9 + 0.2 * shade);
	ink_col += (ui_washi(UV * rect_size) - 0.5) * 0.05;
	vec3 col = mix(accent.rgb, ink_col, ink_cov);
	float a = max(ink_cov, pink_cov);
	COLOR = vec4(col, a * COLOR.a);
}
