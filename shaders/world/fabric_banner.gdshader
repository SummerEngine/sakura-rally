// Fabric checkpoint banner: a cloth strip tied between two inflatable uprights.
// The wave is computed per vertex (ends pinned, travelling ripples scaled by the global
// wind), with analytic normals so the cel bands ride the folds. A passing car adds a bulge
// in its direction of travel and ripples running out from the middle (`billow`, set per
// gate by FabricGate). The pattern is painted: cream cloth, blossom-pink hems, chequered
// ends, a row of sakura crests, and an ink hem line so the edge reads like the drawn props.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

#include "res://shaders/inc/toon.gdshaderinc"

uniform vec4 cloth : source_color = vec4(0.961, 0.949, 0.918, 1.0);
uniform vec4 hem : source_color = vec4(0.902, 0.541, 0.659, 1.0);
uniform vec4 crest : source_color = vec4(0.949, 0.651, 0.745, 1.0);
uniform vec4 crest_core : source_color = vec4(0.949, 0.773, 0.322, 1.0);
uniform vec4 ink_color : source_color = vec4(0.165, 0.133, 0.208, 1.0);
uniform float banner_height = 1.15;
uniform float grain_amount = 0.07;

instance uniform float span_m = 13.0;
instance uniform float phase = 0.0;
instance uniform float billow = 0.0;
instance uniform float billow_age = 100.0;
instance uniform float billow_dir = 1.0;
// Upright top offsets in gate space: left (x, z), right (x, z).
instance uniform vec4 lean = vec4(0.0);

varying vec3 v_world;
varying vec2 v_uv;

// Out-of-plane displacement (m) of the cloth at (u across, v up).
float cloth_z(vec2 uv) {
	float u = uv.x;
	float v = uv.y;
	float pin = sin(PI * u);
	float t = TIME + phase;
	float wind = 0.35 + 0.65 * clamp(sr_wind.z, 0.0, 1.5);
	float gust = 0.7 + 0.3 * sin(t * 0.61 + phase);
	float loose = 0.55 + 0.45 * (1.0 - v); // the bottom hem flaps more than the tied top
	float w = 0.09 * sin(u * 11.0 - t * 2.4 + v * 1.3)
			+ 0.045 * sin(u * 23.0 - t * 3.9 + v * 2.6)
			+ 0.03 * sin(u * 5.0 + t * 1.3);
	float z = w * pin * loose * wind * gust;
	float env = billow * exp(-1.3 * billow_age);
	if (env > 0.001) {
		float rise = smoothstep(0.0, 0.18, billow_age);
		float bulge = billow_dir * 0.62 * rise * pin * (0.45 + 0.55 * (1.0 - v));
		float d = abs(u - 0.5) * span_m;
		float ripple = 0.26 * sin(d * 1.5 - billow_age * 11.0 + v * 1.8) * smoothstep(billow_age * 14.0 + 1.0, billow_age * 14.0 - 2.0, d);
		z += env * (bulge + ripple * pin);
	}
	return z;
}

void vertex() {
	vec2 uv = UV;
	float z = cloth_z(uv);
	float e = 0.01;
	float dzu = (cloth_z(uv + vec2(e, 0.0)) - cloth_z(uv - vec2(e, 0.0))) / (2.0 * e);
	float dzv = (cloth_z(uv + vec2(0.0, e)) - cloth_z(uv - vec2(0.0, e))) / (2.0 * e);
	// dP/du = (span, 0, dzu), dP/dv = (0, height, dzv): normal = cross
	vec3 n = vec3(-dzu * banner_height, -dzv * span_m, span_m * banner_height);
	NORMAL = normalize(n);
	// a light sag between the ties, a little more when the cloth is thrown about
	float sag = 0.14 * sin(PI * uv.x);
	vec2 l = mix(lean.xy, lean.zw, uv.x);
	VERTEX += vec3(l.x, -sag, z + l.y);
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_uv = uv;
}

// Five-petal sakura crest, radius ~1 in p units: 1 inside the petals, 0 outside.
float sakura(vec2 p, out float core) {
	float r = length(p);
	float a = atan(p.y, p.x) + PI * 0.5;
	float k = abs(cos(a * 2.5));
	float notch = smoothstep(0.96, 1.0, k) * 0.18;
	float edge = 0.62 + 0.38 * pow(k, 0.6) - notch;
	core = step(r, 0.22);
	return step(r, edge);
}

void fragment() {
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	vec2 m = vec2(v_uv.x * span_m, v_uv.y * banner_height); // metres across / up
	vec3 c = cloth.rgb;
	float hem_w = banner_height * 0.17;
	bool in_hem = m.y < hem_w || m.y > banner_height - hem_w;
	if (in_hem) {
		c = hem.rgb;
	} else {
		// chequered ends: the rally checkpoint mark
		float end = min(m.x, span_m - m.x);
		if (end < 1.35) {
			float sq = (banner_height - 2.0 * hem_w) / 3.0;
			vec2 cell = floor(vec2(m.x, m.y - hem_w) / sq);
			if (mod(cell.x + cell.y, 2.0) > 0.5) {
				c = ink_color.rgb;
			}
		} else {
			// sakura crests along the middle band, every 1.6 m
			float pitch = 1.6;
			float inner = span_m - 2.0 * 1.35;
			float n = max(floor(inner / pitch), 1.0);
			float step_m = inner / n;
			float x = mod(m.x - 1.35, step_m) - step_m * 0.5;
			vec2 p = vec2(x, m.y - banner_height * 0.5) / ((banner_height - 2.0 * hem_w) * 0.42);
			float core;
			float core_unused;
			float outline = sakura(p, core_unused);
			float fill = sakura(p * 1.18, core);
			c = mix(c, ink_color.rgb, outline * (1.0 - fill));
			c = mix(c, crest.rgb, fill);
			c = mix(c, crest_core.rgb, core);
		}
	}
	// ink hem lines, top and bottom, and the tie ends
	float line = 0.028;
	if (m.y < line || m.y > banner_height - line || m.x < line * 1.5 || m.x > span_m - line * 1.5
			|| abs(m.y - hem_w) < line * 0.5 || abs(m.y - (banner_height - hem_w)) < line * 0.5) {
		c = ink_color.rgb;
	}
	vec4 g = texture(sr_grain, v_world.xz * 0.035 + v_world.y * 0.03);
	c *= 1.0 + (g.r - 0.5) * grain_amount + (g.g - 0.5) * grain_amount * 0.8;
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
