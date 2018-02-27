#include "CUDADenseGraphAnnealer.h"
#include "DeviceKernels.h"
#include "cub_iterator.cuh"
#include <cub/cub.cuh>
#include "DeviceSegmentedSum.cuh"


using namespace sqaod_cuda;

template<class real>
CUDADenseGraphAnnealer<real>::CUDADenseGraphAnnealer() {
    devStream_ = NULL;
    m_ = (SizeType)-1;
}

template<class real>
CUDADenseGraphAnnealer<real>::CUDADenseGraphAnnealer(Device &device) {
    devStream_ = NULL;
    m_ = (SizeType)-1;
    assignDevice(device);
}

template<class real>
CUDADenseGraphAnnealer<real>::~CUDADenseGraphAnnealer() {
    if (isInitialized())
        deallocate();
    d_random_.deallocate();
    if (dotJq_ != NULL) {
        delete dotJq_;
        dotJq_ = NULL;
    }
}

template<class real>
void CUDADenseGraphAnnealer<real>::deallocate() {
    if (isProblemSet())
        deallocateProblem();
    if (isInitialized())
        deallocateInternalObjects();
}

template<class real>
void CUDADenseGraphAnnealer<real>::deallocateProblem() {
    devAlloc_->deallocate(d_J_);
    devAlloc_->deallocate(d_h_);
    devAlloc_->deallocate(d_c_);
    clearState(solProblemSet);
}

template<class real>
void CUDADenseGraphAnnealer<real>::deallocateInternalObjects() {
    devAlloc_->deallocate(d_matq_);
    devAlloc_->deallocate(d_Jq_);
        
    HostObjectAllocator halloc;
    halloc.deallocate(h_E_);
    halloc.deallocate(h_q_);
    E_ = HostVector();
        
    flipPosBuffer_.deallocate();
    realNumBuffer_.deallocate();

    clearState(solInitialized);
    clearState(solQSet);
}

template<class real>
void CUDADenseGraphAnnealer<real>::assignDevice(Device &device) {
    throwErrorIf(devStream_ != NULL, "Device assigned more than once.");
    devStream_ = device.defaultStream();
    devAlloc_ = device.objectAllocator();
    devFormulas_.assignDevice(device);
    devCopy_.assignDevice(device);
    d_random_.assignDevice(device);
    flipPosBuffer_.assignDevice(device);
    realNumBuffer_.assignDevice(device);

    /* initialize sumJq */
    typedef DeviceSegmentedSumTypeImpl<real, InDotPtr<real>, real*, Offset2way> DotJq;
    dotJq_ = new DotJq(device);
}

template<class real>
sq::Algorithm CUDADenseGraphAnnealer<real>::selectAlgorithm(sq::Algorithm algo) {
    return sq::algoColoring;
}

template<class real>
sq::Algorithm CUDADenseGraphAnnealer<real>::getAlgorithm() const {
    return sq::algoColoring;
}


template<class real>
void CUDADenseGraphAnnealer<real>::seed(unsigned int seed) {
    throwErrorIf(devStream_ == NULL, "Device not set.");
    d_random_.seed(seed);
    setState(solRandSeedGiven);
}

template<class real>
void CUDADenseGraphAnnealer<real>::setProblem(const HostMatrix &W, sq::OptimizeMethod om) {
    throwErrorIf(!isSymmetric(W), "W is not symmetric.");
    throwErrorIf(devStream_ == NULL, "Device not set.");
    if (W.rows != N_)
        deallocate();

    N_ = W.rows;
    m_ = N_ / 4;
    om_ = om;

    DeviceMatrix *dW = devStream_->tempDeviceMatrix<real>(W.dim(), __func__);
    devCopy_(dW, W);
    if (om == sq::optMaximize)
        devFormulas_.devMath.scale(dW, -1., *dW);
    devFormulas_.calculate_hJc(&d_h_, &d_J_, &d_c_, *dW);

    setState(solProblemSet);
}


template<class real>
const sq::VectorType<real> &CUDADenseGraphAnnealer<real>::get_E() const {
    throwErrorIfSolutionNotAvailable();
    return E_;
}

template<class real>
const sq::BitsArray &CUDADenseGraphAnnealer<real>::get_x() const {
    throwErrorIfSolutionNotAvailable();
    return xlist_;
}


