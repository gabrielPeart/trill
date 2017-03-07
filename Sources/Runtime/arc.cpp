//
//  arc.cpp
//  trill
//
//  Created by Harlan Haskins on 3/6/17.
//  Copyright © 2017 Harlan. All rights reserved.
//

#include "arc.h"
#include "trill.h"
#include <cstdlib>
#include <atomic>
#include <mutex>

using namespace trill;

/**
 A RefCountBox contains
  - A retain count
  - A mutex used to synchronize retains and releases
  - A variably-sized payload that is not represented by a data member.

  It is meant as a hidden store for retain count data alongside the allocated
  contents of an indirect type.

  Trill will always see this as:
      [retainCount][mutex][payload]
                          ^~ indirect type "begins" here
 */
struct RefCountBox {
  uint32_t retainCount;
  std::mutex mutex;

  /// Finds the payload by walking to the end of the data members of this box.
  void *value() {
    return reinterpret_cast<void *>(reinterpret_cast<uintptr_t>(this) +
                                    sizeof(RefCountBox));
  }
};

/**
 A convenience struct that performs the arithmetic necessary to work with a
 \c RefCountBox.
 */
struct RefCounted {
public:
  RefCountBox *box;

  /**
   Creates a \c RefCountBox along with a payload of the specific size.
   @param size The size of the underlying payload.
   */
  static RefCountBox *createBox(size_t size) {
    auto boxPtr = trill_alloc(sizeof(RefCountBox) + size);
    auto box = reinterpret_cast<RefCountBox *>(boxPtr);
    box->retainCount = 0;
    return box;
  }

  /**
   Gets a \c RefCounted instance for a given pointer into a box, by offsetting
   the value pointer with the size of the \c RefCountBox.
   
   @param boxValue The payload value underlying a \c RefCountBox.
   */
  RefCounted(void *_Nonnull boxValue) {
    auto boxPtr = reinterpret_cast<uintptr_t>(boxValue) - sizeof(RefCountBox);
    box = reinterpret_cast<RefCountBox *>(boxPtr);
  }

  uint32_t retainCount() {
    std::lock_guard<std::mutex> guard(box->mutex);
    return box->retainCount;
  }

  /**
   Retains the value inside a RefCountBox.
   */
  void retain() {
    std::lock_guard<std::mutex> guard(box->mutex);
    if (box->retainCount == std::numeric_limits<decltype(box->retainCount)>::max()) {
      trill_fatalError("retain count overflow");
    }
    box->retainCount++;
  }

  /**
   Releases the value inside a RefCountBox.
   */
  void release() {
    std::lock_guard<std::mutex> guard(box->mutex);
    if (box->retainCount == 0) {
      trill_fatalError("attempting to release object with retain count 0");
    }
    box->retainCount--;
    if (box->retainCount == 0) {
      dealloc();
    }
  }

  /**
   Deallocates the value inside a RefCountBox.
   */
  void dealloc() {
    std::lock_guard<std::mutex> guard(box->mutex);
    if (box->retainCount > 0) {
      trill_fatalError("object deallocated with retain count > 0");
    }
    free(box->value());
  }
};

void *_Nonnull trill_allocateIndirectType(size_t size) {
  return RefCounted::createBox(size)->value();
}

void trill_retain(void *_Nonnull instance) {
  auto refCounted = RefCounted(instance);
  refCounted.retain();
}

void trill_release(void *_Nonnull instance) {
  auto refCounted = RefCounted(instance);
  refCounted.release();
}