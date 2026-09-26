// Brush stroke reveal for glyphs drawn by UIBrushKanji.
// Stroke mode: the glyph shows only where a virtual brush has already travelled along the
// authored stroke centrelines (grid 0..10 over the glyph box), stroke by stroke.
// Wipe mode (stroke_count == 0): a ragged ink front sweeps along `wipe_dir`.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

const int MAX_PTS = 64;
const int MAX_STROKES = 16;

uniform vec2 box_origin = vec2(0.0);
uniform float box_size = 100.0;
uniform vec2 pts[MAX_PTS];
uniform int pt_stroke[MAX_PTS];
uniform float pt_s[MAX_PTS];
uniform int pt_count = 0;
uniform float stroke_p[MAX_STROKES];
uniform int stroke_count = 0;
uniform float brush_radius = 0.62;
uniform vec2 wipe_dir = vec2(1.0, 0.0);
uniform vec2 wipe_extent = vec2(0.0, 100.0); // projection range of the text along wipe_dir
uniform float wipe_p = 1.0;
uniform float wet = 0.0; // 0..1 darkening near the brush tip while painting

varying vec2 local;

void vertex() {
	local = VERTEX;
}

void fragment() {
	float mask = 0.0;
	float tip = 0.0;
	if (stroke_count > 0) {
		vec2 g = (local - box_origin) / box_size * 10.0;
		float wobble = (ui_noise(g * 3.1) - 0.5) * 0.22;
		float dmin = 1e3;
		for (int j = 0; j < MAX_PTS - 1; j++) {
			if (j >= pt_count - 1) {
				break;
			}
			int k = pt_stroke[j];
			if (k != pt_stroke[j + 1]) {
				continue;
			}
			float p = stroke_p[k];
			float sa = pt_s[j];
			float sb = pt_s[j + 1];
			if (p <= sa) {
				continue;
			}
			float f = clamp((p - sa) / max(sb - sa, 1e-4), 0.0, 1.0);
			vec2 a = pts[j];
			vec2 b = mix(a, pts[j + 1], f);
			float d = ui_sd_segment(g, a, b);
			// Round cap only where the brush currently is; swell a little at the tip.
			if (p < 1.0 && f < 1.0) {
				float dt = length(g - b);
				tip = max(tip, 1.0 - smoothstep(0.0, brush_radius * 1.4, dt));
			}
			dmin = min(dmin, d);
		}
		mask = 1.0 - smoothstep(brush_radius - 0.12, brush_radius + 0.02, dmin + wobble);
	} else {
		float proj = dot(local, normalize(wipe_dir));
		float u = (proj - wipe_extent.x) / max(wipe_extent.y - wipe_extent.x, 1.0);
		vec2 perp = vec2(-wipe_dir.y, wipe_dir.x);
		float ragged = (ui_fbm(vec2(dot(local, perp) * 0.035, 3.0)) - 0.5) * 0.18;
		float front = wipe_p * 1.2 - 0.1;
		mask = smoothstep(u + ragged - 0.02, u + ragged + 0.02, front);
		tip = (1.0 - smoothstep(0.0, 0.08, abs(u + ragged - front))) * step(wipe_p, 0.999);
	}
	vec4 c = COLOR;
	c.rgb = mix(c.rgb, c.rgb * 0.7, tip * wet);
	COLOR = vec4(c.rgb, c.a * mask);
}
