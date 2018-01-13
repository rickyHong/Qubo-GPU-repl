#include "cudafuncs.h"
#include "DeviceMathKernels.h"
#include <cub/cub.cuh>

using sqaod::SizeType;
using sqaod::IdxType;
using namespace sqaod_cuda;

#ifdef _DEBUG
#define CUB_DEBUG (true)
#else
#define CUB_DEBUG (false)
#endif


/* FIXME: add __forceinline__ for device funcs/methods. */

namespace {
        
template<class real>
struct AddAssign {
    __device__ AddAssign(real &_d_value, real _mulFactor, real _alpha) : d_value(_d_value), mulFactor(_mulFactor), alpha(_alpha) { }
    __forceinline__
    __device__ real operator=(const real &v) const {
        return d_value = mulFactor * d_value + alpha * v;
    }
    real &d_value;
    real mulFactor;
    real alpha;
};

template<class real>
struct AddAssignDevPtr {
    typedef real value_type;

    AddAssignDevPtr(real *_d_data, real _mulFactor, real _alpha) : d_data(_d_data), mulFactor(_mulFactor), alpha(_alpha) { }
    typedef AddAssign<real> Ref;
    __device__ Ref operator*() const {
        return Ref(*d_data, mulFactor, alpha);
    }
    __device__ Ref operator[](SizeType idx) const {
        return Ref(d_data[idx], mulFactor, alpha);
    }


    real *d_data;
    real mulFactor;
    real alpha;
};


template<class real>
struct StridedInPtr {
    typedef real value_type;
    typedef StridedInPtr SelfType;
    __host__ __device__
    StridedInPtr(const real *_d_data, SizeType _stride, IdxType _offset) : d_data(_d_data), stride(_stride), offset(_offset) { }
    typedef AddAssign<real> Ref;
    __device__ const real &operator[](SizeType idx) const {
        return d_data[offset + idx * stride];
    }
    __device__
    SelfType operator+(IdxType v) const {
        return SelfType(d_data + v, stride, offset);
    }

    const real *d_data;
    SizeType stride;
    IdxType offset;
};


template<class type, class real>
struct dev_iterator_traits {
    using difference_type   = ptrdiff_t;
    typedef real              value_type;
    using pointer           = real*;
    using reference         = real&;
    using iterator_category = std::random_access_iterator_tag;
};


}

namespace std {

template<class real>
struct iterator_traits<AddAssignDevPtr<real> > : dev_iterator_traits<AddAssignDevPtr<real>, real> { };
template<class real>
struct iterator_traits<StridedInPtr<real>> : dev_iterator_traits<StridedInPtr<real>, real> { };

}




template<class real>  static __global__
void scaleKernel(real *d_y, real alpha, const real *d_x, SizeType size) {
    int gid = blockDim.x * blockIdx.x + threadIdx.x;
    if (gid < size)
        d_y[gid] += alpha * d_x[gid];
}

template<class real>
void DeviceMathKernelsType<real>::scale(real *d_y, real alpha, const real *d_x, SizeType size) {
    dim3 blockDim(128);
    dim3 gridDim(divru(size, blockDim.x));
    scaleKernel<<<gridDim, blockDim, 0, stream_>>>(d_y, alpha, d_x, size);
    DEBUG_SYNC;
}

template<class real, class OutType>
static __global__
void scaleBroadcastKernel(OutType d_y, real alpha, const real *d_c, SizeType size) {
    int gid = blockDim.x * blockIdx.x + threadIdx.x;
    if (gid < size)
        d_y[gid] = alpha * (*d_c);
}

template<class real> void DeviceMathKernelsType<real>::
scaleBroadcast(real *d_y, real alpha, const real *d_c, SizeType size,
               real addAssignFactor) {
    dim3 blockDim(128);
    dim3 gridDim(divru(size, blockDim.x));
    if (addAssignFactor == 0.) {
        scaleBroadcastKernel<<<gridDim, blockDim, 0, stream_>>>
                (d_y, alpha, d_c, size);
    }
    else {
        AddAssignDevPtr<real> outPtr(d_y, addAssignFactor, real(1.));
        scaleBroadcastKernel<real><<<gridDim, blockDim, 0, stream_>>>(outPtr, alpha, d_c, size);
    }
    DEBUG_SYNC;
}

