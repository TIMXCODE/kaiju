import Foundation

/// A fixed-size circular byte arena.
///
/// This is the thing that makes the replay buffer's memory behaviour flat. One
/// allocation happens at `init`; after that every encoded frame is memcpy'd into
/// the same region and old bytes are overwritten in place. No per-frame `Data`
/// allocation, no allocator churn, no growth over a six-hour session.
///
/// Positions are expressed as *absolute* offsets: a monotonically increasing
/// count of every byte ever written. A record at absolute offset `o` with length
/// `n` is still readable while `o >= writeCursor - capacity`. That makes
/// eviction a comparison instead of any kind of bookkeeping.
public final class ByteRing: @unchecked Sendable {
    public let capacity: Int
    private let base: UnsafeMutableRawPointer
    private(set) public var writeCursor: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "ByteRing capacity must be positive")
        self.capacity = capacity
        self.base = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit { base.deallocate() }

    /// Absolute offset of the oldest byte that is still intact.
    public var oldestValidOffset: Int { max(0, writeCursor - capacity) }

    /// Number of live bytes currently held.
    public var used: Int { min(writeCursor, capacity) }

    public func reset() { writeCursor = 0 }

    public func contains(absoluteOffset: Int, length: Int) -> Bool {
        absoluteOffset >= oldestValidOffset && absoluteOffset + length <= writeCursor
    }

    /// Copies `bytes` into the ring, overwriting the oldest content as needed.
    /// Returns the absolute offset the data was written at, or `nil` if a single
    /// write is larger than the whole ring (which means the ring is misconfigured).
    @discardableResult
    public func append(_ bytes: UnsafeRawBufferPointer) -> Int? {
        guard let src = bytes.baseAddress else { return writeCursor }
        let length = bytes.count
        guard length > 0 else { return writeCursor }
        guard length <= capacity else { return nil }

        let start = writeCursor
        let physical = start % capacity
        let firstChunk = min(length, capacity - physical)
        base.advanced(by: physical).copyMemory(from: src, byteCount: firstChunk)
        if firstChunk < length {
            base.copyMemory(from: src.advanced(by: firstChunk), byteCount: length - firstChunk)
        }
        writeCursor = start + length
        return start
    }

    @discardableResult
    public func append(_ data: Data) -> Int? {
        data.withUnsafeBytes { append($0) }
    }

    /// Copies `length` bytes starting at `absoluteOffset` into `destination`.
    /// Returns false if that range has already been overwritten.
    @discardableResult
    public func read(absoluteOffset: Int, length: Int, into destination: UnsafeMutableRawPointer) -> Bool {
        guard contains(absoluteOffset: absoluteOffset, length: length) else { return false }
        guard length > 0 else { return true }
        let physical = absoluteOffset % capacity
        let firstChunk = min(length, capacity - physical)
        destination.copyMemory(from: base.advanced(by: physical), byteCount: firstChunk)
        if firstChunk < length {
            destination.advanced(by: firstChunk)
                .copyMemory(from: base, byteCount: length - firstChunk)
        }
        return true
    }

    /// Convenience read into a fresh `Data`. Used only when extracting a clip,
    /// never on the capture hot path.
    public func read(absoluteOffset: Int, length: Int) -> Data? {
        guard contains(absoluteOffset: absoluteOffset, length: length) else { return nil }
        var data = Data(count: length)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let dst = raw.baseAddress else { return false }
            return read(absoluteOffset: absoluteOffset, length: length, into: dst)
        }
        return ok ? data : nil
    }
}
