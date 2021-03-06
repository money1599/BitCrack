#include <cuda.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <stdlib.h>
#include <stdio.h>

#include "ptx.cuh"
#include "secp256k1.cuh"

#include "sha256.cuh"
#include "ripemd160.cuh"

#include "secp256k1.h"
#include "DeviceContextShared.h"

#define MAX_TARGETS_CONSTANT_MEM 16

#define BLOOM_FILTER_SIZE_WORDS 2048

__constant__ unsigned int _TARGET_HASH[MAX_TARGETS_CONSTANT_MEM][5];
__constant__ unsigned int _NUM_TARGET_HASHES[1];
__constant__ unsigned int *_BLOOM_FILTER[1];
__constant__ unsigned int _USE_BLOOM_FILTER[1];
__constant__ unsigned int _INC_X[8];
__constant__ unsigned int _INC_Y[8];

static bool _useBloomFilter = false;
static unsigned int *_bloomFilterPtr = NULL;

static const unsigned int _RIPEMD160_IV_HOST[5] = {
	0x67452301,
	0xefcdab89,
	0x98badcfe,
	0x10325476,
	0xc3d2e1f0
};

static unsigned int swp(unsigned int x)
{
	return (x << 24) | ((x << 8) & 0x00ff0000) | ((x >> 8) & 0x0000ff00) | (x >> 24);
}

void cleanupTargets()
{
	if(_useBloomFilter) {
		if(_bloomFilterPtr != NULL) {
			cudaFree(_bloomFilterPtr);
			_bloomFilterPtr = NULL;
		}
	}
}

cudaError_t setTargetConstantMemory(const std::vector<struct hash160> &targets)
{
	unsigned int count = targets.size();


	for(int i = 0; i < count; i++) {
		unsigned int h[5];

		// Undo the final round of RIPEMD160 and endian swap to save some computation
		for(int j = 0; j < 5; j++) {
			h[j] = swp(targets[i].h[j]) - _RIPEMD160_IV_HOST[(j + 1) % 5];
		}

		cudaError_t err = cudaMemcpyToSymbol(_TARGET_HASH, h, sizeof(unsigned int) * 5, i * sizeof(unsigned int) * 5);

		if(err) {
			return err;
		}
	}

	cudaError_t err = cudaMemcpyToSymbol(_NUM_TARGET_HASHES, &count, sizeof(unsigned int));
	if(err) {
		return err;
	}

	unsigned int useBloomFilter = 0;

	err = cudaMemcpyToSymbol(_USE_BLOOM_FILTER, &useBloomFilter, sizeof(bool));
	if(err) {
		return err;
	}

	return cudaSuccess;
}

cudaError_t setTargetBloomFilter(const std::vector<struct hash160> &targets)
{
	unsigned int filter[BLOOM_FILTER_SIZE_WORDS];

	cudaError_t err = cudaMalloc(&_bloomFilterPtr, sizeof(unsigned int) *BLOOM_FILTER_SIZE_WORDS);

	if(err) {
		return err;
	}

	memset(filter, 0, sizeof(unsigned int) * BLOOM_FILTER_SIZE_WORDS);
	
	// Use the low 16 bits of each word in the hash as the index into the bloom filter
	for(int i = 0; i < targets.size(); i++) {
	
		for(int j = 0; j < 5; j++) {
			// Undo the final round of RIPEMD160 and endian swap to save some computation
			unsigned int h = swp(targets[i].h[j]) - _RIPEMD160_IV_HOST[(j + 1) % 5];
	
			unsigned int idx = h & 0xffff;
	
			filter[idx / 32] |= (0x01 << (idx % 32));
		}
	}
	
	// Copy to device
	err = cudaMemcpy(_bloomFilterPtr, filter, sizeof(unsigned int) * BLOOM_FILTER_SIZE_WORDS, cudaMemcpyHostToDevice);
	if(err) {
		cudaFree(_bloomFilterPtr);
		_bloomFilterPtr = NULL;
		return err;
	}

	// Copy device memory pointer to constant memory
	err = cudaMemcpyToSymbol(_BLOOM_FILTER, &_bloomFilterPtr, sizeof(unsigned int *));
	if(err) {
		cudaFree(_bloomFilterPtr);
		_bloomFilterPtr = NULL;
		return err;
	}

	unsigned int useBloomFilter = 1;
	err = cudaMemcpyToSymbol(_USE_BLOOM_FILTER, &useBloomFilter, sizeof(unsigned int));

	return err;
}

cudaError_t setTargetHash(const std::vector<struct hash160> &targets)
{
	cleanupTargets();

	if(targets.size() <= MAX_TARGETS_CONSTANT_MEM) {
		return setTargetConstantMemory(targets);
	} else {
		return setTargetBloomFilter(targets);
	}
}



cudaError_t setIncrementorPoint(const secp256k1::uint256 &x, const secp256k1::uint256 &y)
{
	unsigned int xWords[8];
	unsigned int yWords[8];

	x.exportWords(xWords, 8, secp256k1::uint256::BigEndian);
	y.exportWords(yWords, 8, secp256k1::uint256::BigEndian);

	cudaError_t err = cudaMemcpyToSymbol(_INC_X, xWords, sizeof(unsigned int) * 8);
	if(err) {
		return err;
	}

	return cudaMemcpyToSymbol(_INC_Y, yWords, sizeof(unsigned int) * 8);
}

__device__ void hashPublicKey(const unsigned int *x, const unsigned int *y, unsigned int *digestOut)
{
	unsigned int hash[8];

	sha256PublicKey(x, y, hash);

	// Swap to little-endian
	for(int i = 0; i < 8; i++) {
		hash[i] = endian(hash[i]);
	}

	ripemd160sha256NoFinal(hash, digestOut);
}

