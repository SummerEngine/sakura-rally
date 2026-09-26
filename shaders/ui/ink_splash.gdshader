// Radial ink splash for "GO!" / finish: a central blot bursts out with droplets and
// streak arms, then dries away from the edges. progress 0 -> 1 (burst), fade 0 -> 1 (dry).
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform vec4 ink : source_color = vec4(0.894, 0.29, 0.188, 1.0);
uniform float progress = 1.0;
uniform float fade = 0.0;
uniform float seed = 2.0;
uniform vec2 rect_size = vec2(900.0, 900.0);

void fragment() {
	vec2 p = (UV - 0.5) * 2.0;
	p.x *= rect_size.x / max(rect_size.y, 1.0);
	float r = length(p);
	float ang = atan(p.y, p.x);
	float grow = 1.0 - pow(1.0 - clamp(progress, 0.0, 1.0), 3.0);
	// Lumpy blot outline.
	float lump = ui_fbm(vec2(ang * 2.2 + seed, seed * 0.7)) * 0.35 + ui_noise(vec2(ang * 9.0, seed)) * 0.08;
	float blot_r = (0.42 + lump) * grow;
	float blot = 1.0 - smoothstep(blot_r - 0.01, blot_r + 0.005, r);
	// Streak arms: a few narrow radial spikes that shoot further.
	float arms = 0.0;
	for (int i = 0; i < 9; i++) {
		float fi = float(i);
		float a0 = ui_hash(vec2(fi, seed)) * TAU;
		float len = (0.55 + ui_hash(vec2(fi, seed + 3.0)) * 0.45) * grow;
		float da = abs(mod(ang - a0 + PI, TAU) - PI);
		float width = 0.09 * (1.0 - smoothstep(0.0, len, r)) + 0.004;
		arms = max(arms, (1.0 - smoothstep(width, width + 0.01, da * r)) * step(r, len));
	}
	// Droplets flung outward.
	float drops = 0.0;
	for (int i = 0; i < 18; i++) {
		float fi = float(i);
		float a0 = ui_hash(vec2(fi, seed + 11.0)) * TAU;
		float dist = (0.65 + ui_hash(vec2(fi, seed + 13.0)) * 0.3) * grow;
		float sz = 0.012 + ui_hash(vec2(fi, seed + 17.0)) * 0.03;
		vec2 c = vec2(cos(a0), sin(a0)) * dist;
		drops = max(drops, 1.0 - smoothstep(sz - 0.004, sz + 0.002, length(p - c)));
	}
	float a = max(max(blot, arms), drops);
	// Drying: erode by noise, strongest at the rim.
	float dry_noise = ui_fbm(p * 6.0 + seed);
	a *= smoothstep(fade * 1.3 - 0.05, fade * 1.3 + 0.05, dry_noise * 0.9 + (1.0 - r) * 0.35);
	vec3 col = ink.rgb * (0.92 + 0.12 * ui_noise(p * 20.0));
	COLOR = vec4(col, ink.a * a * COLOR.a);
}
