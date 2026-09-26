// Procedural "painted anime background" landscape. Used as the map-card placeholder art
// (when no preview texture exists) and as the backdrop of the UI preview harness.
// Flat cel bands, hazy layered mountains, puffy clouds, blossom / maple canopies.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform float autumn = 0.0; // 0 = spring noon, 1 = autumn golden hour
uniform float parallax = 0.0; // -1..1 horizontal parallax offset (hover / mouse)
uniform float time_scale = 1.0;
uniform vec2 rect_size = vec2(1920.0, 1080.0);
uniform float radius = 0.0; // rounded-corner mask in pixels (0 = none)
uniform vec4 corner_mask = vec4(1.0); // which corners are rounded: tl, tr, br, bl
uniform sampler2D preview_tex : source_color, filter_linear_mipmap;
uniform bool use_texture = false;
uniform float zoom = 1.0;

float ridge(float x, float seed, float amp, float freq) {
	return (ui_fbm(vec2(x * freq + seed, seed)) - 0.5) * amp + sin(x * freq * 2.1 + seed) * amp * 0.25;
}

float cloud_puffs(vec2 p, vec2 c, float s) {
	float d = 1e3;
	d = min(d, length(p - c) - s);
	d = min(d, length(p - c - vec2(s * 1.05, s * 0.18)) - s * 0.82);
	d = min(d, length(p - c + vec2(s * 1.0, -s * 0.28)) - s * 0.7);
	d = min(d, length(p - c - vec2(s * 0.45, -s * 0.55)) - s * 0.78);
	d = min(d, length(p - c - vec2(s * 1.9, s * 0.45)) - s * 0.5);
	d = max(d, p.y - c.y - s * 0.5);
	return d;
}

