// Generic cel material: albedo colour x vertex colour x optional texture,
// optional wind sway, emission, per-instance tint (MultiMesh custom data) and
// spectator motion (shaders/inc/crowd.gdshaderinc).
shader_type spatial;
render_mode cull_back, depth_draw_opaque;

#include "res://shaders/inc/toon.gdshaderinc"
#include "res://shaders/inc/crowd.gdshaderinc"

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable, hint_default_white;
uniform bool use_vertex_color = false;
uniform bool use_texture = false;
// Emission (lanterns, lights). Scales up at dusk with sr_glow.
uniform vec4 emission : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float emission_energy = 0.0;
// Wind sway: amount 0 = static. Weight rises from sway_start to sway_end (object-space Y).
uniform float sway_amount = 0.0;
uniform float sway_start = 0.5;
uniform float sway_end = 4.0;
// Painterly grain modulation of the albedo (0 = flat).
uniform float grain_amount : hint_range(0.0, 1.0) = 0.12;
uniform float grain_scale = 0.35;
// Instance tint: INSTANCE_CUSTOM.rgb multiplies albedo when > 0 (MultiMesh with custom data).
uniform bool use_instance_tint = false;
// Glossy reflection band (glass).
uniform float gloss_band = 0.0;
uniform vec4 gloss_color : source_color = vec4(0.85, 0.9, 1.0, 1.0);

varying vec3 v_world;
varying vec3 v_tint;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	if (sway_amount > 0.0) {
		float w = smoothstep(sway_start, sway_end, VERTEX.y);
		VERTEX += sr_sway(v_world, w, sway_amount);
	}
	if (crowd_motion > 0.0) {
		VERTEX = sr_crowd(VERTEX, COLOR.a, MODEL_MATRIX, INSTANCE_CUSTOM, TIME);
	}
	v_tint = vec3(1.0);
	if (use_instance_tint) {
		v_tint = INSTANCE_CUSTOM.rgb;
	}
}

void fragment() {
	vec3 c = albedo.rgb * v_tint;
	if (use_vertex_color) {
		c *= COLOR.rgb;
	}
	if (use_texture) {
		c *= texture(albedo_texture, UV).rgb;
	}
	if (grain_amount > 0.0) {
		vec4 g = texture(sr_grain, v_world.xz * grain_scale * 0.1 + v_world.y * 0.03);
		c *= 1.0 + (g.r - 0.5) * grain_amount + (g.g - 0.5) * grain_amount * 0.8;
	}
	ALBEDO = c;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	if (gloss_band > 0.0) {
		// A painted reflection stripe across glass, fixed in view space.
		vec3 r = reflect(-VIEW, NORMAL);
		float band = smoothstep(0.05, 0.12, r.y) * (1.0 - smoothstep(0.28, 0.36, r.y));
		float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.0);
		EMISSION = gloss_color.rgb * (band * gloss_band + fres * 0.25 * gloss_band);
	}
	if (emission_energy > 0.0) {
		EMISSION += emission.rgb * emission_energy * (1.0 + sr_glow * 2.5);
	}
}
