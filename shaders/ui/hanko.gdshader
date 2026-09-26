// Hanko (red seal) ink texture: uneven stamp pressure, speckled voids and a slightly
// eroded edge. Applied to the UIHanko control, which draws a solid seal with knocked-out
// (paper coloured) kanji; this shader only modulates alpha.
shader_type canvas_item;

#include "res://shaders/ui/ui_common.gdshaderinc"

uniform float seed = 3.0;
uniform float pressure = 1.0; // 0..1, fades speckles in as the stamp lands
uniform vec2 rect_size = vec2(160.0);

varying vec2 local;

void vertex() {
	local = VERTEX;
}

void fragment() {
	vec2 uv = local / max(rect_size, vec2(1.0));
	float grain = ui_noise(local * 0.45 + seed * 13.0);
	float blotch = ui_fbm(uv * 3.5 + seed);
	float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	float erode = smoothstep(0.0, 0.07, edge + (blotch - 0.5) * 0.05);
	float voids = smoothstep(0.18, 0.3, grain * 0.6 + blotch * 0.7 - 0.12 + (1.0 - pressure) * -0.3);
	float a = mix(1.0, voids, 0.35) * mix(0.82, 1.0, blotch) * mix(1.0, erode, 0.7);
	COLOR.a *= clamp(a, 0.0, 1.0);
}
