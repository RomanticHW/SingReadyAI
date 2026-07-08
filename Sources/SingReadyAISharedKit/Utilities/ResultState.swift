import Foundation

public enum ResultState<Value>: Equatable where Value: Equatable {
    case idle
    case loading
    case success(Value)
    case failure(String)
}

public struct DateProvider: Sendable {
    public var now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }
}

public enum SingReadyLogger {
    public static func log(_ message: String) {
        #if DEBUG
        print("[SingReady] \(message)")
        #endif
    }
}
