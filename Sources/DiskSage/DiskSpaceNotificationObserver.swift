import Dispatch
import Foundation
import notify

/// System warnings are hints: callers must still check capacity and cleanup policy.
final class DiskSpaceNotificationObserver: @unchecked Sendable {
    static let names = ["com.apple.system.lowdiskspace", "com.apple.system.lowdiskspace.system", "com.apple.system.lowdiskspace.user"]

    struct Status: Codable, Equatable, Sendable {
        var registeredNames: [String] = []
        var failures: [String: UInt32] = [:]
    }
    struct Registration: Sendable {
        let status: UInt32
        let token: Int32
    }
    typealias Register = @Sendable (String, @escaping @MainActor @Sendable () -> Void) -> Registration
    typealias Cancel = @Sendable (Int32) -> Void

    let status: Status
    private let delivery: NotificationDeliveryGate
    private let cancel: Cancel
    private let lock = NSLock()
    private var tokens: [Int32]

    init(names: [String] = names, register: Register = { registerNative($0, handler: $1) },
         cancel: @escaping Cancel = { _ = notify_cancel($0) },
         onEvent: @escaping @MainActor @Sendable () -> Void) {
        let delivery = NotificationDeliveryGate()
        var status = Status(), tokens: [Int32] = []
        for name in names {
            let registration = register(name) {
                guard delivery.isActive else { return }
                onEvent()
            }
            if registration.status == NOTIFY_STATUS_OK {
                status.registeredNames.append(name)
                tokens.append(registration.token)
            } else {
                status.failures[name] = registration.status
            }
        }
        self.status = status
        self.tokens = tokens
        self.delivery = delivery
        self.cancel = cancel
    }

    func stop() {
        delivery.cancel()
        let cancelled = lock.withLock {
            let cancelled = tokens
            tokens = []
            return cancelled
        }
        for token in cancelled { cancel(token) }
    }

    deinit { stop() }

    private static func registerNative(_ name: String, handler: @escaping @MainActor @Sendable () -> Void) -> Registration {
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        return Registration(status: status, token: token)
    }
}

private final class NotificationDeliveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func cancel() { lock.withLock { active = false } }
}
