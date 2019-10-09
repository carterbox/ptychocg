#include "ptychofft.cuh"
#include "kernels.cuh"

// constructor, memory allocation
ptychofft::ptychofft(size_t ntheta_, size_t nz_, size_t n_,
					 size_t nscan_, size_t ndetx_, size_t ndety_, size_t nprb_)
{
	// init sizes
	n = n_;
	ntheta = ntheta_;
	nz = nz_;
	nscan = nscan_;
	ndetx = ndetx_;
	ndety = ndety_;
	nprb = nprb_;

	// allocate memory on GPU
	cudaMalloc((void **)&f, ntheta * nz * n * sizeof(float2));
	cudaMalloc((void **)&g, ntheta * nscan * ndetx * ndety * sizeof(float2));
	cudaMalloc((void **)&scanx, ntheta * nscan * sizeof(float));
	cudaMalloc((void **)&scany, ntheta * nscan * sizeof(float));
	cudaMalloc((void **)&shiftx, ntheta * nscan * sizeof(float2));
	cudaMalloc((void **)&shifty, ntheta * nscan * sizeof(float2));
	cudaMalloc((void **)&prb, ntheta * nprb * nprb * sizeof(float2));

	// create batched 2d FFT plan on GPU with sizes (ndetx,ndety)
	int ffts[2];
	ffts[0] = ndetx;
	ffts[1] = ndety;
	cufftPlanMany(&plan2d, 2, ffts, ffts, 1, ndetx * ndety, ffts, 1, ndetx * ndety, CUFFT_C2C, ntheta * nscan);

	// create batched 2d FFT plan on GPU with sizes (nprb,nprb)	acting on arrays with sizes (ndetx,ndety)
	ffts[0] = nprb;
	ffts[1] = nprb;
	int inembed[2];
	inembed[0] = ndetx;
	inembed[1] = ndety;
	cufftPlanMany(&plan2dshift, 2, ffts, inembed, 1, ndetx * ndety, inembed, 1, ndetx * ndety, CUFFT_C2C, ntheta * nscan);

	// init 3d thread block on GPU
	BS3d.x = 32;
	BS3d.y = 32;
	BS3d.z = 1;

	// init 3d thread grids	on GPU
	GS3d0.x = ceil(nprb * nprb / (float)BS3d.x);
	GS3d0.y = ceil(nscan / (float)BS3d.y);
	GS3d0.z = ceil(ntheta / (float)BS3d.z);

	GS3d1.x = ceil(ndetx * ndety / (float)BS3d.x);
	GS3d1.y = ceil(nscan / (float)BS3d.y);
	GS3d1.z = ceil(ntheta / (float)BS3d.z);

	GS3d2.x = ceil(nscan / (float)BS3d.x);
	GS3d2.y = ceil(ntheta / (float)BS3d.y);
	GS3d2.z = 1;
}

// destructor, memory deallocation
ptychofft::~ptychofft()
{
	cudaFree(f);
	cudaFree(g);
	cudaFree(scanx);
	cudaFree(scany);
	cudaFree(shiftx);
	cudaFree(shifty);
	cudaFree(prb);
	cufftDestroy(plan2d);
}

// forward ptychography operator g = FQf
void ptychofft::fwd(size_t g_, size_t f_, size_t scan_, size_t prb_)
{
	// copy arrays to GPU
	cudaMemcpy(f, (float2 *)f_, ntheta * nz * n * sizeof(float2), cudaMemcpyDefault);
	cudaMemset(g, 0, ntheta * nscan * ndetx * ndety * sizeof(float2));
	cudaMemcpy(scanx, &((float *)scan_)[0], ntheta * nscan * sizeof(float), cudaMemcpyDefault);
	cudaMemcpy(scany, &((float *)scan_)[ntheta * nscan], ntheta * nscan * sizeof(float), cudaMemcpyDefault);
	cudaMemcpy(prb, (float2 *)prb_, ntheta * nprb * nprb * sizeof(float2), cudaMemcpyDefault);

	// take part for the probe multiplication and shift it via FFT
	takepart<<<GS3d0, BS3d>>>(g, f, prb, scanx, scany, ntheta, nz, n, nscan, nprb, ndetx, ndety);

	//// SHIFT start
	// Fourier transform
	cufftExecC2C(plan2dshift, (cufftComplex *)g, (cufftComplex *)g, CUFFT_FORWARD);
	// compute exp(1j dx),exp(1j dy) where dx,dy are in (-1,1) and correspond to shifts to nearest integer
	takeshifts<<<GS3d2, BS3d>>>(shiftx, shifty, scanx, scany, 1, ntheta, nscan);
	// perform shifts in the frequency domain by multiplication with exp(1j dx),exp(1j dy)
	shifts<<<GS3d1, BS3d>>>(g, shiftx, shifty, ntheta, nscan, ndetx * ndety, nprb*nprb);
	// inverse Fourier transform
	cufftExecC2C(plan2dshift, (cufftComplex *)g, (cufftComplex *)g, CUFFT_INVERSE);
	//// SHIFT end

	// probe multiplication of the object array
	mulprobe<<<GS3d0, BS3d>>>(g, f, prb, scanx, scany, ntheta, nz, n, nscan, nprb, ndetx, ndety);
	// Fourier transform
	cufftExecC2C(plan2d, (cufftComplex *)g, (cufftComplex *)g, CUFFT_FORWARD);

	// copy result to CPU
	cudaMemcpy((float2 *)g_, g, ntheta * nscan * ndetx * ndety * sizeof(float2), cudaMemcpyDefault);
}

