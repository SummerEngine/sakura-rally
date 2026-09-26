// Road ribbon. UV.x = lateral offset / half width (carriageway -1..1, verge beyond),
// UV.y = distance along the road in metres. UV2.x = gravel weight, UV2.y = wood deck.
// COLOR.rgb = terrain paint under the verge, COLOR.a = fallen petals / leaves.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/inc/toon.gdshaderinc"

uniform float half_width_m = 3.5;
uniform vec4 tarmac_color : source_color = vec4(0.34, 0.36, 0.44, 1.0);
uniform vec4 tarmac_patch : source_color = vec4(0.29, 0.31, 0.38, 1.0);
uniform vec4 gravel_color : source_color = vec4(0.76, 0.67, 0.53, 1.0);
uniform vec4 gravel_dark : source_color = vec4(0.62, 0.52, 0.40, 1.0);
uniform vec4 line_color : source_color = vec4(0.96, 0.95, 0.92, 1.0);
uniform vec4 centre_color : source_color = vec4(0.96, 0.95, 0.92, 1.0);
uniform vec4 wood_color : source_color = vec4(0.64, 0.44, 0.28, 1.0);
uniform vec4 shoulder_color : source_color = vec4(0.62, 0.58, 0.52, 1.0);
uniform vec4 litter_a : source_color = vec4(0.97, 0.78, 0.84, 1.0);
uniform vec4 litter_b : source_color = vec4(0.99, 0.88, 0.92, 1.0);
uniform vec4 litter_c : source_color = vec4(0.99, 0.88, 0.92, 1.0);
uniform float litter_density = 0.35;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float band(float x, float centre, float half_w, float aa) {
	return 1.0 - smoothstep(half_w - aa, half_w + aa, abs(x - centre));
}

float litter(vec2 p, float cell, float density, out float pick) {
	vec2 g = p / cell;
	vec2 id = floor(g);
	vec2 f = fract(g);
	float best = 0.0;
	pick = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = id + vec2(float(i), float(j));
			if (hash21(c) > density) {
				continue;
			}
			vec2 o = vec2(hash21(c + 17.1), hash21(c + 31.7));
			vec2 d = (vec2(float(i), float(j)) + o) - f;
			float a = hash21(c + 5.3) * 6.2831;
			vec2 r = vec2(cos(a) * d.x - sin(a) * d.y, sin(a) * d.x + cos(a) * d.y);
			float m = 1.0 - smoothstep(0.85, 1.0, length(r / vec2(0.26, 0.15)));
			if (m > best) {
				best = m;
				pick = hash21(c + 9.9);
			}
		}
	}
	return best;
}

