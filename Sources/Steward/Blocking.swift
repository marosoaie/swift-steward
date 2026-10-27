import Dispatch
import Foundation

/// Blocking work, such as reading a pipe or a file, kept off Swift
/// concurrency's cooperative pool, whose few threads a blocking read would
/// take away from everything else.
enum Blocking {
    /// Runs `work` on one of Dispatch's global queues and returns what it
    /// returns.
    static func run<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// Runs `body` in an autorelease pool on Darwin: without one per read,
    /// every autoreleased chunk `FileHandle` returns stays alive until the
    /// read loop ends, and streaming holds the whole input.
    static func withAutoreleasePool<Value>(_ body: () throws -> Value) rethrows -> Value {
        #if canImport(Darwin)
        try autoreleasepool(invoking: body)
        #else
        // swift-corelibs-foundation has no autorelease pools to drain.
        try body()
        #endif
    }
}
