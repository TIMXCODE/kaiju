import Foundation

/// Thin wrapper over `os_unfair_lock`. Used on the capture/encode hot path where
/// an `NSLock` allocation and its objc dispatch are measurable.
public final class UnfairLock: @unchecked Sendable {
    // `@usableFromInline` rather than `private`: the accessors below are
    // `@inlinable` so this lock costs nothing across the module boundary on the
    // capture hot path, and an inlinable body may only touch internal-or-better state.
    @usableFromInline let storage: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        storage = .allocate(capacity: 1)
        storage.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    @inlinable public func lock() { os_unfair_lock_lock(storage) }
    @inlinable public func unlock() { os_unfair_lock_unlock(storage) }

    @inlinable
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(storage)
        defer { os_unfair_lock_unlock(storage) }
        return try body()
    }
}

/// A value guarded by an `UnfairLock`.
public final class Guarded<Value>: @unchecked Sendable {
    private let lock = UnfairLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value { lock.withLock { value } }
}
