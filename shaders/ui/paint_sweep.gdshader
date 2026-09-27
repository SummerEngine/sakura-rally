// Garage livery change: the toon car paint (shaders/toon.gdshader with the same cel lighting)
// with a brush front that sweeps nose to tail, leaving the new colour behind it. A thin ink
// line rides the ragged front and a wet sheen trails it. MenuStage swaps a paint material to
// this shader for the length of the sweep and back to the toon shader afterwards; the
// material keeps every other parameter.
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/inc/toon.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0); // the new colour
uniform vec4 albedo_from : source_color = vec4(1.0); // the colour being painted over
uniform vec3 sweep_origin = vec3(0.0); // car origin (world)
uniform vec3 sweep_axis = vec3(0.0, 0.0, 1.0); // nose to tail (world, unit)
uniform float sweep_front = -3.0; // metres along the axis
uniform vec4 ink : source_color = vec4(0.165, 0.133, 0.208, 1.0);

varying vec3 v_world;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 rel = v_world - sweep_origin;
	float d = dot(rel, sweep_axis);
	// Ragged brush front: bristle streaks across the body plus a slow wobble.
	vec3 side = normalize(cross(sweep_axis, vec3(0.0, 1.0, 0.0)));
	vec2 q = vec2(dot(rel, side), rel.y);
	float front = sweep_front + (noise(q * vec2(9.0, 14.0)) - 0.5) * 0.16 + (noise(q * 1.7) - 0.5) * 0.3;
	float behind = front - d; // > 0 where the new paint is
	vec3 c = mix(albedo_from.rgb, albedo.rgb, smoothstep(-0.01, 0.01, behind));
	float wet = smoothstep(0.45, 0.0, behind) * step(0.0, behind);
	c = mix(c, min(c * 1.18 + 0.06, vec3(1.0)), wet * 0.7);
	float line = 1.0 - smoothstep(0.012, 0.035, abs(behind));
	c = mix(c, ink.rgb, line * 0.9);
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
