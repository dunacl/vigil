// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

import Testing

@testable import VigilCore

@Suite struct RingBufferTests {
    @Test func keepsInsertionOrderUntilFull() {
        var buffer = RingBuffer<Float>(capacity: 4, filler: 0)
        for value: Float in [1, 2, 3] { buffer.append(value) }
        #expect(Array(buffer) == [1, 2, 3])
        #expect(buffer.count == 3)
        #expect(!buffer.isFull)
        #expect(buffer.last == 3)
    }

    @Test func overwritesOldestWhenFull() {
        var buffer = RingBuffer<Float>(capacity: 3, filler: 0)
        for value: Float in [1, 2, 3, 4, 5] { buffer.append(value) }
        #expect(Array(buffer) == [3, 4, 5])
        #expect(buffer[0] == 3)
        #expect(buffer[2] == 5)
        #expect(buffer.isFull)
    }

    @Test func contiguousSlicesCoverAllElementsInOrder() {
        var buffer = RingBuffer<Int32>(capacity: 4, filler: 0)
        for value: Int32 in 1...6 { buffer.append(value) }  // wrapped: storage [5, 6, 3, 4]
        let joined = buffer.withContiguousSlices { Array($0) + Array($1) }
        #expect(joined == [3, 4, 5, 6])
    }

    @Test func maxAcrossTheWrap() {
        var buffer = RingBuffer<Float>(capacity: 3, filler: 0)
        #expect(buffer.max() == nil)
        for value: Float in [9, 1, 2, 3] { buffer.append(value) }  // 9 has been overwritten
        #expect(buffer.max() == 3)
    }

    @Test func emptyAndReset() {
        var buffer = RingBuffer<Float>(capacity: 0, filler: 0)
        #expect(buffer.capacity == 1)
        #expect(buffer.last == nil)
        buffer.append(7)
        buffer.removeAll()
        #expect(buffer.isEmpty)
        #expect(Array(buffer).isEmpty)
    }
}
