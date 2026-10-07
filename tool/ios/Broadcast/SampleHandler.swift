import CoreMedia
import Foundation
import ImageIO
import ReplayKit

/// iPhone ekranını ReplayKit ile alır, donanımda H.264'e sıkıştırır ve
/// uzantı içindeki sunucu (8090) üzerinden araç tarayıcısına gönderir.
///
/// Kullanıcı yayını YolcuTV'deki "Yansıtmayı başlat" düğmesinden veya
/// Denetim Merkezi → Ekran Kaydı (uzun bas) → "YolcuTV Yansıtma" yoluyla başlatır.
final class SampleHandler: RPBroadcastSampleHandler {
    private let server = MirrorServer(port: 8090)
    private var encoder: H264Encoder?
    private let lock = NSLock()

    // Uzantı sabit "Dengeli" kalitede çalışır (App Group gerektirmemek için).
    private let maxSize = 1280
    private let bitrate = 4_000_000
    private let fps = 30

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        server.onClientNeedsKeyFrame = { [weak self] in self?.currentEncoder()?.forceKeyFrame() }
        server.start()
        DarwinBus.observe(DarwinBus.stopRequest) { [weak self] in
            let error = NSError(
                domain: "YolcuTV",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Yansıtma YolcuTV'den durduruldu."]
            )
            self?.finishBroadcastWithError(error)
        }
        DarwinBus.post(DarwinBus.started)
    }

    override func broadcastResumed() {
        currentEncoder()?.forceKeyFrame()
    }

    override func broadcastFinished() {
        lock.lock()
        let e = encoder
        encoder = nil
        lock.unlock()
        e?.invalidate()
        server.stop()
        DarwinBus.post(DarwinBus.stopped)
        DarwinBus.removeAll()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        // Ses gönderilmez: ses telefondan veya aracın Bluetooth bağlantısından çıkar.
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let e = currentEncoder() ?? makeEncoder(for: pixelBuffer)

        // ReplayKit görüntüyü her zaman dikey verir; yön bilgisi ekte gelir.
        if let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            server.setRotation(Self.degrees(forOrientation: value.uint32Value))
        }

        e?.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    // MARK: -

    private func currentEncoder() -> H264Encoder? {
        lock.lock()
        defer { lock.unlock() }
        return encoder
    }

    private func makeEncoder(for pixelBuffer: CVPixelBuffer) -> H264Encoder? {
        let e = H264Encoder(
            sourceWidth: CVPixelBufferGetWidth(pixelBuffer),
            sourceHeight: CVPixelBufferGetHeight(pixelBuffer),
            maxSize: maxSize,
            bitrate: bitrate,
            fps: fps
        ) { [weak self] packet in
            self?.server.broadcast(packet)
        }
        lock.lock()
        encoder = e
        lock.unlock()
        return e
    }

    /// Tarayıcının görüntüyü saat yönünde kaç derece döndüreceği.
    /// Eşleme, ReplayKit yayınlarını WebRTC'ye aktaran yaygın açık kaynak projelerle aynıdır.
    /// Gerçek cihazda görüntü ters çıkarsa 90 ile -90'ı yer değiştirmek yeterli.
    static func degrees(forOrientation raw: UInt32) -> Int {
        switch CGImagePropertyOrientation(rawValue: raw) {
        case .some(.left): return 90
        case .some(.right): return -90
        case .some(.down): return 180
        default: return 0
        }
    }
}