template<class real, class OutPtrType>  static __global__
void scaleBroadcastVectorKernel(OutPtrType d_A, real alpha, const real *d_x, SizeType size) {
    int gidx = blockDim.x * blockIdx.x + threadIdx.x;
    int gidy = blockDim.y * blockIdx.y + threadIdx.y;
    if (gidx < size) {
        SizeType pos = gidx + size * gidy;
        d_A[pos] = alpha * d_x[gidx];
    }
}

template<class real>
void DeviceMathKernelsType<real>::
scaleBroadcastVector(real *d_A, real alpha, const real *d_x, SizeType size,
                     SizeType nBatch, real addAssignFactor) {
    dim3 blockDim(128);
    dim3 gridDim(divru(size, blockDim.x), divru(nBatch, blockDim.y));
    if (addAssignFactor == 0.) {
        scaleBroadcastVectorKernel<<<gridDim, blockDim, 0, stream_>>>(d_A, alpha, d_x, size);
    }
    else {
        AddAssignDevPtr<real> outPtr(d_A, addAssignFactor, real(1.));
        scaleBroadcastVectorKernel<<<gridDim, blockDim, 0, stream_>>>(outPtr, alpha, d_x, size);
    }
    DEBUG_SYNC;
}


template<class real, class OutPtrType>
static __global__
void scaleBroadcastScalarsKernel(OutPtrType d_A, real alpha, const real *d_x, SizeType size) {
    int gidx = blockDim.x * blockIdx.x + threadIdx.x;
    int gidy = blockDim.y * blockIdx.y + threadIdx.y;
    if (gidx < size) {
        SizeType pos = gidx + size * gidy;
        d_A[pos] = alpha * d_x[gidy];
    }
}

template<class real>
void DeviceMathKernelsType<real>::
scaleBroadcastScalars(real *d_A, real alpha, const real *d_x, SizeType size,
                     SizeType nBatch, real addAssignFactor) {
    dim3 blockDim(128);
    dim3 gridDim(divru(size, blockDim.x), divru(nBatch, blockDim.y));
    if (addAssignFactor == 0.) {
        scaleBroadcastScalarsKernel
                <<<gridDim, blockDim, 0, stream_>>>(d_A, alpha, d_x, size);
    }
    else {
        AddAssignDevPtr<real> outPtr(d_A, addAssignFactor, real(1.));
        scaleBroadcastScalarsKernel
                <<<gridDim, blockDim, 0, stream_>>>(outPtr, alpha, d_x, size);
    }
    DEBUG_SYNC;
}


template<class real> void DeviceMathKernelsType<real>::
sum(real *d_sum, real alpha, const real *d_x, SizeType size, real addAssignFactor) {
    size_t temp_storage_bytes;
    cub::DeviceReduce::Sum(NULL, temp_storage_bytes,
                           d_x, d_sum, size, stream_, CUB_DEBUG);
    void *d_temp_storage = devStream_->allocate(temp_storage_bytes, __func__);
    if (addAssignFactor == 0.) {
        cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes,
                               d_x, d_sum, size, stream_, CUB_DEBUG);
    }
    else {
        AddAssignDevPtr<real> outPtr(d_sum, addAssignFactor, real(1.));
        cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes,
                               d_x, outPtr, size, stream_, CUB_DEBUG);
    }
}



template<class real> void DeviceMathKernelsType<real>::
sumGather(real *d_sum, real alpha, const real *d_x, SizeType size, SizeType stride, int offset) {
    size_t temp_storage_bytes;
    cub::DeviceReduce::Sum(NULL, temp_storage_bytes,
                           d_x, d_sum, size, stream_, CUB_DEBUG);
    void *d_temp_storage = devStream_->allocate(temp_storage_bytes, __func__);
    StridedInPtr<real> inPtr(d_x, stride, offset);
    cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes,
                           inPtr, d_sum, size, stream_, CUB_DEBUG);
}


