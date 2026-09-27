// Seasons across the world. `sr_season` is the pack's season grid (R spring, G summer,
// B autumn weights; MapWorld uploads it), `sr_season_rect` its rect on the ground
// (origin x, origin z, size x, size z in metres). Fallen litter on the ground and the road
// takes its density and colours from the season under the fragment: each litter cell picks
// one season by the weights, so a stretch between two seasons carries petals and leaves side
// by side instead of a muddy mix of the two.

global uniform sampler2D sr_season : filter_linear, repeat_disable;
global uniform vec4 sr_season_rect;

// Litter density per season (spring, summer, autumn) on the terrain and on the road.
const vec3 SR_LITTER_TERRAIN = vec3(0.55, 0.22, 0.62);
const vec3 SR_LITTER_ROAD = vec3(0.32, 0.1, 0.4);

// Season weights (spring, summer, autumn; summing to 1) at a world position.
vec3 sr_season_at(vec2 wp) {
	vec3 w = texture(sr_season, (wp - sr_season_rect.xy) / sr_season_rect.zw).rgb;
	return w / max(w.r + w.g + w.b, 1e-4);
}

// Season index (0 spring, 1 summer, 2 autumn) for a litter cell with the random `h` in 0..1.
int sr_season_pick(vec3 w, float h) {
	return h < w.x ? 0 : (h < w.x + w.y ? 1 : 2);
}

vec3 sr_to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

// Litter colour (linear) of a season: petals A/B/C, a few green leaves and clover heads,
// maple red/orange/yellow. `pick` in 0..1 chooses the shade.
vec3 sr_litter_color(int season, float pick) {
	vec3 c;
	if (season == 0) {
		c = pick < 0.45 ? vec3(0.969, 0.765, 0.827) : (pick < 0.8 ? vec3(0.992, 0.894, 0.925) : vec3(0.941, 0.608, 0.722));
	} else if (season == 1) {
		c = pick < 0.45 ? vec3(0.498, 0.682, 0.333) : (pick < 0.8 ? vec3(0.643, 0.784, 0.416) : vec3(0.933, 0.941, 0.863));
	} else {
		c = pick < 0.45 ? vec3(0.863, 0.290, 0.173) : (pick < 0.8 ? vec3(0.937, 0.541, 0.212) : vec3(0.945, 0.749, 0.271));
	}
	return sr_to_linear(c);
}
