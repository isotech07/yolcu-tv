import Flutter
import ReplayKit
import UIKit

/// Flutter tarafındaki ScreenMirror ile iOS yayın uzantısı arasındaki köprü.
/// Android'deki MainActivity ile aynı kanal adlarını kullanır, böylece Dart kodu ortaktır.
///
/// AppDelegate'e kurulum betiği tarafından tek satırla bağlanır:
///   YolcuMirrorBridge.register(with: <GeneratedPluginRegistrant'a verilen kayıt>)
final class YolcuMirrorBridge: NSObject, FlutterStreamHandler {
    static let shared = YolcuMirrorBridge()
    static let extensionSuffix = ".Broadcast"

    private var sink: FlutterEventSink?
    private var picker: RPSystemBroadcastPickerView?
    private var running = false

    static func register(with registry: FlutterPluginRegistry) {
        guard let registrar = registry.registrar(forPlugin: "YolcuMirrorBridge") else { return }
        let messenger = registrar.messenger()

        let methods = FlutterMethodChannel(name: "yolcutv/screen", binaryMessenger: messenger)
        methods.setMethodCallHandler { call, result in
            shared.handle(call, result: result)
        }
        let events = FlutterEventChannel(name: "yolcutv/screen/events", binaryMessenger: messenger)
        events.setStreamHandler(shared)
        shared.observe()
    }

    // MARK: - Flutter

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "start":
            showPicker()
            result(true)
        case "stop":
            DarwinBus.post(DarwinBus.stopRequest)
            result(true)
        case "isRunning":
            result(running)
        case "requestKeyFrame":
            result(nil) // uzantı kendisi yönetir
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        if running { events("started") }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    // MARK: - Uzantı durumu

    private func observe() {
        DarwinBus.observe(DarwinBus.started) { [weak self] in self?.update(true) }
        DarwinBus.observe(DarwinBus.stopped) { [weak self] in self?.update(false) }

        // Uygulama askıdayken kaçan "durdu" bildirimini telafi et.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.running, !UIScreen.main.isCaptured else { return }
            self.update(false)
        }
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.running, !UIScreen.main.isCaptured else { return }
            self.update(false)
        }
    }

    private func update(_ on: Bool) {
        guard running != on else { return }
        running = on
        sink?(on ? "started" : "stopped")
    }

    // MARK: - Sistem yayın penceresi

    /// iOS, yayını yalnızca kullanıcının onayıyla başlatır. Görünmez bir
    /// RPSystemBroadcastPickerView ekleyip düğmesine basarak sistem penceresini açıyoruz;
    /// kullanıcı orada "Yayını Başlat"a dokunur.
    private func showPicker() {
        DispatchQueue.main.async {
            let picker = self.picker ?? RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
            picker.preferredExtension = (Bundle.main.bundleIdentifier ?? "") + Self.extensionSuffix
            picker.showsMicrophoneButton = false
            picker.alpha = 0.011
            if picker.superview == nil {
                Self.keyWindow()?.addSubview(picker)
            }
            self.picker = picker
            Self.findButton(in: picker)?.sendActions(for: .allTouchEvents)
        }
    }

    private static func findButton(in view: UIView) -> UIButton? {
        for subview in view.subviews {
            if let button = subview as? UIButton { return button }
            if let button = findButton(in: subview) { return button }
        }
        return nil
    }

    private static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}
