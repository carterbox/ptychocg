void __global__ fftshift1c(float2 *f, int N, int Ntheta, int Nz) {
  int tx = blockDim.x * blockIdx.x + threadIdx.x;
  int ty = blockDim.y * blockIdx.y + threadIdx.y;
  int tz = blockDim.z * blockIdx.z + threadIdx.z;
  if (tx >= N || ty >= Ntheta || tz >= Nz)
    return;
  int g = (1 - 2 * ((tx + 1) % 2));
  f[tx + tz * N + ty * N * Nz].x *= g;
  f[tx + tz * N + ty * N * Nz].y *= g;
}

void __global__ fftshiftc(float2 *f, int N, int Nz) {
  int tx = blockDim.x * blockIdx.x + threadIdx.x;
  int ty = blockDim.y * blockIdx.y + threadIdx.y;
  int tz = blockDim.z * blockIdx.z + threadIdx.z;
  if (tx >= N || ty >= N || tz >= Nz)
    return;
  int g = (1 - 2 * ((tx + 1) % 2)) * (1 - 2 * ((ty + 1) % 2));
  f[tx + ty * N + tz * N * N].x *= g;
  f[tx + ty * N + tz * N * N].y *= g;
}

void __global__ takeshift(float2 *shift, float c, int N) {
  int tx = blockDim.x * blockIdx.x + threadIdx.x;
  if (tx >= N)
    return;
  shift[tx].x = __cosf(2 * PI * c * (tx - N / 2.0) / N);
  shift[tx].y = __sinf(2 * PI * c * (tx - N / 2.0) / N);
}

void __global__ shift(float2 *f, float2 *shift, int N, int Ntheta, int Nz) {
  int tx = blockDim.x * blockIdx.x + threadIdx.x;
  int ty = blockDim.y * blockIdx.y + threadIdx.y;
  int tz = blockDim.z * blockIdx.z + threadIdx.z;
  if (tx >= N || ty >= Ntheta || tz >= Nz)
    return;
  float cr = shift[tx].x;
  float ci = shift[tx].y;
  float2 f0;
  f0.x = f[tx + tz * N + ty * N * Nz].x;
  f0.y = f[tx + tz * N + ty * N * Nz].y;
  f[tx + tz * N + ty * N * Nz].x = f0.x * cr - f0.y * ci;
  f[tx + tz * N + ty * N * Nz].y = f0.x * ci + f0.y * cr;
}
