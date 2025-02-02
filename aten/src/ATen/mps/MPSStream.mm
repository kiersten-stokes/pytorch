//  Copyright © 2022 Apple Inc.

#include <ATen/mps/MPSAllocatorInterface.h>
#include <ATen/mps/MPSProfiler.h>
#include <ATen/mps/MPSStream.h>

@interface MPSGraphExecutionDescriptor ()
@property(readwrite, atomic) BOOL enableCommitAndContinue;
@end

namespace at {
namespace mps {

//-----------------------------------------------------------------
//  MPSStream
//-----------------------------------------------------------------

MPSStream::MPSStream(Stream stream) : _stream(stream) {
  _commandQueue = [MPSDevice::getInstance()->device() newCommandQueue];
  TORCH_CHECK(_stream.device_type() == DeviceType::MPS);
  _serialQueue = dispatch_queue_create("metal gpu stream", nullptr);
  _executionDescriptor = [MPSGraphExecutionDescriptor new];
  // disable commitAndContinue if Signpost tracing is enabled
  if (getMPSProfiler().isSignpostTracingEnabled()) {
    _enableCommitAndContinue = false;
  }
  _executionDescriptor.enableCommitAndContinue = _enableCommitAndContinue;
}

MPSStream::~MPSStream() {
  [_commandQueue release];
  _commandQueue = nil;
  [_executionDescriptor release];
  _executionDescriptor = nil;

  assert(_commandBuffer == nil);
}

MPSCommandBuffer* MPSStream::commandBuffer() {
  if (!_commandBuffer) {
    _commandBuffer = [MPSCommandBuffer commandBufferFromCommandQueue:_commandQueue].retain;
  }

  return _commandBuffer;
}

id<MTLComputeCommandEncoder> MPSStream::commandEncoder() {
  if (!_commandEncoder) {
    _commandEncoder = [commandBuffer() computeCommandEncoder].retain;
  }

  return _commandEncoder;
}

void MPSStream::synchronize(SyncType syncType) {
  endKernelCoalescing();
  switch (syncType) {
    case SyncType::NONE:
      // typically in GPU to GPU copies we won't commit explicitly
      break;
    case SyncType::COMMIT:
      commit();
      break;
    case SyncType::COMMIT_ADAPTIVE:
      // the adaptive commit only commits if we hit the low watermark memory threshold
      if (getIMPSAllocator()->getLowWatermarkValue() <= 1) {
        commit();
      }
      break;
    case SyncType::COMMIT_AND_WAIT:
      commitAndWait();
      break;
    case SyncType::COMMIT_AND_CONTINUE:
      TORCH_INTERNAL_ASSERT_DEBUG_ONLY(_enableCommitAndContinue,
                                       "CommitAndContinue is called but it is disabled globally!");
      commitAndContinue();
      break;
  }
}

void MPSStream::commit() {
  if (_enableCommitAndContinue) {
    [commandBuffer() commitAndContinue];
  } else {
    flush();
  }
}

void MPSStream::commitAndWait() {
  if (_prevCommandBuffer) {
    // the previous command buffer (if exists) has already been committed,
    // so we just wait until it's completed and then dispose it.
    [_prevCommandBuffer waitUntilCompleted];
    [_prevCommandBuffer release];
    _prevCommandBuffer = nil;
  }

  if (_commandBuffer) {
    if (_enableCommitAndContinue) {
      // no need to release the command buffer with CommitAndContinue
      // This improves the performance by eliminating the overhead of recreating
      // command buffers, and avoiding distruption to commitAndContinue's internal cache
      id<MTLCommandBuffer> rootCommandBuffer = _commandBuffer.rootCommandBuffer;
      [_commandBuffer commitAndContinue];
      [rootCommandBuffer waitUntilCompleted];
    } else {
      [_commandBuffer commit];
      [_commandBuffer waitUntilCompleted];
      [_commandBuffer release];
      _commandBuffer = nil;
    }
  }
}

void MPSStream::commitAndContinue() {
  assert(_commandBuffer);
  [_commandBuffer commitAndContinue];
}

void MPSStream::endKernelCoalescing() {
  if (_commandEncoder) {
    [_commandEncoder endEncoding];
    [_commandEncoder release];
    _commandEncoder = nil;
  }
}

void MPSStream::flush() {
  if (_commandBuffer) {
    [_commandBuffer commit];
    // if commitAndContinue is disabled (e.g., for Profiler), we keep the command
    // buffer so we could wait on it later, if required.
    if (!_enableCommitAndContinue) {
      _prevCommandBuffer = _commandBuffer;
    } else {
      [_commandBuffer release];
    }
    _commandBuffer = nil;
  }
}

void MPSStream::addCompletedHandler(MTLCommandBufferHandler block) {
  dispatch_sync(_serialQueue, ^() {
    @autoreleasepool {
      [commandBuffer() addCompletedHandler:block];
    }
  });
}

void MPSStream::fill(id<MTLBuffer> buffer, uint8_t value, size_t length, size_t offset, SyncType syncType) {
  TORCH_INTERNAL_ASSERT(length >= offset);
  if (length == 0)
    return;
  dispatch_sync(_serialQueue, ^() {
    @autoreleasepool {
      endKernelCoalescing();
      id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer() blitCommandEncoder];

      [blitEncoder fillBuffer:buffer range:NSMakeRange(offset, length) value:value];
      [blitEncoder endEncoding];
      synchronize(syncType);
    }
  });
}

void MPSStream::copy(id<MTLBuffer> srcBuffer,
                     id<MTLBuffer> dstBuffer,
                     size_t length,
                     size_t srcOffset,
                     size_t dstOffset,
                     uint64_t profileId,
                     SyncType syncType) {
  dispatch_sync(_serialQueue, ^() {
    @autoreleasepool {
      endKernelCoalescing();
      id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer() blitCommandEncoder];

      [blitEncoder copyFromBuffer:srcBuffer
                     sourceOffset:(NSUInteger)srcOffset
                         toBuffer:dstBuffer
                destinationOffset:(NSUInteger)dstOffset
                             size:(NSUInteger)length];
      [blitEncoder endEncoding];

      // profilerId has a value only if copy profiling is enabled
      if (profileId) {
        getMPSProfiler().endProfileCopy(profileId, syncType);
      } else {
        synchronize(syncType);
      }
    }
  });
}

