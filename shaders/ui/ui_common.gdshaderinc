// Shared helpers for the UI shaders: hashes, value noise, fbm and SDFs.

const vec3 UI_INK = vec3(0.165, 0.133, 0.208);

float ui_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float ui_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = ui_hash(i);
	float b = ui_hash(i + vec2(1.0, 0.0));
	float c = ui_hash(i + vec2(0.0, 1.0));
	float d = ui_hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float ui_fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * ui_noise(p);
		p = p * 2.03 + vec2(17.1, 9.7);
		a *= 0.5;
	}
	return v;
}

float ui_sd_round_box(vec2 p, vec2 half_size, float r) {
	r = min(r, min(half_size.x, half_size.y));
	vec2 q = abs(p) - half_size + r;
	return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float ui_sd_segment(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
	return length(pa - ba * h);
}

// Washi paper grain: fine speckle plus long soft fibres.
float ui_washi(vec2 px) {
	float speck = ui_noise(px * 0.85);
	float fibre = ui_noise(vec2(px.x * 0.06 + px.y * 0.02, px.y * 0.9));
	float cloud = ui_noise(px * 0.012);
	return speck * 0.45 + fibre * 0.35 + cloud * 0.2;
}