__device__ void hashPublicKeyCompressed(const unsigned int *x, const unsigned int *y, unsigned int *digestOut)
{
	unsigned int hash[8];

	sha256PublicKeyCompressed(x, y, hash);

	// Swap to little-endian
	for(int i = 0; i < 8; i++) {
		hash[i] = endian(hash[i]);
	}

	ripemd160sha256NoFinal(hash, digestOut);
}

__device__ void addResult(unsigned int *numResultsPtr, void *results, void *info, unsigned int size)
{
	unsigned int count = atomicAdd(numResultsPtr, 1);
	unsigned char *ptr = (unsigned char *)results + count * size;
	memcpy(ptr, info, size);
}

__device__ void setResultFound(unsigned int *numResultsPtr, void *results, int idx, bool compressed, unsigned int x[8], unsigned int y[8], unsigned int digest[5])
{
	struct KeyFinderDeviceResult r;

	r.block = blockIdx.x;
	r.thread = threadIdx.x;
	r.idx = idx;
	r.compressed = compressed;

	for(int i = 0; i < 8; i++) {
		r.x[i] = x[i];
		r.y[i] = y[i];
	}

	for(int i = 0; i < 5; i++) {
		r.digest[i] = endian(digest[i] + _RIPEMD160_IV[(i + 1) % 5]);
	}
	addResult(numResultsPtr, results, &r, sizeof(r));
}

__device__ bool checkHash(unsigned int hash[5])
{
	bool foundMatch = false;

	if(*_USE_BLOOM_FILTER) {
		foundMatch = true;
		for(int i = 0; i < 5; i++) {
			unsigned int idx = hash[i] & 0xffff;

			unsigned int f = ((unsigned int *)(_BLOOM_FILTER[0]))[idx / 32];
			if((f & (0x01 << (idx % 32))) == 0) {
				foundMatch = false;
			}
		}
	} else {
		for(int j = 0; j < *_NUM_TARGET_HASHES; j++) {
			bool equal = true;
			for(int i = 0; i < 5; i++) {
				equal &= (hash[i] == _TARGET_HASH[j][i]);
			}
			foundMatch |= equal;
		}
	}

	return foundMatch;
}

__device__ void doIteration(unsigned int *xPtr, unsigned int *yPtr, unsigned int *chain, int pointsPerThread, unsigned int *numResults, void *results, int compression)
{
	// Multiply together all (_Gx - x) and then invert
	unsigned int inverse[8] = { 0,0,0,0,0,0,0,1 };
	for(int i = 0; i < pointsPerThread; i++) {
		unsigned int x[8];
		unsigned int y[8];
		unsigned int digest[5];

		readInt(xPtr, i, x);
		readInt(yPtr, i, y);

		if(compression == PointCompressionType::UNCOMPRESSED || compression == PointCompressionType::BOTH) {
			hashPublicKey(x, y, digest);

			if(checkHash(digest)) {
				setResultFound(numResults, results, i, false, x, y, digest);
			}
		}

		if(compression == PointCompressionType::COMPRESSED || compression == PointCompressionType::BOTH) {
			hashPublicKeyCompressed(x, y, digest);

			if(checkHash(digest)) {
				setResultFound(numResults, results, i, true, x, y, digest);
			}
		}

		beginBatchAdd(_INC_X, xPtr, chain, i, inverse);
	}

	doBatchInverse(inverse);

	for(int i = pointsPerThread - 1; i >= 0; i--) {

		unsigned int newX[8];
		unsigned int newY[8];

		completeBatchAdd(_INC_X, _INC_Y, xPtr, yPtr, i, chain, inverse, newX, newY);

		writeInt(xPtr, i, newX);
		writeInt(yPtr, i, newY);
	}
}

__device__ void doIterationWithDouble(unsigned int *xPtr, unsigned int *yPtr, unsigned int *chain, int pointsPerThread, unsigned int *numResults, void *results, int compression)
{
	// Multiply together all (_Gx - x) and then invert
	unsigned int inverse[8] = { 0,0,0,0,0,0,0,1 };
	for(int i = 0; i < pointsPerThread; i++) {
		unsigned int x[8];
		unsigned int y[8];
		unsigned int digest[5];

		readInt(xPtr, i, x);
		readInt(yPtr, i, y);

		// uncompressed
		if(compression == 1 || compression == 2) {
			hashPublicKey(x, y, digest);

			if(checkHash(digest)) {
				setResultFound(numResults, results, i, false, x, y, digest);
			}
		}

		// compressed
		if(compression == 0 || compression == 2) {
			hashPublicKeyCompressed(x, y, digest);

			if(checkHash(digest)) {
				setResultFound(numResults, results, i, true, x, y, digest);
			}
		}

		beginBatchAddWithDouble(_INC_X, _INC_Y, xPtr, chain, i, inverse);
	}

	doBatchInverse(inverse);

	for(int i = pointsPerThread - 1; i >= 0; i--) {

		unsigned int newX[8];
		unsigned int newY[8];

		completeBatchAddWithDouble(_INC_X, _INC_Y, xPtr, yPtr, i, chain, inverse, newX, newY);

		writeInt(xPtr, i, newX);
		writeInt(yPtr, i, newY);
	}
}

/**
* Performs a single iteration
*/
__global__ void keyFinderKernel(int points, unsigned int *x, unsigned int *y, unsigned int *chain, unsigned int *numResults, void *results, int compression)
{
	doIteration(x, y, chain, points, numResults, results, compression);
}

__global__ void keyFinderKernelWithDouble(int points, unsigned int *x, unsigned int *y, unsigned int *chain, unsigned int *numResults, void *results, int compression)
{
	doIterationWithDouble(x, y, chain, points, numResults, results, compression);
}