void MPSStream::copy_and_sync(id<MTLBuffer> srcBuffer,
                              id<MTLBuffer> dstBuffer,
                              size_t length,
                              size_t srcOffset,
                              size_t dstOffset,
                              bool non_blocking,
                              uint64_t profileId) {
  copy(srcBuffer,
       dstBuffer,
       length,
       srcOffset,
       dstOffset,
       profileId,
       !non_blocking ? SyncType::COMMIT_AND_WAIT : SyncType::COMMIT);
}

void MPSStream::executeMPSGraph(MPSGraph* mpsGraph, NSDictionary* feeds, NSDictionary* results, SyncType syncType) {
  auto& profiler = getMPSProfiler();
  const bool isGraphProfilingEnabled = profiler.isOperationProfilingEnabled();

  dispatch_sync(_serialQueue, ^() {
    endKernelCoalescing();
    if (isGraphProfilingEnabled) {
      // this function call is only relevant for interval-based Signposts
      // which exclude schedule time (only includes GPU run time)
      profiler.beginProfileGPUInterval(mpsGraph);
    }
    // note: CommitAndContinue feature is enabled/disabled via "_executionDescriptor"
    [mpsGraph encodeToCommandBuffer:commandBuffer()
                              feeds:feeds
                   targetOperations:nil
                  resultsDictionary:results
                executionDescriptor:_executionDescriptor];

    SyncType _syncType = syncType;
    // if commitAndContinue is disabled, we need to always commit manually after encoding
    if (!_enableCommitAndContinue && syncType != SyncType::COMMIT_AND_WAIT) {
      _syncType = SyncType::COMMIT;
    }

    // check if graph execution profiling is enabled
    if (isGraphProfilingEnabled) {
      // with profiler enabled, we commit after adding the completedHandler in MPSProfiler
      profiler.endProfileKernel(mpsGraph, _syncType);
    } else {
      synchronize(_syncType);
    }
  });
}

//-----------------------------------------------------------------
//  MPSStreamImpl
//-----------------------------------------------------------------

MPSStream* MPSStreamImpl::_stream = nullptr;

MPSStream* MPSStreamImpl::getInstance() {
  if (_stream == nullptr) {
    _stream = new MPSStream(Stream(Stream::UNSAFE, c10::Device(DeviceType::MPS), 0));
  }
  return _stream;
}

MPSStreamImpl::MPSStreamImpl() {}

MPSStream* getCurrentMPSStream() {
  return getDefaultMPSStream();
}

MPSStream* getDefaultMPSStream() {
  return MPSStreamImpl::getInstance();
}

//-----------------------------------------------------------------
//  MPSEvent
//-----------------------------------------------------------------

MPSEvent::MPSEvent(bool deferInitialization)
    : is_initialized(false), _signalCounter(0), _stream(nil), _event(nil), _listener(nil) {
  if (!deferInitialization) {
    initialize();
  }
}

MPSEvent::~MPSEvent() {
  if (_event) {
    [_event release];
    _event = nil;
  }
  if (_listener) {
    [_listener release];
    _listener = nil;
  }
}

void MPSEvent::initialize() {
  _stream = getDefaultMPSStream();
  _event = [_stream->device() newSharedEvent];
  _listener = [[MTLSharedEventListener alloc] init];
  is_initialized = true;
}

void MPSEvent::recordEvent(bool syncEvent) {
  if (!is_initialized)
    initialize();

  dispatch_sync(_stream->queue(), ^() {
    @autoreleasepool {
      ++_signalCounter;
      id<MTLCommandBuffer> commandBuffer = _stream->commandBuffer();
      [commandBuffer encodeSignalEvent:_event value:_signalCounter];
      if (syncEvent)
        _stream->synchronize(SyncType::COMMIT);
    }
  });
}

void MPSEvent::waitForEvent(bool syncEvent) {
  TORCH_INTERNAL_ASSERT(is_initialized);
  dispatch_sync(_stream->queue(), ^() {
    @autoreleasepool {
      id<MTLCommandBuffer> commandBuffer = _stream->commandBuffer();
      [commandBuffer encodeWaitForEvent:_event value:_signalCounter];
      if (syncEvent)
        _stream->synchronize(SyncType::COMMIT);
    }
  });
}

void MPSEvent::notifyEvent(MTLSharedEventNotificationBlock block) {
  if (!is_initialized)
    initialize();
  dispatch_sync(_stream->queue(), ^() {
    @autoreleasepool {
      ++_signalCounter;
      [_event notifyListener:_listener atValue:_signalCounter block:block];
    }
  });
}

bool MPSEvent::queryEvent() const {
  // return false if not recorded or signaled yet
  return _signalCounter && (_event.signaledValue >= _signalCounter);
}

} // namespace mps
} // namespace at
