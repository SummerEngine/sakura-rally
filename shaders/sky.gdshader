// Painted sky: a three-stop gradient with a faint airbrushed band step,
// a sun disc with a wide halo and a warm horizon band on the sun's side.
shader_type sky;
render_mode use_debanding;

uniform vec3 sky_top : source_color = vec3(0.31, 0.56, 0.85);
uniform vec3 sky_mid : source_color = vec3(0.64, 0.82, 0.94);
uniform vec3 sky_haze : source_color = vec3(0.93, 0.95, 0.94);
uniform vec3 ground : source_color = vec3(0.60, 0.68, 0.66);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform float sun_size = 0.99935;
uniform float halo = 1.0;
uniform float horizon_band = 0.22;
uniform float band_steps = 24.0;
uniform float band_mix = 0.28;
uniform float exposure = 1.0;

void sky() {
	vec3 d = EYEDIR;
	float h = d.y;
	float t = clamp(h * 1.25 + 0.015, 0.0, 1.0);
	float q = floor(t * band_steps) / band_steps;
	t = mix(t, q, band_mix);
	vec3 c = mix(sky_haze, sky_mid, smoothstep(0.0, 0.3, t));
	c = mix(c, sky_top, smoothstep(0.24, 1.0, t));

	vec3 sun_dir = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 0.5, -0.8);
	float sd = dot(d, sun_dir);
	float hal = pow(max(sd, 0.0), 6.0) * 0.3 + pow(max(sd, 0.0), 48.0) * 0.45;
	c += sun_color * hal * halo;
	c += sun_color * pow(max(sd * 0.5 + 0.5, 0.0), 3.0) * exp(-abs(h) * 9.0) * horizon_band * halo;
	c = mix(c, ground, smoothstep(0.0, -0.2, h));

	if (!AT_CUBEMAP_PASS) {
		float disc = smoothstep(sun_size - 0.00025, sun_size + 0.00015, sd);
		c = mix(c, sun_color * 2.4, disc * smoothstep(-0.04, 0.02, h));
	}
	COLOR = c * exposure;
}
