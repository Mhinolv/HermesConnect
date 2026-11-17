import Foundation
import os

/// The one log of the app (issue #18). It writes to the unified system log, and tests can watch it.
///
/// Rule: a log message contains only metadata (ids, counts, states, algorithm names). Never pass message
/// text, transcripts, file names, tokens or key material. `LogPrivacyTests` fail if a message body shows up.
public struct HermesLog: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug, info, notice, error

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Entry: Sendable, Equatable {
        public var level: Level
        public var category: String
        public var message: String
    }

    public static let subsystem = "HermesConnect"

    public let category: String
    private let logger: Logger

    public init(category: String) {
        self.category = category
        logger = Logger(subsystem: Self.subsystem, category: category)
    }

    public func debug(_ message: @autoclosure () -> String) { write(.debug, message()) }
    public func info(_ message: @autoclosure () -> String) { write(.info, message()) }
    public func notice(_ message: @autoclosure () -> String) { write(.notice, message()) }
    public func error(_ message: @autoclosure () -> String) { write(.error, message()) }

    private func write(_ level: Level, _ message: String) {
        // The message is metadata only (see the rule above), so it can be public in the system log.
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        Self.observers.send(Entry(level: level, category: category, message: message))
    }

    // MARK: Observers (tests)

    /// Calls `observer` for each entry until `removeObserver` runs. For tests.
    @discardableResult
    public static func addObserver(_ observer: @escaping @Sendable (Entry) -> Void) -> UUID {
        observers.add(observer)
    }

    public static func removeObserver(_ id: UUID) { observers.remove(id) }

    private static let observers = Observers()

    private final class Observers: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [UUID: @Sendable (Entry) -> Void] = [:]

        func add(_ observer: @escaping @Sendable (Entry) -> Void) -> UUID {
            let id = UUID()
            lock.withLock { items[id] = observer }
            return id
        }

        func remove(_ id: UUID) { _ = lock.withLock { items.removeValue(forKey: id) } }

        func send(_ entry: Entry) {
            let current = lock.withLock { Array(items.values) }
            for observer in current { observer(entry) }
        }
    }
}
