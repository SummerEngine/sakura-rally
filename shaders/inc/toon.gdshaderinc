// Cel lighting shared by every lit surface in Sakura Rally.
//
// Direct sun light is quantised into flat bands. The shade side is hue-shifted
// toward the global violet tint instead of simply darkened, and cast shadows
// push the surface into the darkest band rather than cutting the light to
// black - so shadows read as painted colour, the way anime backgrounds do.
//
// Include AFTER `shader_type spatial;` and the render_mode line. The including
// shader provides vertex()/fragment(); this file provides light().

global uniform vec4 sr_shade_tint;
global uniform vec4 sr_rim_color;
global uniform vec4 sr_wind;
global uniform float sr_glow;
global uniform sampler2D sr_grain : filter_linear_mipmap, repeat_enable;

group_uniforms cel;
// Band boundaries in half-lambert space (N.L * 0.5 + 0.5) and their light levels.
uniform vec3 ramp_edges = vec3(0.47, 0.62, 2.0);
uniform vec3 ramp_values = vec3(0.50, 0.78, 1.0);
uniform float ramp_soft : hint_range(0.0, 0.1) = 0.012;
// 0 = ignore cast shadows (blossom), 1 = full painted shadow.
uniform float receive_shadow : hint_range(0.0, 1.0) = 1.0;
// How strongly the shade side is pushed toward the global tint.
uniform float shade_tint_amount : hint_range(0.0, 1.5) = 1.0;
// Sun-side rim band for hero objects.
uniform float rim_strength : hint_range(0.0, 2.0) = 0.0;
// Toon specular spot (car paint, glass, water).
uniform float spec_strength : hint_range(0.0, 4.0) = 0.0;
uniform float spec_size : hint_range(0.5, 1.0) = 0.965;
// Light that wraps into the shade side (soft, translucent masses).
uniform float wrap_light : hint_range(0.0, 1.0) = 0.0;
group_uniforms;

float sr_luma(vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float sr_ramp(float x) {
	float b1 = smoothstep(ramp_edges.x - ramp_soft, ramp_edges.x + ramp_soft, x);
	float b2 = smoothstep(ramp_edges.y - ramp_soft, ramp_edges.y + ramp_soft, x);
	return mix(mix(ramp_values.x, ramp_values.y, b1), ramp_values.z, b2);
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float hl = clamp(ndl * (0.5 - wrap_light * 0.25) + 0.5 + wrap_light * 0.25, 0.0, 1.0);
	float band = sr_ramp(hl);
	float low = ramp_values.x;
	// Crisp painted shadow edge.
	float sh = smoothstep(0.30, 0.70, ATTENUATION);
	sh = mix(1.0, sh, receive_shadow);
	band = mix(low, band, sh);
	float t = clamp((band - low) / max(1.0 - low, 0.01), 0.0, 1.0);
	vec3 tint = sr_shade_tint.rgb / max(sr_luma(sr_shade_tint.rgb), 0.05);
	tint = mix(vec3(1.0), tint, 0.5 * shade_tint_amount * sr_shade_tint.a);
	vec3 irradiance = band * mix(tint, vec3(1.0), t);
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += irradiance * LIGHT_COLOR / PI;
	} else {
		// Point/spot lights (lanterns): soft falloff, no banding.
		DIFFUSE_LIGHT += clamp(ndl * 0.5 + 0.5, 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
	}

	if (rim_strength > 0.0 && LIGHT_IS_DIRECTIONAL) {
		float facing = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
		float rim_band = smoothstep(0.56, 0.64, facing);
		float to_sun = smoothstep(-0.2, 0.35, ndl);
		DIFFUSE_LIGHT += sr_rim_color.rgb * rim_band * to_sun * sh * rim_strength * LIGHT_COLOR / PI;
	}

	if (spec_strength > 0.0 && LIGHT_IS_DIRECTIONAL) {
		vec3 h = normalize(LIGHT + VIEW);
		float s = smoothstep(spec_size - 0.004, spec_size + 0.004, dot(NORMAL, h));
		SPECULAR_LIGHT += s * sh * spec_strength * LIGHT_COLOR / PI;
	}
}

// Wind sway offset in object space. weight 0..1 (0 = trunk base).
vec3 sr_sway(vec3 world_pos, float weight, float amount) {
	float ph = dot(world_pos.xz, vec2(0.11, 0.07));
	float gust = 0.65 + 0.35 * sin(TIME * sr_wind.w + ph * 0.2);
	vec3 o;
	o.x = sin(TIME * 1.7 + ph) * sr_wind.x;
	o.z = cos(TIME * 1.3 + ph * 1.4) * sr_wind.y;
	o.y = sin(TIME * 2.6 + ph * 2.1) * 0.2;
	return o * weight * amount * sr_wind.z * gust * 0.16;
}
