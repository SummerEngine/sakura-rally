// Anime colour grade over the rendered frame (below the UI layers):
// painted sun glow, soft highlight shoulder, split tone (violet darks, warm
// paper-white lights), lifted blacks, saturation, vignette, speed lines,
// letterbox, fade and film grain.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear, repeat_disable;
uniform float exposure = 1.0;
uniform vec3 shadow_tint : source_color = vec3(0.70, 0.68, 0.84);
uniform vec3 light_tint : source_color = vec3(1.0, 0.965, 0.918);
uniform float shadow_tint_amount = 0.55;
uniform float light_tint_amount = 0.8;
uniform float saturation = 1.1;
uniform float lift = 0.03;
uniform float warmth = 0.04;
uniform float vignette = 0.2;
uniform vec2 sun_uv = vec2(0.5, 0.2);
uniform float sun_vis = 0.0;
uniform vec3 sun_glow : source_color = vec3(1.0, 0.94, 0.82);
uniform float speed = 0.0;
uniform vec3 speed_color : source_color = vec3(1.0);
uniform float letterbox = 0.0;
uniform float fade = 0.0;
uniform vec3 fade_color : source_color = vec3(1.0, 0.965, 0.94);
uniform float grain_amount = 0.03;
uniform float enabled = 1.0;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 to_srgb(vec3 c) {
	return mix(c * 12.92, 1.055 * pow(max(c, vec3(0.0031308)), vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec3 src = texture(screen_tex, uv).rgb;
	if (enabled < 0.5) {
		COLOR = vec4(src, 1.0);
	} else {
		vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
		float aspect = res.x / res.y;
		vec3 c = to_linear(src) * exposure;

		vec2 sd = (uv - sun_uv) * vec2(aspect, 1.0);
		float sr = length(sd);
		c += to_linear(sun_glow) * sun_vis * (exp(-sr * 4.0) * 0.22 + exp(-sr * 16.0) * 0.35);

		float peak = max(c.r, max(c.g, c.b));
		if (peak > 0.8) {
			float p2 = 0.8 + 0.2 * (1.0 - exp(-(peak - 0.8) / 0.2));
			c *= p2 / peak;
		}

		vec3 lw = vec3(0.2126, 0.7152, 0.0722);
		float l = dot(c, lw);
		float k = smoothstep(0.02, 0.55, l);
		vec3 st = to_linear(shadow_tint);
		vec3 lt = to_linear(light_tint);
		vec3 ts = mix(vec3(1.0), st / max(dot(st, lw), 0.05), shadow_tint_amount);
		vec3 tl = mix(vec3(1.0), lt / max(dot(lt, lw), 0.05), light_tint_amount);
		c *= mix(ts, tl, k);
		c += vec3(warmth, warmth * 0.45, 0.0) * l * 0.35;
		c += lift * (1.0 - k);
		c = mix(vec3(l), c, saturation);

		vec2 cp = (uv - vec2(0.5, 0.54)) * vec2(aspect, 1.0);
		float r = length(cp);
		if (speed > 0.001) {
			float ang = atan(cp.y, cp.x);
			float a = ang / 6.2831853 * 150.0;
			float id = floor(a);
			float frame = floor(TIME * 12.0);
			float on = step(0.82, hash12(vec2(id, frame)));
			float r0 = mix(0.42, 0.75, hash12(vec2(id * 1.7, frame + 3.0))) * aspect * 0.6;
			float w = abs(fract(a) - 0.5);
			float thin = 1.0 - smoothstep(0.05, 0.05 + 0.14 * clamp((r - r0) * 2.0, 0.0, 1.0), w);
			float streak = on * thin * smoothstep(r0, r0 + 0.25, r);
			c = mix(c, to_linear(speed_color), streak * speed * 0.5);
		}

		float vr = clamp(r / (0.5 * aspect + 0.2), 0.0, 1.0);
		c *= 1.0 - vignette * pow(vr, 2.4);
		c = mix(c, to_linear(fade_color), fade);

		vec3 s = to_srgb(max(c, vec3(0.0)));
		s += (hash12(uv * res + fract(TIME * 7.0) * 64.0) - 0.5) * grain_amount;
		float lb = letterbox * 0.11;
		if (uv.y < lb || uv.y > 1.0 - lb) {
			s = vec3(0.07, 0.06, 0.09);
		}
		COLOR = vec4(s, 1.0);
	}
}
