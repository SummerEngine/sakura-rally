// Far mountain rings. Cel lit, then hazed toward the sky colour by distance and
// low altitude; the haze goes in EMISSION so it is independent of lighting and
// ridges fade into the sky in flat layers like a painted backdrop.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, fog_disabled;

#include "res://shaders/inc/toon.gdshaderinc"

uniform vec4 haze : source_color = vec4(0.91, 0.94, 0.94, 1.0);
uniform vec4 haze_sun : source_color = vec4(1.0, 0.93, 0.82, 1.0);
uniform vec3 sun_dir = vec3(0.45, 0.7, 0.3);
uniform float near_dist = 700.0;
uniform float far_dist = 5200.0;
uniform float min_haze = 0.28;
uniform float max_haze = 0.92;
uniform float valley_mist = 0.35;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 to = v_world - CAMERA_POSITION_WORLD;
	float dist = length(to.xz);
	float t = mix(min_haze, max_haze, smoothstep(near_dist, far_dist, dist));
	t = max(t, valley_mist * (1.0 - smoothstep(0.0, 260.0, v_world.y)));
	vec3 dir = normalize(to);
	float sunward = pow(max(dot(normalize(vec3(dir.x, 0.0, dir.z)), normalize(vec3(sun_dir.x, 0.0, sun_dir.z))), 0.0), 3.0);
	vec3 h = mix(haze.rgb, haze_sun.rgb, sunward * 0.6);
	// quantise the haze a little so distant ridges read as flat layers
	t = mix(t, floor(t * 6.0 + 0.5) / 6.0, 0.35);
	ALBEDO = COLOR.rgb * (1.0 - t);
	EMISSION = h * t;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
