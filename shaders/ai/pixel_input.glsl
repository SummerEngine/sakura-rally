#[compute]
#version 450
// The pixel driver's input (scripts/ai/pixel_policy.gd): the DriveEyes frame as the network was
// trained on it, the bytes Viewport.get_image() returns over 255, channel-major (R plane, G, B).
// A texture stored as sRGB decodes to linear when read: `to_srgb` encodes it back.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D frame;
layout(set = 0, binding = 1, std430) restrict writeonly buffer Out { float data[]; } dst;

layout(push_constant, std430) uniform Params {
	int width;
	int height;
	int to_srgb;
	int pad;
} p;

float encode(float c) {
	return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= p.width || xy.y >= p.height) {
		return;
	}
	vec3 c = texelFetch(frame, xy, 0).rgb;
	if (p.to_srgb != 0) {
		c = vec3(encode(c.r), encode(c.g), encode(c.b));
	}
	// as bytes: the training frames were 8-bit
	c = round(clamp(c, 0.0, 1.0) * 255.0) / 255.0;
	int plane = p.width * p.height;
	int i = xy.y * p.width + xy.x;
	dst.data[i] = c.r;
	dst.data[plane + i] = c.g;
	dst.data[2 * plane + i] = c.b;
}