// adjoint ptychography operator with respect to object (flg==0) f = Q*F*g, or probe (flg==1) prb = Q*F*g
void ptychofft::adj(size_t f_, size_t g_, size_t scan_, size_t prb_, int flg)
{
	// copy arrays to GPU
	cudaMemcpy(f, (float2 *)f_, ntheta * nz * n * sizeof(float2),cudaMemcpyDefault);
	cudaMemcpy(g, (float2 *)g_, ntheta * nscan * ndetx * ndety * sizeof(float2), cudaMemcpyDefault);
	cudaMemcpy(scanx, &((float *)scan_)[0], ntheta * nscan * sizeof(float), cudaMemcpyDefault);
	cudaMemcpy(scany, &((float *)scan_)[ntheta * nscan], ntheta * nscan * sizeof(float), cudaMemcpyDefault);
	cudaMemcpy(prb, (float2 *)prb_, ntheta * nprb * nprb * sizeof(float2), cudaMemcpyDefault);

	// inverse Fourier transform
	cufftExecC2C(plan2d, (cufftComplex *)g, (cufftComplex *)g, CUFFT_INVERSE);
	if (flg == 0)// adjoint probe multiplication operator
	{
		mulaprobe<<<GS3d0, BS3d>>>(f, g, prb, scanx, scany, ntheta, nz, n, nscan, nprb, ndetx, ndety);

		//// SHIFT start
		// Fourier transform
		cufftExecC2C(plan2dshift, (cufftComplex *)g, (cufftComplex *)g, CUFFT_FORWARD);
		// compute exp(1j dx),exp(1j dy) where dx,dy are in (-1,1) and correspond to shifts to nearest integer
		takeshifts<<<GS3d2, BS3d>>>(shiftx, shifty, scanx, scany, -1, ntheta, nscan);
		// perform shifts in the frequency domain by multiplication with exp(-1j dx),exp(-1j dy) - backward
		shifts<<<GS3d1, BS3d>>>(g, shiftx, shifty, ntheta, nscan, ndetx * ndety, nprb*nprb);
		cufftExecC2C(plan2dshift, (cufftComplex *)g, (cufftComplex *)g, CUFFT_INVERSE);
		//// SHIFT end

		setpartobj<<<GS3d0, BS3d>>>(f, g, prb, scanx, scany, ntheta, nz, n, nscan, nprb, ndetx, ndety);
		// copy result to CPU
		cudaMemcpy((float2 *)f_, f, ntheta * nz * n * sizeof(float2), cudaMemcpyDefault);
	}
	else if (flg == 1)// adjoint object multiplication operator
	{
		mulaobj<<<GS3d0, BS3d>>>(prb, g, f, scanx, scany, ntheta, nz, n, nscan, nprb, ndetx, ndety);

		//// SHIFT start
		// Fourier transform
		cufftExecC2C(plan2dshift, (cufftComplex *)g, (cufftComplex *)g, CUFFT_FORWARD);
		// compute exp(1j dx),exp(1j dy) where dx,dy are in (-1,1) and correspond to shifts to nearest integer
		takeshifts<<<GS3d2, BS3d>>>(shiftx, shifty, scanx, scany, -1, ntheta, nscan);
		// perform shifts in the frequency domain by multiplication with exp(-1j dx),exp(-1j dy) - backward
		shifts<<<GS3d1, BS3d>>>(g, shiftx, shifty, ntheta, nscan, ndetx * ndety, nprb*nprb);
		cufftExecC2C(plan2dshift, (cufftComplex *)g, (cufftComplex *)g, CUFFT_INVERSE);
		//// SHIFT end

		setpartprobe<<<GS3d0, BS3d>>>(prb, g, f, scanx, scany, ntheta, nz, n, nscan, nprb, ndetx, ndety);
		// copy result to CPU
		cudaMemcpy((float2 *)prb_, prb, ntheta * nprb * nprb * sizeof(float2), cudaMemcpyDefault);
	}
}
