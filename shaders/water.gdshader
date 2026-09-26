// Painted water: depth-tinted body read from the depth buffer, a flat sky
// reflection band with fresnel, crisp white glints where painted ripples face the
// sun, and a soft foam line at the shore. `flow` > 0 scrolls ripples along UV.y
// (river); lakes drift slowly.
shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, blend_mix, specular_disabled, shadows_disabled;

#include "res://shaders/inc/toon.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_linear, repeat_disable;
uniform vec4 shallow : source_color = vec4(0.56, 0.82, 0.81, 1.0);
uniform vec4 deep : source_color = vec4(0.25, 0.53, 0.69, 1.0);
uniform vec4 sky_reflect : source_color = vec4(0.80, 0.90, 0.97, 1.0);
uniform vec4 foam_color : source_color = vec4(0.97, 0.98, 1.0, 1.0);
uniform float depth_fade = 3.2;
uniform float flow = 0.0;
uniform float flow_speed = 0.9;
uniform float clarity = 0.55;
uniform vec3 sun_dir = vec3(0.45, 0.7, 0.3); // toward the sun, set by the map loader
uniform vec4 glint_color : source_color = vec4(1.0, 0.97, 0.9, 1.0);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 wp = v_world.xz;
	vec2 fuv = flow > 0.5 ? vec2(UV.x * 3.0, UV.y * 0.12 - TIME * flow_speed * 0.12) : wp * 0.06 + vec2(TIME * 0.01, TIME * 0.004);
	float r1 = texture(sr_grain, fuv * vec2(1.0, 0.5)).r;
	float r2 = texture(sr_grain, fuv * 1.7 + vec2(0.37, TIME * 0.02)).g;
	float ripple = r1 * 0.6 + r2 * 0.4;

	// water depth below the surface from the opaque depth buffer
	float d = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene_z = -vp.z / vp.w;
	float surf_z = -VERTEX.z;
	float wdepth = max(scene_z - surf_z, 0.0);
	float k = 1.0 - exp(-wdepth / depth_fade);
	vec3 body = mix(shallow.rgb, deep.rgb, smoothstep(0.1, 0.9, k));
	// painted bands of the body colour
	body = mix(body, body * 1.08, step(0.55, ripple) * 0.5);

	vec3 n = normalize(vec3((r1 - 0.5) * 0.12, 1.0, (r2 - 0.5) * 0.12));
	vec3 v = normalize(CAMERA_POSITION_WORLD - v_world);
	float fres = 0.18 + 0.82 * pow(1.0 - max(dot(n, v), 0.0), 4.0);
	vec3 c = mix(body, sky_reflect.rgb, fres * 0.75);

	float foam = 1.0 - smoothstep(0.0, 0.35 + ripple * 0.35, wdepth);
	foam *= step(0.35, ripple + 0.2);
	if (flow > 0.5) {
		foam = max(foam, smoothstep(0.72, 0.78, ripple) * 0.55 * smoothstep(0.6, 1.0, abs(UV.x)));
	}
	c = mix(c, foam_color.rgb, foam * 0.85);

	ALBEDO = c;
	ROUGHNESS = 1.0;
	ALPHA = clamp(mix(clarity, 1.0, k) + foam, 0.0, 1.0);
	// glints: crisp flecks where ripples mirror the sun
	vec3 rv = reflect(-v, n);
	float gl = pow(max(dot(rv, normalize(sun_dir)), 0.0), 160.0) * smoothstep(0.52, 0.72, ripple);
	EMISSION = glint_color.rgb * step(0.3, gl) * 2.2;
}
