import Foundation

/// A tiny amortised-O(1) deque backed by a single `ContiguousArray`.
///
/// The replay ring appends one record per encoded frame and drops records from
/// the front as they age out. `Array.removeFirst()` is O(n), which at 60 fps for
/// hours is not acceptable, and pulling in swift-collections for one type isn't
/// worth a third-party dependency. So: append to the tail, advance a head index,
/// and compact only when the dead prefix is worth reclaiming.
public struct RecordDeque<Element> {
    @usableFromInline var storage: ContiguousArray<Element> = []
    @usableFromInline var head: Int = 0

    public init(minimumCapacity: Int = 0) {
        if minimumCapacity > 0 { storage.reserveCapacity(minimumCapacity) }
    }

    @inlinable public var count: Int { storage.count - head }
    @inlinable public var isEmpty: Bool { count == 0 }

    @inlinable
    public subscript(index: Int) -> Element {
        get { storage[head + index] }
        set { storage[head + index] = newValue }
    }

    @inlinable public var first: Element? { isEmpty ? nil : storage[head] }
    @inlinable public var last: Element? { isEmpty ? nil : storage[storage.count - 1] }

    @inlinable
    public mutating func append(_ element: Element) {
        storage.append(element)
    }

    @discardableResult
    @inlinable
    public mutating func removeFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        compactIfNeeded()
        return element
    }

    @inlinable
    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }

    @usableFromInline
    mutating func compactIfNeeded() {
        // Reclaim once the dead prefix is both large in absolute terms and at
        // least half the array, so compaction cost stays amortised constant.
        if head >= 1024 && head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Index of the last element for which `predicate` is true, assuming the
    /// deque is sorted such that the predicate is true for a prefix.
    @inlinable
    public func lastIndex(wherePrefix predicate: (Element) -> Bool) -> Int? {
        var low = 0
        var high = count - 1
        var result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    /// Index of the first element for which `predicate` is true, assuming the
    /// predicate is false for a prefix and true for the rest.
    @inlinable
    public func firstIndex(whereSuffix predicate: (Element) -> Bool) -> Int? {
        var low = 0
        var high = count - 1
        var result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if predicate(self[mid]) {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return result
    }
}