vec3 painted(vec2 uv, float t) {
	float aspect = rect_size.x / max(rect_size.y, 1.0);
	vec2 p = vec2((uv.x - 0.5) * aspect, uv.y); // y down, 0 top .. 1 bottom
	p /= zoom;

	vec3 sky_top = mix(vec3(0.42, 0.66, 0.91), vec3(0.47, 0.55, 0.82), autumn);
	vec3 sky_low = mix(vec3(0.91, 0.93, 0.94), vec3(1.0, 0.8, 0.58), autumn);
	vec3 col = mix(sky_top, sky_low, smoothstep(0.0, 0.62, p.y));

	// Sun glow (autumn: low warm sun to the right).
	vec2 sun = mix(vec2(0.55 * aspect * 0.5, 0.08), vec2(0.35 * aspect * 0.5, 0.42), autumn);
	float sd = length(p - sun);
	col += mix(vec3(1.0, 0.98, 0.9), vec3(1.0, 0.72, 0.4), autumn) * (0.22 * exp(-sd * 5.0));
	col = mix(col, mix(vec3(1.0), vec3(1.0, 0.9, 0.7), autumn), smoothstep(0.075, 0.06, sd) * autumn);

	// Clouds: cel white with lavender underside band.
	vec3 cloud_lit = mix(vec3(0.97, 0.96, 0.94), vec3(1.0, 0.9, 0.8), autumn);
	vec3 cloud_sh = mix(vec3(0.8, 0.8, 0.9), vec3(0.86, 0.68, 0.7), autumn);
	for (int i = 0; i < 5; i++) {
		float fi = float(i);
		float spd = 0.004 + fi * 0.0015;
		vec2 c = vec2(fract(fi * 0.37 + t * spd + parallax * 0.01) * aspect * 1.4 - aspect * 0.7, 0.1 + fi * 0.055);
		float s = 0.05 + ui_hash(vec2(fi, 3.0)) * 0.04;
		float d = cloud_puffs(p, c, s);
		float inside = smoothstep(0.003, -0.003, d);
		float under = smoothstep(c.y + s * 0.05, c.y + s * 0.4, p.y);
		col = mix(col, mix(cloud_lit, cloud_sh, under), inside);
	}

	// Far mountains, hazy.
	vec3 haze = sky_low;
	vec3 far_c = mix(vec3(0.62, 0.66, 0.82), vec3(0.72, 0.56, 0.62), autumn);
	float h1 = 0.44 + ridge(p.x + parallax * 0.02, 1.7, 0.18, 1.3);
	col = mix(col, mix(far_c, haze, 0.45), smoothstep(h1, h1 + 0.003, p.y));
	vec3 mid_c = mix(vec3(0.42, 0.58, 0.62), vec3(0.64, 0.42, 0.4), autumn);
	float h2 = 0.54 + ridge(p.x + parallax * 0.05, 5.3, 0.16, 1.8);
	col = mix(col, mix(mid_c, haze, 0.28), smoothstep(h2, h2 + 0.003, p.y));

	// Near hill with canopy blobs.
	vec3 grass = mix(vec3(0.64, 0.81, 0.45), vec3(0.8, 0.62, 0.3), autumn);
	vec3 grass_sh = mix(vec3(0.43, 0.65, 0.33), vec3(0.62, 0.4, 0.3), autumn);
	float h3 = 0.68 + ridge(p.x + parallax * 0.1, 9.1, 0.12, 2.4) - smoothstep(-0.2, -0.9, p.x) * 0.3;
	float hill = smoothstep(h3, h3 + 0.003, p.y);
	float band = step(0.5, ui_noise(vec2(p.x * 6.0, p.y * 3.0)) + (p.y - h3) * 2.0);
	col = mix(col, mix(grass_sh, grass, band), hill);

	vec3 bloom = mix(vec3(0.97, 0.75, 0.82), vec3(0.91, 0.36, 0.24), autumn);
	vec3 bloom_hi = mix(vec3(0.99, 0.87, 0.9), vec3(0.96, 0.6, 0.29), autumn);
	vec3 bloom_sh = mix(vec3(0.85, 0.55, 0.68), vec3(0.7, 0.24, 0.26), autumn);
	for (int i = 0; i < 9; i++) {
		float fi = float(i);
		float x = (ui_hash(vec2(fi, 11.0)) - 0.5) * aspect * 1.1 + parallax * 0.14;
		float base_y = 0.68 + ridge(x, 9.1, 0.12, 2.4) - smoothstep(-0.2, -0.9, x) * 0.3;
		float s = 0.05 + ui_hash(vec2(fi, 21.0)) * 0.06;
		vec2 c = vec2(x + sin(t * 0.6 + fi) * 0.002, base_y - s * 0.6);
		float trunk = step(abs(p.x - x), s * 0.08) * step(c.y, p.y) * step(p.y, base_y + 0.01);
		col = mix(col, vec3(0.42, 0.3, 0.28), trunk);
		float d = length((p - c) * vec2(1.0, 1.25)) - s;
		d = min(d, length((p - c - vec2(s * 0.7, s * 0.25)) * vec2(1.0, 1.3)) - s * 0.7);
		d = min(d, length((p - c + vec2(s * 0.75, -s * 0.2)) * vec2(1.0, 1.3)) - s * 0.65);
		float inside = smoothstep(0.003, -0.003, d);
		float lit = step(0.0, dot(normalize(p - c + vec2(0.0001)), normalize(vec2(-0.4, -1.0))));
		vec3 bc = mix(bloom_sh, mix(bloom, bloom_hi, step(0.35, dot(normalize(p - c + vec2(0.0001)), normalize(vec2(-0.5, -1.0))))), lit);
		col = mix(col, bc, inside);
	}

	// Road ribbon.
	float road_x = 0.18 * aspect * 0.5 + sin(p.y * 6.0) * 0.04 + parallax * 0.2;
	float road_w = mix(0.0, 0.45, smoothstep(0.72, 1.0, p.y));
	float road = step(abs(p.x - road_x), road_w) * step(0.72, p.y);
	col = mix(col, vec3(0.37, 0.39, 0.5), road);
	float line = step(abs(abs(p.x - road_x) - road_w * 0.85), road_w * 0.03) * road;
	col = mix(col, vec3(0.96, 0.95, 0.92), line);

	// Aerial haze towards the horizon.
	col = mix(col, haze, smoothstep(0.75, 0.4, p.y) * 0.12);
	return col;
}

void fragment() {
	vec3 col;
	if (use_texture) {
		vec2 uv = (UV - 0.5) / zoom + 0.5 + vec2(parallax * 0.01, 0.0);
		col = texture(preview_tex, uv).rgb;
	} else {
		col = painted(UV, TIME * time_scale);
	}
	float a = 1.0;
	if (radius > 0.0) {
		vec2 px = UV * rect_size;
		vec2 h = rect_size * 0.5;
		vec2 q = px - h;
		float r = q.x < 0.0 ? (q.y < 0.0 ? corner_mask.x : corner_mask.w) : (q.y < 0.0 ? corner_mask.y : corner_mask.z);
		float d = ui_sd_round_box(q, h, radius * r);
		a = clamp(0.5 - d, 0.0, 1.0);
	}
	COLOR = vec4(col, a * COLOR.a);
}