void fragment() {
	float u = UV.x;
	float s = UV.y;
	float au = abs(u);
	float lat_m = u * half_width_m; // metres from the centreline
	float alat = abs(lat_m);
	float aa = max(fwidth(lat_m), 0.004) * 0.75;
	float aas = max(fwidth(s), 0.004) * 0.75;
	float gravel = clamp(UV2.x, 0.0, 1.0);
	float wood = clamp(UV2.y, 0.0, 1.0);
	vec2 wp = v_world.xz;
	vec4 gf = texture(sr_grain, wp * 0.33);   // fine aggregate
	vec4 gm = texture(sr_grain, wp * 0.06);   // medium
	vec4 gl = texture(sr_grain, vec2(lat_m * 0.02, s * 0.004)); // long, road-aligned

	// ---- tarmac
	vec3 tar = tarmac_color.rgb;
	tar *= 1.0 + (gf.r - 0.5) * 0.16 + (gm.b - 0.5) * 0.12;
	// patch repairs: rectangles aligned with the road
	vec2 pc = vec2(floor(lat_m / 1.7), floor(s / 6.5));
	float ph = hash21(pc + 3.0);
	vec2 pf = vec2(fract(lat_m / 1.7), fract(s / 6.5));
	float patch = step(0.9, ph) * step(0.08, pf.x) * step(pf.x, 0.92) * step(0.1, pf.y) * step(pf.y, 0.85 - 0.4 * hash21(pc));
	tar = mix(tar, tarmac_patch.rgb * (1.0 + (gf.g - 0.5) * 0.1), patch * (au < 0.9 ? 1.0 : 0.0));
	// polished wheel tracks, slightly lighter
	float tracks = band(alat, half_width_m * 0.48, 0.45, 0.35);
	tar *= 1.0 + tracks * 0.06;
	// markings: edge lines and 5 m / 5 m centre dashes, worn by the grain
	float wear = smoothstep(0.25, 0.45, gf.g + gm.r * 0.5 - 0.1);
	float edge_line = band(alat, half_width_m - 0.28, 0.075, aa) * wear;
	float dash = step(fract(s / 10.0), 0.5);
	float centre = band(lat_m, 0.0, 0.065, aa) * dash * wear;
	tar = mix(tar, line_color.rgb, edge_line * 0.95);
	tar = mix(tar, centre_color.rgb, centre * 0.9);

	// ---- gravel
	vec3 grv = mix(gravel_color.rgb, gravel_dark.rgb, smoothstep(0.35, 0.7, gm.b) * 0.5);
	float stones = smoothstep(0.62, 0.72, gf.r);
	grv = mix(grv, gravel_dark.rgb * 0.85, stones * 0.6);
	grv = mix(grv, gravel_color.rgb * 1.12, smoothstep(0.7, 0.8, gf.g) * 0.5);
	// ruts: darker, smoother bands where the wheels run; crown in the middle
	float ruts = band(alat, half_width_m * 0.48, 0.55, 0.3);
	grv = mix(grv, gravel_dark.rgb * 0.92, ruts * 0.45);
	float crown = (1.0 - smoothstep(0.35, 0.8, alat + (gm.g - 0.5) * 0.6)) * smoothstep(0.35, 0.6, gl.b);
	grv = mix(grv, COLOR.rgb * 0.95, crown * 0.55);

	// ---- wood deck: planks across the road
	float plank_id = floor(s / 0.42);
	float pf2 = fract(s / 0.42);
	vec3 wd = wood_color.rgb * (0.85 + 0.3 * hash21(vec2(plank_id, 1.0)));
	wd *= 1.0 + (texture(sr_grain, vec2(lat_m * 0.9, s * 0.08)).r - 0.5) * 0.25;
	float gap = 1.0 - smoothstep(0.0, aas * 2.0 + 0.02, min(pf2, 1.0 - pf2));
	wd = mix(wd, wood_color.rgb * 0.45, gap);

	vec3 road = mix(tar, grv, gravel);
	road = mix(road, wd, wood);

	// ---- shoulder and verge
	float edge_n = (gm.g - 0.5) * 0.5 + (gf.b - 0.5) * 0.15;
	float out_m = alat - half_width_m; // metres beyond the carriageway edge
	float shoulder = smoothstep(-0.05, 0.05, out_m + edge_n * 0.2);
	vec3 sh_col = mix(shoulder_color.rgb * (1.0 + (gf.r - 0.5) * 0.2), gravel_color.rgb, gravel);
	vec3 c = mix(road, sh_col, shoulder * (1.0 - wood));
	float verge = smoothstep(0.15, 0.55, out_m + edge_n);
	c = mix(c, COLOR.rgb * (1.0 + (gm.b - 0.5) * 0.12), verge * (1.0 - wood));

	// ---- litter, thicker towards the edges
	float dist = length(v_world - CAMERA_POSITION_WORLD);
	float lw = COLOR.a * mix(0.3, 1.0, smoothstep(0.3, 1.0, au));
	if (lw > 0.02 && dist < 60.0) {
		float pick;
		float m = litter(wp, 0.5, litter_density, pick);
		m *= smoothstep(0.1, 0.6, lw) * (1.0 - smoothstep(40.0, 60.0, dist));
		vec3 lc = pick < 0.45 ? litter_a.rgb : (pick < 0.8 ? litter_b.rgb : litter_c.rgb);
		c = mix(c, lc, m);
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