namespace {
/* Functors for offsets */

struct Const {
    Const(IdxType _c) : c(_c) { }
    __device__
    IdxType operator[](IdxType idx) const { return c; }
    IdxType c;
};

struct Linear {
    Linear(IdxType _a, IdxType _b) : a(_a), b(_b) { }
    __device__
    IdxType operator[](IdxType idx) const { return a * idx + b; }
    IdxType a, b;
};

}

template<class real> void DeviceMathKernelsType<real>::
sumBatched(real *d_sum, real alpha, const real *d_A, SizeType size, SizeType nBatch) {
    size_t temp_storage_bytes;
    cub::DeviceSegmentedReduce::Sum(NULL, temp_storage_bytes,
                                    d_A, d_sum, nBatch,
                                    Linear(0, size), Linear(size, size),
                                    stream_, CUB_DEBUG);
    void *d_temp_storage = devStream_->allocate(temp_storage_bytes, __func__);
    cub::DeviceSegmentedReduce::Sum(d_temp_storage, temp_storage_bytes,
                                    d_A, d_sum, nBatch,
                                    Linear(0, size), Linear(size, size),
                                    stream_, CUB_DEBUG);
}


namespace {

template<class real>
struct InDotPtr {
    typedef InDotPtr<real> SelfType;
    
    __host__ __device__
    InDotPtr(const real *_d_x, const real *_d_y) : d_x(_d_x), d_y(_d_y) { }
    __device__
    real operator[](IdxType idx) const {
        return d_x[idx] * d_y[idx];
    }
    __device__
    SelfType operator+(IdxType idx) const {
        return SelfType(&d_x[idx], &d_y[idx]);
    }
    
    const real *d_x, *d_y;
};

}

namespace std {

template<class real>
struct iterator_traits<InDotPtr<real>> : dev_iterator_traits<InDotPtr<real>, real> { };

}


template<class real> void DeviceMathKernelsType<real>::
dot(real *d_c, real alpha, const real *d_x, const real *d_y, SizeType size,
    real addAssignFactor) {

    InDotPtr<real> inPtr(d_x, d_y);
    size_t temp_storage_bytes;
    cub::DeviceReduce::Sum(NULL, temp_storage_bytes,
                           inPtr, d_c, size, stream_, CUB_DEBUG);
    void *d_temp_storage = devStream_->allocate(temp_storage_bytes, __func__);

    if (addAssignFactor == 0.) {
        cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes,
                               inPtr, d_c, size, stream_, CUB_DEBUG);
    }
    else {
        AddAssignDevPtr<real> outPtr(d_c, addAssignFactor, real(1.));
        cub::DeviceReduce::Sum(d_temp_storage, temp_storage_bytes,
                               inPtr, outPtr, size, stream_, CUB_DEBUG);
    }
}


template<class real> void DeviceMathKernelsType<real>::
dotBatched(real *d_z, real alpha, const real *d_x, const real *d_y, SizeType size,
           SizeType nBatch) {
    
    InDotPtr<real> inPtr(d_x, d_y);
    
    size_t temp_storage_bytes;
    cub::DeviceSegmentedReduce::Sum(NULL, temp_storage_bytes,
                                    inPtr, d_z, nBatch,
                                    Linear(0, size), Linear(size, size),
                                    stream_, CUB_DEBUG);
    void *d_temp_storage = devStream_->allocate(temp_storage_bytes, __func__);
    cub::DeviceSegmentedReduce::Sum(d_temp_storage, temp_storage_bytes,
                                    inPtr, d_z, nBatch,
                                    Linear(0, size), Linear(size, size),
                                    stream_, CUB_DEBUG);
}

