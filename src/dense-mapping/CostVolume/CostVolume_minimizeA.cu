#include <assert.h>
#include <iostream>
#include <opencv2/core/core.hpp>
#include "CostVolume.cuh"

// Using a different version of the accelerated search method:
// a_min must lie between [(d_i-d_min), (d_i+d_min)]

#define SET_start_layer()                                   \
    float d_start = di - r;                                 \
    layer = lrintf(floorf((d_start - far)/depthStep)) - 1;  \
    layer = (layer<0)? 0 : layer;                           \
    start_layer = layer;                                    \

#define SET_end_layer()                                     \
    float d_end = di + r;                                   \
    layer = lrintf(ceilf((d_end - far)/depthStep)) + 1;     \
    layer = (layer>(layers-1))? (layers-1) : layer;         \
    end_layer = layer;                                      \

__device__
static inline float Eaux(float theta, float di, float aIdx, float far, float depthStep, float lambda, float costval)
{
	float ai = far + float(aIdx)*depthStep;
	return (0.5f/theta)*((di-ai)*(di-ai)) + lambda*costval; // TODO beware float substraction
}

static __global__ void minimizeA(float* cost, int rows, int cols,
								 float* a, float* d,
								 float*d_Cmin, float*C_min, float*C_max,
								 float far, float near, int layers,
								 float theta, float lambda)
{
	// thread coordinate
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	const int i = x + y*cols;

	const float depthStep = (near - far) / (layers - 1);
	const int	layerStep = rows*cols;
	const float di		  = d[i];

	float r = sqrtf(2*theta*lambda*(C_max[i] - C_min[i]));

	int minl = 0;
	float Eaux_min = 1e+30;
	int layer, start_layer, end_layer;
	SET_start_layer();
	SET_end_layer();
	for(int l=start_layer; l<=end_layer; l++) {
		float c = Eaux(theta, di, l, far, depthStep, lambda, cost[i+l*layerStep]);
		if(c < Eaux_min) {
			Eaux_min = c;
			minl = l;
		}
	}

	a[i] = far + float(minl)*depthStep;

	if(minl == 0 || minl == layers-1) // first or last was best
		return;

	// sublayer sampling as the minimum of the parabola with the 2 points around (minl, Eaux_min)
	float A = Eaux(theta, di, minl-1, far, depthStep, lambda, cost[i+(minl-1)*layerStep]);
	float B = Eaux_min;
	float C = Eaux(theta, di, minl+1, far, depthStep, lambda, cost[i+(minl+1)*layerStep]);
	float delta = ((A+C)==2*B)? 0.0f : ((A-C)*depthStep)/(2*(A-2*B+C));
	delta = (fabsf(delta) > depthStep)? 0.0f : delta;
	a[i] += delta;
}

void minimizeACaller(float *cdata, int rows, int cols,
					 float *a, float *d,
					 float*d_Cmin, float*C_min, float*C_max,
					 float far, float near, int layers,
					 float theta, float lambda)
{
	dim3 dimBlock(16, 16);
	dim3 dimGrid((cols + dimBlock.x - 1) / dimBlock.x,
				 (rows + dimBlock.y - 1) / dimBlock.y);

	minimizeA<<<dimGrid, dimBlock>>>(cdata, rows, cols,
									 a, d,
									 d_Cmin, C_min, C_max,
									 far, near, layers,
									 theta, lambda);

	cudaDeviceSynchronize();
	cudaSafeCall( cudaGetLastError() );
}
