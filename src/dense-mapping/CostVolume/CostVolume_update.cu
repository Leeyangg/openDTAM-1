#include <opencv2/core/core.hpp>
#include "CostVolume.cuh"

// 2D float texture
static texture<float, cudaTextureType2D, cudaReadModeElementType> current_imageTexRef;

static __global__ void updateCostVolume(float* K, float* Kinv, float* Tmr,
										int rows, int cols,
										float near, float far, int layers, int layerStep,
										float* Cost, float count,
										float* Cmin, float* Cmax, float* CminIdx,
										float* reference_image, float* current_image)
{
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	const int i = x + y*cols;

	const float ur = x;
	const float vr = y;

	const float depthStep = (near - far)/(layers-1);

	float Ir = reference_image[i];

	int	  minl = layers-1; // TODO set to layers?
	float Cost_min = 1e+30, Cost_max = 0.0;
	for(int l=layers-1; l >= 0; l--) { // TODO march from front to back, i.e., l = layers -> 0 and check results. 
		float d = far + float(l)*depthStep;
		// 0 1 2
		// 3 4 5
		// 6 7 8
		float zr = 1.0/d; // divide by 0 is evaluated as Inf, as per IEEE-754
		float xr = (Kinv[0]*ur + Kinv[2])*zr;
		float yr = (Kinv[4]*vr + Kinv[5])*zr;
		//  0  1  2  3
		//  4  5  6  7
		//  8  9 10 11
		// 12 13 14 15
		float xm = Tmr[0]*xr + Tmr[1]*yr + Tmr[2]*zr  + Tmr[3];
		float ym = Tmr[4]*xr + Tmr[5]*yr + Tmr[6]*zr  + Tmr[7];
		float zm = Tmr[8]*xr + Tmr[9]*yr + Tmr[10]*zr + Tmr[11];
		// 0 1 2
		// 3 4 5
		// 6 7 8
		float um = K[0]*(xm/zm) + K[2];
		float vm = K[4]*(ym/zm) + K[5];

		if( (um > float(cols)) || (um < 0.0f) || (vm > float(rows)) || (vm < 0.0f) )
			continue;

		float Im = tex2D(current_imageTexRef, um, vm);

		float rho = fabsf(Ir - Im);
		Cost[i+l*layerStep] = (Cost[i+l*layerStep]*(count-1) + rho) / count; // TODO: maintain per pixel count? Not necessary. 
		float Cost_l = Cost[i+l*layerStep];
		if(Cost_l <= Cost_min) {
			Cost_min = Cost_l;
			minl = l;
		}
		Cost_max = fmaxf(Cost_l, Cost_max);
	}

	Cmin[i]	   = Cost_min;
	CminIdx[i] = far + float(minl)*depthStep; // scaling is done when used in DepthEstimator::optimize
	Cmax[i]	   = Cost_max;

	// sublayer sampling as the minimum of the parabola with the 2 points around (minz, minv)
	if(minl == 0 || minl == layers-1) // first or last was best
		return;

	float A = far + float(minl-1)*depthStep;
	float B = CminIdx[i];
	float C = far + float(minl+1)*depthStep;
	float delta = ((A+C)==2*B)? 0.0f : ((A-C)*depthStep)/(2*(A-2*B+C));
	delta = (fabsf(delta) > depthStep)? 0.0f : delta;
	CminIdx[i] += delta;
}

void updateCostVolumeCaller(float* K, float* Kinv, float* Tmr,
							int rows, int cols, int imageStep,
							float near, float far, int layers, int layerStep,
							float* Cdata, float count,
							float* Cmin, float* Cmax, float* CminIdx,
							float* reference_image, float* current_image)
{
	dim3 dimBlock(16, 16);
	dim3 dimGrid((cols + dimBlock.x - 1) / dimBlock.x,
				 (rows + dimBlock.y - 1) / dimBlock.y);

	// Set texture reference parameters
	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc(32, 0, 0, 0, cudaChannelFormatKindFloat);

	current_imageTexRef.normalized	  = false;
	current_imageTexRef.addressMode[0] = cudaAddressModeClamp; // out of border references return first or last element
	current_imageTexRef.addressMode[1] = cudaAddressModeClamp;
	current_imageTexRef.filterMode	  = cudaFilterModeLinear;

	// Bind current_image to the texture reference
	size_t offset;
	cudaBindTexture2D(&offset, current_imageTexRef, current_image, channelDesc, cols, rows, imageStep);

	cudaDeviceSynchronize();
	cudaSafeCall(cudaGetLastError());

	updateCostVolume<<<dimGrid, dimBlock>>>(K, Kinv, Tmr,
											rows, cols,
											near, far, layers, layerStep,
											Cdata, count,
											Cmin, Cmax, CminIdx,
											reference_image, current_image);
	cudaDeviceSynchronize();
	cudaSafeCall(cudaGetLastError());
	cudaUnbindTexture(current_imageTexRef);
}
