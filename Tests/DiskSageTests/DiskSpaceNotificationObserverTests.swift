import Foundation
import Testing
import notify
@testable import DiskSage

@MainActor
struct DiskSpaceNotificationObserverTests {
    @Test func subscribesToTheActualSystemNamesWithoutPostingSystemNotifications() {
        let observer = DiskSpaceNotificationObserver(onEvent: {})
        #expect(observer.status.registeredNames == DiskSpaceNotificationObserver.names)
        #expect(observer.status.failures.isEmpty)
        observer.stop()
    }

    @Test func nativeNotificationDeliveryArrivesOnTheMainActor() async throws {
        let name = "com.abdoeaita.DiskSage.test.\(UUID())"
        let events = AsyncStream<Void>.makeStream()
        let observer = DiskSpaceNotificationObserver(names: [name]) {
            MainActor.assertIsolated()
            events.continuation.yield(())
        }
        defer { observer.stop(); events.continuation.finish() }
        #expect(observer.status.registeredNames == [name])
        #expect(notify_post(name) == NOTIFY_STATUS_OK)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in events.stream { return }
                throw NotificationTimeout()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw NotificationTimeout()
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    @Test(arguments: [false, true])
    func stoppingOrDeinitializingCancelsOnceAndIgnoresAlreadyQueuedCallbacks(deinitialize: Bool) {
        let probe = NotificationProbe()
        var observer: DiskSpaceNotificationObserver? = DiskSpaceNotificationObserver(names: ["ok", "failed"],
            register: { probe.register($0, handler: $1) }, cancel: { probe.cancel($0) }, onEvent: { probe.delivered() })
        #expect(observer?.status.registeredNames == ["ok"])
        #expect(observer?.status.failures == ["failed": 1])
        probe.callbacks[0]()
        #expect(probe.deliveryCount == 1)
        if deinitialize { observer = nil } else { observer?.stop(); observer?.stop() }
        for callback in probe.callbacks { callback() }
        #expect(probe.deliveryCount == 1)
        #expect(probe.cancelledTokens == [42])
    }
}

private struct NotificationTimeout: Error {}

private final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [@MainActor @Sendable () -> Void] = []
    private var cancellations: [Int32] = []
    private var deliveries = 0
    var callbacks: [@MainActor @Sendable () -> Void] { lock.withLock { handlers } }
    var cancelledTokens: [Int32] { lock.withLock { cancellations } }
    var deliveryCount: Int { lock.withLock { deliveries } }
    func register(_ name: String, handler: @escaping @MainActor @Sendable () -> Void) -> DiskSpaceNotificationObserver.Registration {
        lock.withLock { handlers.append(handler) }
        return .init(status: name == "failed" ? 1 : 0, token: name == "failed" ? -1 : 42)
    }
    func cancel(_ token: Int32) { lock.withLock { cancellations.append(token) } }
    func delivered() { lock.withLock { deliveries += 1 } }
}
