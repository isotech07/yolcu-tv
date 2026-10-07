import Foundation

/// Ana uygulama ile yayın uzantısı ayrı süreçlerdir. Darwin bildirimleri
/// ek yetki (App Group) gerektirmeden süreçler arasında basit sinyal taşır.
enum DarwinBus {
    static let started = "com.yolcutv.mirror.started"
    static let stopped = "com.yolcutv.mirror.stopped"
    static let stopRequest = "com.yolcutv.mirror.stop"

    private final class Token {}
    private static let token = Token()
    private static var handlers: [String: () -> Void] = [:]
    private static let lock = NSLock()

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil, nil, true
        )
    }

    static func observe(_ name: String, _ handler: @escaping () -> Void) {
        lock.lock()
        handlers[name] = handler
        lock.unlock()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(token).toOpaque(),
            { _, _, cfName, _, _ in
                guard let raw = cfName?.rawValue else { return }
                let key = raw as String
                DarwinBus.lock.lock()
                let handler = DarwinBus.handlers[key]
                DarwinBus.lock.unlock()
                DispatchQueue.main.async { handler?() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    static func removeAll() {
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(token).toOpaque()
        )
        lock.lock()
        handlers.removeAll()
        lock.unlock()
    }
}