template<class real>
void CUDADenseGraphAnnealer<real>::set_x(const Bits &x) {
    throwErrorIfNotInitialized();
    /* FIXME: add size check */
    HostVector rx = sq::x_to_q<real>(x);
    DeviceVector *d_x = devStream_->tempDeviceVector<real>(rx.size);
    devCopy_(d_x, rx);
    devFormulas_.devMath.scaleBroadcast(&d_matq_, real(1.), *d_x, opRowwise);
    setState(solQSet);
}


template<class real>
void CUDADenseGraphAnnealer<real>::get_hJc(HostVector *h, HostMatrix *J, real *c) const {
    throwErrorIfProblemNotSet();

    devCopy_(h, d_h_);
    devCopy_(J, d_J_);
    devCopy_(c, d_c_);
    devCopy_.synchronize();
}

template<class real>
void CUDADenseGraphAnnealer<real>::randomize_q() {
    throwErrorIfNotInitialized();

    ::randomize_q(d_matq_.d_data, d_random_, d_matq_.rows * d_matq_.cols,
                  devStream_->getCudaStream());
    setState(solQSet);
}

template<class real>
void CUDADenseGraphAnnealer<real>::calculate_E() {
    throwErrorIfQNotSet();

    DeviceVector *d_E = devStream_->tempDeviceVector<real>(m_);
    devFormulas_.calculate_E(d_E, d_h_, d_J_, d_c_, d_matq_);
    real sign = (om_ == sq::optMaximize) ? -1. : 1.;
    devFormulas_.devMath.scale(&h_E_, sign, *d_E);
}

template<class real>
void CUDADenseGraphAnnealer<real>::initAnneal() {
    throwErrorIfProblemNotSet();

    if (!isRandSeedGiven())
        d_random_.seed();
    setState(solRandSeedGiven);

    if (isInitialized())
        deallocateInternalObjects();
    
    HostObjectAllocator halloc;
    devAlloc_->allocate(&d_matq_, m_, N_);
    devAlloc_->allocate(&d_Jq_, m_);
    halloc.allocate(&h_E_, m_);
    E_.map(h_E_.d_data, h_E_.size);
    halloc.allocate(&h_q_, sq::Dim(m_, N_));
    xlist_.reserve(m_);
    qlist_.reserve(m_);
    /* estimate # rand nums required per one anneal. */
    int requiredSize = (N_ * m_ * (nRunsPerRandGen + 1)) * sizeof(real) / 4;
    d_random_.setRequiredSize(requiredSize);
    
    typedef DeviceSegmentedSumTypeImpl<real, InDotPtr<real>, real*, Offset2way> DotJq;
    DotJq &dotJq = static_cast<DotJq&>(*dotJq_);
    dotJq.configure(N_, m_, false);

    setState(solInitialized);
}

template<class real>
void CUDADenseGraphAnnealer<real>::finAnneal() {
    throwErrorIfQNotSet();

    devStream_->synchronize();
    syncBits();
    calculate_E();
    devStream_->synchronize();

    setState(solSolutionAvailable);
}

template<class real>
void CUDADenseGraphAnnealer<real>::syncBits() {
    xlist_.clear();
    qlist_.clear();

    devFormulas_.devMath.toBits(&h_q_, d_matq_);
    devStream_->synchronize();
    for (int idx = 0; idx < sq::IdxType(m_); ++idx) {
        Bits q(h_q_.row(idx), N_);
        qlist_.pushBack(q);
        Bits x(sq::SizeType(qlist_.size()));
        x = x_from_q(q);
        xlist_.pushBack(x);
    }
}

