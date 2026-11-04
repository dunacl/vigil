// Copyright 2026 The Vigil Authors. Licensed under the Apache License, Version 2.0.

/// A fixed-capacity FIFO that overwrites its oldest element when full.
///
/// Storage is allocated once at init and never grows, so appending is O(1)
/// and allocation-free. Iteration yields elements oldest → newest.
public struct RingBuffer<Element: BitwiseCopyable & Sendable>: Sendable {
    private var storage: ContiguousArray<Element>
    /// Index of the next write.
    private var head = 0
    public private(set) var count = 0

    public var capacity: Int { storage.count }
    public var isEmpty: Bool { count == 0 }
    public var isFull: Bool { count == capacity }

    /// - Parameters:
    ///   - capacity: Maximum number of elements (at least 1).
    ///   - filler: Placeholder value for unused slots; never returned.
    public init(capacity: Int, filler: Element) {
        storage = ContiguousArray(repeating: filler, count: Swift.max(1, capacity))
    }

    public mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % storage.count
        if count < storage.count { count += 1 }
    }

    public mutating func removeAll() {
        head = 0
        count = 0
    }

    /// The most recent element.
    public var last: Element? { count > 0 ? storage[(head - 1 + storage.count) % storage.count] : nil }

    /// Element `index` positions from the oldest (0 = oldest, `count - 1` = newest).
    public subscript(index: Int) -> Element {
        precondition(index >= 0 && index < count, "RingBuffer index out of range")
        return storage[(head - count + index + storage.count) % storage.count]
    }

    /// Calls `body` with the elements as up to two contiguous slices
    /// (oldest part first), without copying. Use for drawing graphs.
    public func withContiguousSlices<R>(
        _ body: (UnsafeBufferPointer<Element>, UnsafeBufferPointer<Element>) throws -> R
    ) rethrows -> R {
        try storage.withUnsafeBufferPointer { all in
            let start = (head - count + storage.count) % storage.count
            if start + count <= storage.count {
                return try body(
                    UnsafeBufferPointer(rebasing: all[start..<(start + count)]), .init(start: nil, count: 0))
            }
            let firstLength = storage.count - start
            return try body(
                UnsafeBufferPointer(rebasing: all[start...]),
                UnsafeBufferPointer(rebasing: all[0..<(count - firstLength)]))
        }
    }

    /// Largest element, or `nil` if empty.
    public func max() -> Element? where Element: Comparable {
        withContiguousSlices { first, second in
            switch (first.max(), second.max()) {
            case (let a?, let b?): Swift.max(a, b)
            case (let a?, nil): a
            case (nil, let b): b
            }
        }
    }
}

extension RingBuffer: Sequence {
    public struct Iterator: IteratorProtocol {
        fileprivate let buffer: RingBuffer
        fileprivate var position = 0

        public mutating func next() -> Element? {
            guard position < buffer.count else { return nil }
            defer { position += 1 }
            return buffer[position]
        }
    }

    public func makeIterator() -> Iterator { Iterator(buffer: self) }
    public var underestimatedCount: Int { count }
}
