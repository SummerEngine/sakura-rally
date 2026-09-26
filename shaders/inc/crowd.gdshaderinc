// Spectator idle and cheer motion (tools/blender/props/people.py, scripts/world/crowd.gd).
//
// Each person is a MultiMesh instance: INSTANCE_CUSTOM.a is its phase (0..1, it also sets
// the tempo), the vertex colour alpha weights the arms (0 on the body, up to the pose's arm
// energy at the hands and whatever they hold). Arms open and close (claps, pumps, waves) and
// bounce; the body sways a little. Within `crowd_focus.w` metres of `crowd_focus.xyz` (Crowd
// puts the player car there) people cheer harder and hop.
//
// Included by shaders/toon.gdshader; `crowd_motion` 0 (every other material) costs one
// uniform branch.

uniform float crowd_motion = 0.0;
uniform vec4 crowd_focus = vec4(0.0, -100000.0, 0.0, 45.0);

vec3 sr_crowd(vec3 v, float arm, mat4 model, vec4 custom, float time) {
	vec3 origin = model[3].xyz;
	float ph = custom.a * 6.2832;
	float near = 1.0 - smoothstep(crowd_focus.w * 0.3, crowd_focus.w, distance(origin, crowd_focus.xyz));
	float energy = crowd_motion * (0.3 + 0.7 * near);
	float rate = 3.4 + fract(custom.a * 13.7) * 1.8 + near * 2.0;
	float s = sin(time * rate + ph);
	float c2 = sin(time * rate * 2.0 + ph * 1.7);
	// arms: open and close about the body's centre line, and bounce
	float side = v.x >= 0.0 ? 1.0 : -1.0;
	v.x += side * arm * s * 0.07 * energy;
	v.y += arm * c2 * 0.06 * energy;
	// body: a slow sway growing with height, and hops when the car is near
	float h = clamp(v.y * 0.6, 0.0, 1.0);
	v.x += sin(time * 0.9 + ph * 1.3) * 0.025 * h * crowd_motion;
	v.y += pow(max(s, 0.0), 2.0) * 0.1 * near * crowd_motion;
	return v;
}