#if 0
/* equivalent code */
template<class real>
void annealOneStep(real G, real kT) {
    real twoDivM = real(2.) / real(m_);
    real coef = std::log(std::tanh(G / kT / m_)) / kT;

    for (int outer = 0; outer < IdxType(N_); ++outer) {
        int x[m];

        /* carried out in DeviceRandomBuffer. */
        for (int y = 0; y < IdxType(m_); ++y) {
            /* first plane */
            int fraction = y % 2;
            /* second plane */
            int fraction = 1 - y % 2;

            x[innder] = (random_random() * 2 + fraction) % N;
        }

        /* calculate_Jq() */
        real d_Jq[m];
        for (int y = 0; y < IdxType(m_); ++y)
            d_Jq[y] = J_.row(x[y]).dot(matQ_.row(y));

        /* flip each bit, */
        for (int inner = 0; inner < IdxType(m_); ++inner) {
            /* flip one bit */
            real qyx = matQ_(y, x[m]);

            real dE = - twoDivM * qyx * (d_Jq[x[y] + h_(x[y])];
            int neibour0 = (m_ + y - 1) % m_, neibour1 = (y + 1) % m_;
            dE -= qyx * (matQ_(neibour0, x) + matQ_(neibour1, x)) * coef;
            real threshold = (dE < real(0.)) ? real(1.) : std::exp(-dE / kT);
            if (threshold > random_.random<real>())
                matQ_(y, x) = - qyx;
        }
    }
}
#endif

template<class real>
void CUDADenseGraphAnnealer<real>::calculate_Jq(DeviceVector *d_Jq,
                                                const DeviceMatrix &d_J, const DeviceMatrix &d_matq,
                                                const int *d_flipPos) {
    cudaStream_t stream = devStream_->getCudaStream();
    InDotPtr<real> inPtr(d_matq.d_data, d_J.d_data);
    typedef DeviceSegmentedSumTypeImpl<real, InDotPtr<real>, real*, Offset2way> DotJq;
    DotJq &dotJq = static_cast<DotJq&>(*dotJq_);
    dotJq(inPtr, d_Jq->d_data, Offset2way(d_flipPos, N_));
}

template<class real>
__global__ static void
tryFlipKernel(real *d_q, const real *d_Jq, const real *d_h,
              const int *d_x, const real *d_random, sq::SizeType N, sq::SizeType m,
             const real twoDivM, const real coef, const real invKT) {
    int y = blockDim.x * blockIdx.x + threadIdx.x; /* m */
    if (y < m) {
        int x = d_x[y]; /* N */
        real qyx = d_q[N * y + x];

        int neibour0 = (y == 0) ? m - 1 : y - 1;
        int neibour1 = (y == m - 1) ? 0 : y + 1;

        real dE = - twoDivM * qyx * (d_Jq[y] + d_h[x]);
        dE -= qyx * (d_q[N * neibour0 + x] + d_q[N * neibour1 + x]) * coef;
        real threshold = (dE < real(0.)) ? real(1.) : exp(- dE * invKT);
        if (threshold > d_random[y])
            d_q[N * y + x] = - qyx;
    }
}

template<class real> void CUDADenseGraphAnnealer<real>::
annealOneStep(DeviceMatrix *d_matq, const DeviceVector &d_Jq, const int *d_x, const real *d_random,
              const DeviceVector &d_h, const DeviceMatrix &d_J, real G, real kT) {
    real twoDivM = real(2.) / real(m_);
    real coef = std::log(std::tanh(G / kT / m_)) / kT;
    real invKT = real(1.) / kT;

    dim3 blockDim(128);
    dim3 gridDim(divru((sq::SizeType)m_, blockDim.x));
    tryFlipKernel<<<gridDim, blockDim>>>(d_matq->d_data, d_Jq.d_data, d_h.d_data,
                                         d_x, d_random, N_, m_,
                                         twoDivM, coef, invKT);
    DEBUG_SYNC;
}



template<class real>
void CUDADenseGraphAnnealer<real>::annealOneStep(real G, real kT) {
    throwErrorIfQNotSet();

    if (!flipPosBuffer_.available(m_ * N_))
        flipPosBuffer_.generateFlipPositions(d_random_, N_, m_, nRunsPerRandGen);
    if (!realNumBuffer_.available(m_ * N_))
        realNumBuffer_.generate<real>(d_random_, N_ * m_ * nRunsPerRandGen);
    for (int idx = 0; idx < N_; ++idx) {
        const int *d_flipPos = flipPosBuffer_.acquire<int>(m_);
        const real *d_random = realNumBuffer_.acquire<real>(m_);
        calculate_Jq(&d_Jq_, d_J_, d_matq_, d_flipPos);
        annealOneStep(&d_matq_, d_Jq_, d_flipPos, d_random, d_h_, d_J_, G, kT);
    }
}




template class CUDADenseGraphAnnealer<double>;
template class CUDADenseGraphAnnealer<float>;