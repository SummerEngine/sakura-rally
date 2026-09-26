// Painted campaign map (scripts/ui/screens/journey_map.gd): washi paper, a watercolour land
// wash that turns from spring (blossom greens) through summer (deep greens, a blue bay with
// wave marks) to autumn (maple ambers), cel-banded with darkened pigment edges.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform vec2 rect_size = vec2(1920.0, 1080.0);
// 0..1 wet-ink bleed from the centre outwards (entrance).
uniform float reveal = 1.0;
uniform vec3 paper : source_color = vec3(0.984, 0.961, 0.925);
uniform vec3 spring : source_color = vec3(0.78, 0.87, 0.6);
uniform vec3 spring_bloom : source_color = vec3(0.97, 0.78, 0.84);
uniform vec3 summer : source_color = vec3(0.56, 0.78, 0.44);
uniform vec3 autumn : source_color = vec3(0.95, 0.66, 0.36);
uniform vec3 autumn_deep : source_color = vec3(0.86, 0.38, 0.26);
uniform vec3 sea : source_color = vec3(0.49, 0.72, 0.9);
uniform vec3 shadow_tint : source_color = vec3(0.6, 0.57, 0.78);

// Signed distance-ish field of the sea: negative inside the bay at the top middle.
float sea_field(vec2 p) {
	float coast = 0.2 + 0.06 * sin(p.x * 9.0 + 1.3) + (ui_fbm(vec2(p.x * 5.0, 3.1)) - 0.5) * 0.09;
	float bay = smoothstep(0.3, 0.42, p.x) * smoothstep(0.7, 0.58, p.x);
	return p.y - mix(-0.08, coast, bay);
}

void fragment() {
	vec2 uv = UV;
	vec2 px = uv * rect_size;
	float aspect = rect_size.x / max(rect_size.y, 1.0);
	vec2 p = vec2(uv.x, uv.y);

	float grain = ui_washi(px);
	vec3 col = paper * (0.965 + grain * 0.05);

	// Season blend across the map, the border warped so it reads as painted, not ruled.
	float warp = (ui_fbm(vec2(p.x * 3.0, p.y * 4.0) + 7.0) - 0.5) * 0.12;
	float sx = p.x + warp;
	float to_summer = smoothstep(0.3, 0.4, sx);
	float to_autumn = smoothstep(0.6, 0.7, sx);

	// Pigment density: flat cel bands of a noisy wash.
	float dens = ui_fbm(vec2(p.x * aspect, p.y) * 4.0 + 3.7);
	float band = dens > 0.55 ? 1.0 : (dens > 0.42 ? 0.72 : 0.5);

	vec3 sp = mix(spring, spring_bloom, step(0.62, ui_fbm(vec2(p.x * aspect, p.y) * 9.0 + 1.9)) * 0.85);
	vec3 au = mix(autumn, autumn_deep, step(0.6, ui_fbm(vec2(p.x * aspect, p.y) * 8.0 + 4.4)) * 0.8);
	vec3 land = mix(mix(sp, summer, to_summer), au, to_autumn);
	vec3 wash = mix(paper, land, 0.55 + 0.45 * band);

	// Land edge: the wash fades out towards the frame with a darker pigment rim.
	float edge_n = (ui_fbm(p * 6.0 + 11.0) - 0.5) * 0.05;
	vec2 q = abs(p - 0.5) * 2.0;
	float frame = max(q.x, q.y * 0.98) + edge_n;
	float land_mask = smoothstep(0.93, 0.9, frame);
	float rim = smoothstep(0.86, 0.9, frame) * land_mask;
	wash = mix(wash, wash * mix(vec3(1.0), shadow_tint, 0.55), rim * 0.6);
	col = mix(col, wash, land_mask);

	// The bay: flat blue with a lighter shallows band, a pigment rim and cel wave marks.
	float sf = sea_field(p);
	float in_sea = smoothstep(0.004, -0.004, sf) * land_mask;
	float shallows = smoothstep(-0.05, -0.012, sf);
	vec3 water = mix(sea, mix(sea, paper, 0.45), shallows);
	float wave_row = fract((p.y + 0.012 * sin(p.x * 60.0)) * 38.0);
	float wave_on = step(0.62, ui_noise(vec2(p.x * 22.0, floor(p.y * 38.0) * 3.3)));
	float wave = smoothstep(0.08, 0.0, abs(wave_row - 0.5) - 0.04) * wave_on * smoothstep(-0.02, -0.06, sf);
	water = mix(water, mix(sea, paper, 0.8), wave * 0.8);
	float coast_line = smoothstep(0.006, 0.0, abs(sf)) * land_mask;
	col = mix(col, water, in_sea);
	col = mix(col, mix(col, UI_INK, 0.55), coast_line * 0.7);

	// Wet-ink entrance: the painting bleeds out from the middle over bare paper.
	float bleed = length((uv - 0.5) * vec2(aspect, 1.0)) / (0.5 * length(vec2(aspect, 1.0)));
	float front = reveal * 1.25 - bleed + (ui_fbm(px * 0.01) - 0.5) * 0.25;
	float shown = smoothstep(0.0, 0.04, front);
	vec3 bare = paper * (0.965 + grain * 0.05);
	col = mix(bare, col, shown);
	// A darker tide line right at the bleed front, like wet pigment drying.
	col = mix(col, col * mix(vec3(1.0), shadow_tint, 0.6), smoothstep(0.04, 0.0, abs(front - 0.02)) * (1.0 - step(0.999, reveal)) * 0.7);

	// Soft vignette.
	float vig = smoothstep(0.55, 1.1, length((uv - 0.5) * vec2(aspect * 0.8, 1.0)));
	col = mix(col, col * shadow_tint, vig * 0.25);
	COLOR = vec4(col, COLOR.a);
}
