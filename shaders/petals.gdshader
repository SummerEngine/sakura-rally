// Falling petal / leaf card: flutters (rotates around its own axis so it flashes
// between face-on and edge-on), tinted by the particle colour, shaded by the
// texture's baked shade (R) and cut out by its alpha.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque, shadows_disabled, fog_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;

varying float v_flutter;

void vertex() {
	// Billboard with the particle rotation applied, then squash by a flutter phase.
	float ph = INSTANCE_CUSTOM.x * 6.2831 + float(INSTANCE_ID) * 1.37;
	float f = sin(TIME * (3.0 + fract(float(INSTANCE_ID) * 0.37) * 2.5) + ph);
	v_flutter = f;
	vec3 local = VERTEX;
	local.x *= mix(0.25, 1.0, abs(f));
	mat4 inst = MODEL_MATRIX;
	vec3 inst_pos = inst[3].xyz;
	float s = length(inst[0].xyz);
	mat3 cam_basis = mat3(INV_VIEW_MATRIX[0].xyz, INV_VIEW_MATRIX[1].xyz, INV_VIEW_MATRIX[2].xyz);
	float a = INSTANCE_CUSTOM.y * 6.2831 + TIME * 0.5;
	mat2 rot = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a)));
	local.xy = rot * local.xy;
	vec3 world = inst_pos + cam_basis * (local * s);
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	vec4 t = texture(tex, UV);
	if (t.a < 0.5) {
		discard;
	}
	// back side a touch darker so the flutter reads
	float side = mix(0.82, 1.0, step(0.0, v_flutter));
	ALBEDO = COLOR.rgb * mix(0.78, 1.0, t.r) * side;
}
