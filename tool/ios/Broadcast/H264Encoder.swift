import CoreMedia
import Foundation
import VideoToolbox

/// ReplayKit karelerini donanım H.264 kodlayıcısıyla sıkıştırır.
/// Çıktı paketi Android sürümüyle birebir aynıdır:
///   [1 bayt anahtar kare bayrağı][8 bayt zaman damgası µs, big-endian][H.264 Annex-B]
final class H264Encoder {
    typealias Output = (Data) -> Void

    let width: Int32
    let height: Int32

    private var session: VTCompressionSession?
    private let output: Output
    private let queue = DispatchQueue(label: "yolcutv.encoder")
    private var forceKey = true
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.invalid
    private var lastEncodeDate = Date.distantPast
    private var timer: DispatchSourceTimer?
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init?(sourceWidth: Int, sourceHeight: Int, maxSize: Int, bitrate: Int, fps: Int, output: @escaping Output) {
        let scale = min(1.0, Double(maxSize) / Double(max(sourceWidth, sourceHeight)))
        width = Int32(Double(sourceWidth) * scale) / 2 * 2
        height = Int32(Double(sourceHeight) * scale) / 2 * 2
        self.output = output

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let s = created else { return nil }
        session = s

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrate))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: fps))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 1))
        // Kısa süreli taşmaları sınırla: saniyede en fazla ortalamanın 1,5 katı bayt.
        let limits = [NSNumber(value: bitrate * 3 / 16), NSNumber(value: 1)] as CFArray
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
        VTCompressionSessionPrepareToEncodeFrames(s)

        startKeyFrameTimer()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        queue.async { self.encodeOnQueue(pixelBuffer, pts: pts) }
    }

    /// Yeni bir izleyici bağlandığında çağrılır.
    func forceKeyFrame() {
        queue.async { self.forceKey = true }
    }

    func invalidate() {
        queue.sync {
            timer?.cancel()
            timer = nil
            if let s = session {
                VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
                VTCompressionSessionInvalidate(s)
            }
            session = nil
            lastPixelBuffer = nil
        }
    }

    // MARK: - Kodlama

    private func encodeOnQueue(_ pixelBuffer: CVPixelBuffer, pts inputPTS: CMTime) {
        guard let s = session else { return }
        var pts = inputPTS
        if lastPTS.isValid && CMTimeCompare(pts, lastPTS) <= 0 {
            pts = CMTimeAdd(lastPTS, CMTime(value: 1, timescale: 1000))
        }
        lastPTS = pts
        lastPixelBuffer = pixelBuffer
        lastEncodeDate = Date()

        var properties: CFDictionary?
        if forceKey {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            forceKey = false
        }
        VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let self = self else { return }
            self.emit(sampleBuffer)
        }
    }

    /// Ekran durağansa ReplayKit yeni kare göndermez. Yeni izleyici anahtar kare
    /// beklerken son kareyi yeniden kodlayarak görüntünün hemen gelmesini sağlar.
    private func startKeyFrameTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in
            guard let self = self,
                  self.forceKey,
                  let pixelBuffer = self.lastPixelBuffer,
                  Date().timeIntervalSince(self.lastEncodeDate) > 0.4 else { return }
            self.encodeOnQueue(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        t.resume()
        timer = t
    }

    // MARK: - AVCC → Annex-B

    private func emit(_ sample: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sample), let block = CMSampleBufferGetDataBuffer(sample) else { return }

        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        var annexB = Data()
        // Anahtar karelerin önüne SPS ve PPS eklenir; yeni bağlanan ekran buradan başlar.
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
            )
            for i in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: i,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                )
                if st == noErr, let p = pointer {
                    annexB.append(contentsOf: Self.startCode)
                    annexB.append(p, count: size)
                }
            }
        }

        let total = CMBlockBufferGetDataLength(block)
        var raw = Data(count: total)
        let copied = raw.withUnsafeMutableBytes { dest -> OSStatus in
            guard let base = dest.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        // VideoToolbox her NAL biriminin önüne 4 baytlık uzunluk koyar; bunları başlangıç koduna çeviriyoruz.
        var offset = 0
        while offset + 4 <= raw.count {
            let length = Int(raw[offset]) << 24 | Int(raw[offset + 1]) << 16
                | Int(raw[offset + 2]) << 8 | Int(raw[offset + 3])
            offset += 4
            guard length > 0, offset + length <= raw.count else { break }
            annexB.append(contentsOf: Self.startCode)
            annexB.append(raw.subdata(in: offset..<(offset + length)))
            offset += length
        }
        guard !annexB.isEmpty else { return }

        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        var ptsMicros = Int64(seconds.isFinite ? seconds * 1_000_000 : 0).bigEndian

        var packet = Data(capacity: 9 + annexB.count)
        packet.append(UInt8(isKey ? 1 : 0))
        withUnsafeBytes(of: &ptsMicros) { packet.append(contentsOf: $0) }
        packet.append(annexB)
        output(packet)
    }
}
