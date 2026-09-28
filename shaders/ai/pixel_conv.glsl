#[compute]
#version 450
// One convolution of the pixel driver's network (scripts/ai/pixel_policy.gd) with ReLU, no
// padding, as torch.nn.Conv2d: input channel-major [in_c][in_h][in_w], weights [out_c][in_c][k][k],
// output [out_c][out_h][out_w]. One invocation per output value.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer In { float data[]; } src;
layout(set = 0, binding = 1, std430) restrict readonly buffer Weights { float data[]; } w;
layout(set = 0, binding = 2, std430) restrict readonly buffer Bias { float data[]; } b;
layout(set = 0, binding = 3, std430) restrict writeonly buffer Out { float data[]; } dst;

layout(push_constant, std430) uniform Params {
	int in_c;
	int in_h;
	int in_w;
	int out_c;
	int out_h;
	int out_w;
	int k;
	int stride;
} p;

void main() {
	int idx = int(gl_GlobalInvocationID.x);
	if (idx >= p.out_c * p.out_h * p.out_w) {
		return;
	}
	int ox = idx % p.out_w;
	int oy = (idx / p.out_w) % p.out_h;
	int oc = idx / (p.out_w * p.out_h);
	float acc = b.data[oc];
	int plane = p.in_h * p.in_w;
	for (int ic = 0; ic < p.in_c; ic++) {
		for (int ky = 0; ky < p.k; ky++) {
			int row = ic * plane + (oy * p.stride + ky) * p.in_w + ox * p.stride;
			int wrow = ((oc * p.in_c + ic) * p.k + ky) * p.k;
			for (int kx = 0; kx < p.k; kx++) {
				acc += w.data[wrow + kx] * src.data[row + kx];
			}
		}
	}
	dst.data[idx] = max(acc, 0.0);
}
