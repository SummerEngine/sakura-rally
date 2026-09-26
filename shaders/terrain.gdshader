// Painted ground: baked vertex colour (grass, forest floor, fields, rock, verges,
// shores) broken up with world-space brush blotches, plus fallen petals or leaves
// scattered where the baked alpha says the canopy is overhead.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/inc/toon.gdshaderinc"

uniform float blotch_amount = 0.10;
uniform float fine_amount = 0.05;
// Litter: season palette. Petals use colour A/B, maple leaves use A/B/C.
uniform vec4 litter_a : source_color = vec4(0.97, 0.78, 0.84, 1.0);
uniform vec4 litter_b : source_color = vec4(0.99, 0.88, 0.92, 1.0);
uniform vec4 litter_c : source_color = vec4(0.99, 0.88, 0.92, 1.0);
uniform float litter_density = 0.55;
uniform float litter_cell = 0.55;
// Brush-stroke hue drift toward warm / cool across big areas.
uniform vec4 warm_shift : source_color = vec4(1.04, 1.0, 0.9, 1.0);
uniform vec4 cool_shift : source_color = vec4(0.92, 0.98, 1.05, 1.0);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Distance-field petal in a jittered cell: an ellipse with a random heading.
float litter(vec2 p, float cell, out float pick) {
	vec2 g = p / cell;
	vec2 id = floor(g);
	vec2 f = fract(g);
	float best = 0.0;
	pick = 0.0;
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 c = id + vec2(float(i), float(j));
			float h = hash21(c);
			if (h > litter_density) {
				continue;
			}
			vec2 o = vec2(hash21(c + 17.1), hash21(c + 31.7));
			vec2 d = (vec2(float(i), float(j)) + o) - f;
			float a = hash21(c + 5.3) * 6.2831;
			vec2 r = vec2(cos(a) * d.x - sin(a) * d.y, sin(a) * d.x + cos(a) * d.y);
			float e = length(r / vec2(0.26, 0.15));
			float m = 1.0 - smoothstep(0.85, 1.0, e);
			if (m > best) {
				best = m;
				pick = hash21(c + 9.9);
			}
		}
	}
	return best;
}

void fragment() {
	vec3 c = COLOR.rgb;
	vec2 wp = v_world.xz;
	vec4 g1 = texture(sr_grain, wp * 0.0035);
	vec4 g2 = texture(sr_grain, wp * 0.021);
	vec4 g3 = texture(sr_grain, wp * 0.11);
	// big brush areas drift warm/cool, medium blotches vary value
	c *= mix(cool_shift.rgb, warm_shift.rgb, smoothstep(0.3, 0.7, g1.b));
	c *= 1.0 + (g2.b - 0.5) * 2.0 * blotch_amount;
	c *= 1.0 + (g3.r - 0.5) * 2.0 * fine_amount;

	float lw = COLOR.a;
	float dist = length(v_world - CAMERA_POSITION_WORLD);
	if (lw > 0.02 && dist < 70.0) {
		float pick;
		float m = litter(wp + (g3.g - 0.5) * 0.3, litter_cell, pick);
		m *= smoothstep(0.1, 0.6, lw) * (1.0 - smoothstep(45.0, 70.0, dist));
		vec3 lc = pick < 0.45 ? litter_a.rgb : (pick < 0.8 ? litter_b.rgb : litter_c.rgb);
		c = mix(c, lc, m);
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