template <class real>
__global__ static void
transposeKernel(real *d_At, const real *d_A, SizeType rows, SizeType cols) {


    int inTileLeft = blockDim.x * blockIdx.x * 32;
    int inTileTop = blockDim.y * blockIdx.y * 32;
    
    int xIn = inTileLeft + threadIdx.x;
    int yIn = inTileTop + threadIdx.y;

    real vIn = (xIn < cols) && (yIn < rows) ? d_A[xIn + cols * yIn] : real();
    real vOut;
    typedef cub::BlockExchange<real, 32, 1, cub::BLOCK_LOAD_TRANSPOSE, false, 32> BlockExchange;
    __shared__ typename BlockExchange::TempStorage tmpStorage;
    BlockExchange(tmpStorage).StripedToBlocked(&vIn, &vOut);

    int xOut = inTileTop + threadIdx.x;
    int yOut = inTileLeft + threadIdx.y;
    
    if ((xOut < cols) && (yOut < rows))
        d_At[xOut + cols * yOut] = vOut;
}


template<class real> void DeviceMathKernelsType<real>::
transpose(real *d_At, const real *d_A, SizeType rows, SizeType cols) {
    dim3 blockDim(32, 8);
    dim3 gridDim(divru(rows, 32u), divru(cols, 32u));
    transposeKernel<<<gridDim, blockDim, 0, stream_>>>(d_At, d_A, rows, cols);
    DEBUG_SYNC;
}


template<class real> void DeviceMathKernelsType<real>::
min(real *d_min, const real *d_values, SizeType size) {
    size_t temp_storage_bytes;
    cub::DeviceReduce::Min(NULL, temp_storage_bytes,
                           d_values, d_min, size, stream_, CUB_DEBUG);
    void *d_temp_storage = devStream_->allocate(temp_storage_bytes, __func__);
    cub::DeviceReduce::Min(d_temp_storage, temp_storage_bytes,
                           d_values, d_min, size, stream_, CUB_DEBUG);
}

template<> void DeviceMathKernelsType<double>::
gemv(cublasOperation_t op, int M, int N,
     const double *d_alpha, const double *d_A, const double *d_x,
     const double *d_beta, double *d_y) {
    cublasDgemv(devStream_->getCublasHandle(), op, M, N, d_alpha, d_A, N, d_x, 1, d_beta, d_y, 1);
}

template<> void DeviceMathKernelsType<float>::
gemv(cublasOperation_t op, int M, int N,
     const float *d_alpha, const float *d_A, const float *d_x,
     const float *d_beta, float *d_y) {
    cublasSgemv(devStream_->getCublasHandle(), op, M, N, d_alpha, d_A, N, d_x, 1, d_beta, d_y, 1);
}

template<> void DeviceMathKernelsType<double>::
gemm(cublasOperation_t opA, cublasOperation_t opB, int M, int N, int K,
     const double *d_alpha, const double *d_A, const double *d_B,
     const double *d_beta, double *d_C) {
    cublasDgemm(devStream_->getCublasHandle(), opA, opB, M, N, K, d_alpha, d_A, M, d_B, K, d_beta, d_C, M);
}

template<> void DeviceMathKernelsType<float>::
gemm(cublasOperation_t opA, cublasOperation_t opB, int M, int N, int K,
     const float *d_alpha, const float *d_A, const float *d_B,
     const float *d_beta, float *d_C) {
    cublasSgemm(devStream_->getCublasHandle(), opA, opB, M, N, K, d_alpha, d_A, M, d_B, K, d_beta, d_C, M);
}

template<class real> DeviceMathKernelsType<real>::
DeviceMathKernelsType(DeviceStream *devStream) {
    setDeviceStream(devStream);
}

template<class real> void DeviceMathKernelsType<real>::
setDeviceStream(DeviceStream *devStream) {
    devStream_ = devStream;
    stream_ = devStream_->getStream();
}


template struct sqaod_cuda::DeviceMathKernelsType<double>;
template struct sqaod_cuda::DeviceMathKernelsType<float>;

