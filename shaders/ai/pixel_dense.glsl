#[compute]
#version 450
// One fully connected layer of the pixel driver's network (scripts/ai/pixel_policy.gd), as
// torch.nn.Linear (weights [n_out][n_in]), ReLU when `relu`. It reads n_in values from
// `in_offset` and writes n_out from `out_offset`. One invocation per output.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer In { float data[]; } src;
layout(set = 0, binding = 1, std430) restrict readonly buffer Weights { float data[]; } w;
layout(set = 0, binding = 2, std430) restrict readonly buffer Bias { float data[]; } b;
layout(set = 0, binding = 3, std430) restrict writeonly buffer Out { float data[]; } dst;

layout(push_constant, std430) uniform Params {
	int n_in;
	int n_out;
	int in_offset;
	int out_offset;
	int relu;
	int pad0;
	int pad1;
	int pad2;
} p;

void main() {
	int j = int(gl_GlobalInvocationID.x);
	if (j >= p.n_out) {
		return;
	}
	float acc = b.data[j];
	int row = j * p.n_in;
	for (int i = 0; i < p.n_in; i++) {
		acc += w.data[row + i] * src.data[p.in_offset + i];
	}
	dst.data[p.out_offset + j] = p.relu != 0 ? max(acc, 0.0) : acc;
}
