import Foundation
import CoreMedia
import CoreVideo
import CoreImage
import VideoToolbox

/// 视频转码器：任意来源（CarPlay 流 / 整屏广播）→ 解码 → 缩放 → 按
/// 极核仪表验证过的参数重编码（1024×480 @25fps / 2.5Mbps / H.264 Baseline，
/// 首帧强制 IDR）。与 CarWithin 实测兼容的出帧规格一致。
final class CPVideoTranscoder {

    enum ScaleMode {
        case fit    // 完整画面，上下留黑边
        case crop   // 居中裁出横幅窗口填满仪表（竖屏导航信息区）
    }

    let width = 1024
    let height = 480
    let fps: Double = 25
    let bitrate: Int = 2_500_000

    var scaleMode: ScaleMode = .fit

    // 解码状态
    private let decodeQueue = DispatchQueue(label: "cp.transcode.decode")
    private var decoder: VTDecompressionSession?
    private var decoderFormat: CMVideoFormatDescription?
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDirty = false

    // 最新画面
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var bufferFresh = false
    private var frameCounter = 0

    // 编码状态
    private let encodeLock = NSLock()
    private var encoder: VTCompressionSession?
    private var encoderParamSets: [Data]?
    private var encodedResult: Result<Data, Error>?
    private lazy var compositor = CIContext(options: [.useSoftwareRenderer: true,
                                                      .cacheIntermediates: false])
    private var lastCodecFailure: TimeInterval = -1000

    // MARK: - 输入：CarPlay Annex-B 访问单元

    func appendAnnexB(_ accessUnit: Data) {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.decodeAnnexB(accessUnit)
        }
    }

    /// 输入：广播扩展的系统编码帧（带格式描述的 CMSampleBuffer）。
    func append(sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        decodeQueue.async { [weak self] in
            guard let self else { return }
            self.decode(sampleBuffer: sampleBuffer, format: format as CMVideoFormatDescription)
        }
    }

    // MARK: - 输出：拉帧时同步重编码

    /// 编码最新画面；首帧（或强制）带 IDR。返回 Annex-B 访问单元。
    /// 输出回调异步到达：提交后短轮询取结果（不持锁等待，避免死锁）。
    func encodeLatest(forceKeyframe: Bool) -> Data? {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastCodecFailure >= 0.5 else { return nil }
        bufferLock.lock()
        let image = latestBuffer
        bufferLock.unlock()
        guard let image else { return nil }

        encodeLock.lock()
        var session: VTCompressionSession?
        var presentation = CMTime()
        do {
            session = try ensureEncoder()
            let scaled = try fittedBuffer(image)
            var force = forceKeyframe
            if encoderParamSets == nil { force = true }
            presentation = CMTime(seconds: now, preferredTimescale: 1_000)
            encodedResult = nil
            let status = VTCompressionSessionEncodeFrame(
                session!,
                imageBuffer: scaled,
                presentationTimeStamp: presentation,
                duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
                frameProperties: force
                    ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                    : nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil)
            guard status == noErr else {
                throw CPError.malformed("编码帧失败（\(status)）")
            }
            VTCompressionSessionCompleteFrames(session!, untilPresentationTimeStamp: presentation)
        } catch CPError.malformed {
            encodeLock.unlock()
            return nil // 帧丢弃类错误静默（编码器忙）
        } catch {
            encodeLock.unlock()
            invalidateEncoder()
            lastCodecFailure = ProcessInfo.processInfo.systemUptime
            MirrorLogStore.append("重编码失败：\(error.localizedDescription)")
            return nil
        }
        encodeLock.unlock()

        // 短轮询等待输出回调（回调线程自行持锁写结果）
        var result: Result<Data, Error>?
        for _ in 0..<40 where result == nil {
            encodeLock.lock()
            result = encodedResult
            encodeLock.unlock()
            if result == nil {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        switch result {
        case .success(let data): return data
        case .failure: return nil
        case nil: return nil
        }
    }

    /// 预览用：取最新解码帧（buffer 与递增帧号；帧号用于预览层去重）。
    func snapshotForDisplay() -> (buffer: CVPixelBuffer, frame: Int)? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let buffer = latestBuffer else { return nil }
        return (buffer, frameCounter)
    }

    func invalidate() {
        decodeQueue.async { [weak self] in
            guard let self else { return }
            if let decoder = self.decoder { VTDecompressionSessionInvalidate(decoder) }
            self.decoder = nil
            self.decoderFormat = nil
            self.vps = nil
            self.sps = nil
            self.pps = nil
            self.bufferLock.lock()
            self.latestBuffer = nil
            self.bufferFresh = false
            self.bufferLock.unlock()
        }
        invalidateEncoder()
    }

    // MARK: - 解码

    private func decodeAnnexB(_ accessUnit: Data) {
        guard let units = try? CPAnnexB.units(in: accessUnit) else { return }
        var picture: [Data] = []
        for unit in units {
            switch codecRole(unit) {
            case .vps: if vps != unit { vps = unit; formatDirty = true }
            case .sps: if sps != unit { sps = unit; formatDirty = true }
            case .pps: if pps != unit { pps = unit; formatDirty = true }
            case nil: picture.append(unit)
            }
        }
        guard !picture.isEmpty, sps != nil, pps != nil else { return }
        if decoder == nil || formatDirty {
            guard buildDecoder() else { return }
        }
        guard let decoder, let format = decoderFormat else { return }
        // Annex-B → AVCC（4 字节长度前缀）打包为 CMSampleBuffer
        var avcc = Data()
        for unit in picture {
            avcc.putBE32(UInt32(unit.count))
            avcc.append(unit)
        }
        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &blockBuffer)
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return }
        let fillStatus = avcc.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard fillStatus == kCMBlockBufferNoErr else { return }
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMTime(seconds: ProcessInfo.processInfo.systemUptime,
                                          preferredTimescale: 1_000),
            decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: blockBuffer,
                                        formatDescription: format,
                                        sampleCount: 1,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sample = sampleBuffer else { return }
        decode(sampleBuffer: sample, format: format)
    }

    private enum CodecRole { case vps, sps, pps }

    private func codecRole(_ unit: Data) -> CodecRole? {
        guard let first = unit.first else { return nil }
        switch first & 0x1f {
        case 7: return .sps
        case 8: return .pps
        default: return nil
        }
    }

    private func buildDecoder() -> Bool {
        formatDirty = false
        guard let sps, let pps else { return false }
        if let old = decoder { VTDecompressionSessionInvalidate(old); self.decoder = nil }
        var format: CMVideoFormatDescription?
        var sets: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        let payloads = [sps, pps]
        for payload in payloads {
            let length = payload.count
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
            payload.copyBytes(to: pointer, count: length)
            sets.append(UnsafePointer(pointer))
            sizes.append(length)
        }
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: sets.count,
            parameterSetPointers: &sets,
            parameterSetSizes: &sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &format)
        for pointer in sets { UnsafeMutablePointer(mutating: pointer).deallocate() }
        guard status == noErr, let format else {
            MirrorLogStore.append("构建 H.264 解码描述失败（\(status)）")
            return false
        }
        decoderFormat = format
        // 解码输出经逐帧 completionHandler 回来，会话不挂全局回调
        var session: VTDecompressionSession?
        let decodeStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true] as CFDictionary,
            imageBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferOpenGLCompatibilityKey: true,
            ] as CFDictionary,
            decompressionSessionOut: &session)
        guard decodeStatus == noErr, let session else {
            MirrorLogStore.append("创建解码会话失败（\(decodeStatus)）")
            return false
        }
        self.decoder = session
        return true
    }

    private func decode(sampleBuffer: CMSampleBuffer, format: CMVideoFormatDescription) {
        guard let decoder = self.decoder else { return }
        // kVTDecodeFrame_EnableAsynchronousDecompression = 1 << 0
        let infoFlags = VTDecodeFrameFlags(rawValue: 1 << 0)
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            decoder,
            sampleBuffer: sampleBuffer,
            flags: infoFlags,
            infoFlagsOut: &flagsOut,
            completionHandler: { [weak self] status, _, imageBuffer, _, _, _ in
                guard status == noErr, let imageBuffer else { return }
                self?.store(imageBuffer: imageBuffer)
            })
        if status != noErr {
            MirrorLogStore.append("解码失败（\(status)）")
            // 解码器失效时从关键帧重建
            if status == kVTVideoDecoderMalfunctionErr {
                invalidate()
            }
        }
    }

    private func store(imageBuffer: CVBuffer) {
        bufferLock.lock()
        latestBuffer = imageBuffer as CVPixelBuffer
        bufferFresh = true
        frameCounter &+= 1
        bufferLock.unlock()
    }

    // MARK: - 缩放

    private func fittedBuffer(_ image: CVPixelBuffer) throws -> CVPixelBuffer {
        let sourceWidth = CVPixelBufferGetWidth(image)
        let sourceHeight = CVPixelBufferGetHeight(image)
        if sourceWidth == width, sourceHeight == height { return image }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:] ] as CFDictionary,
                                         &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw CPError.malformed("分配缩放画面失败（\(status)）")
        }
        let source = CIImage(cvPixelBuffer: image)
        let transformed: CIImage
        switch scaleMode {
        case .fit:
            let scale = min(CGFloat(width) / source.extent.width,
                            CGFloat(height) / source.extent.height)
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            transformed = scaled.transformed(by: CGAffineTransform(
                translationX: (CGFloat(width) - scaled.extent.width) / 2,
                y: (CGFloat(height) - scaled.extent.height) / 2))
        case .crop:
            // 居中裁出与仪表同比例的横幅窗口再缩放（竖屏导航信息区）
            let targetRatio = CGFloat(width) / CGFloat(height)
            let cropHeight = min(CGFloat(sourceHeight), CGFloat(sourceWidth) / targetRatio)
            let cropWidth = cropHeight * targetRatio
            let originX = (source.extent.width - cropWidth) / 2
            let originY = (source.extent.height - cropHeight) / 2
            let cropped = source.cropped(to: CGRect(x: originX, y: originY,
                                                    width: cropWidth, height: cropHeight))
            let scale = CGFloat(width) / cropWidth
            transformed = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        compositor.render(transformed.composited(over: CIImage(color: .black)),
                          to: buffer,
                          bounds: CGRect(x: 0, y: 0, width: width, height: height),
                          colorSpace: CGColorSpaceCreateDeviceRGB())
        return buffer
    }

    // MARK: - 编码

    private func ensureEncoder() throws -> VTCompressionSession {
        if let encoder { return encoder }
        var session: VTCompressionSession?
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: VTCompressionOutputCallback = { refCon, _, status, flags, sampleBuffer in
            guard let refCon, status == noErr, let sampleBuffer else { return }
            Unmanaged<CPVideoTranscoder>.fromOpaque(refCon).takeUnretainedValue()
                .handleEncoded(sampleBuffer: sampleBuffer.takeUnretainedValue(), flags: flags)
        }
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refcon,
            compressionSessionOut: &session)
        guard status == noErr, let session else {
            throw CPError.malformed("创建编码会话失败（\(status)）")
        }
        // 压缩属性须在创建后通过 VTSessionSetProperties 设置
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
        ]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr,
              VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            throw CPError.malformed("编码会话配置失败")
        }
        encoder = session
        encoderParamSets = nil
        return session
    }

    private func invalidateEncoder() {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        encoder = nil
        encoderParamSets = nil
        encodedResult = nil
    }

    private func handleEncoded(sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        do {
            let data = try Self.annexB(fromEncoded: sampleBuffer, cachedParamSets: &encoderParamSets)
            encodedResult = .success(data)
        } catch {
            encodedResult = .failure(error)
        }
    }

    /// 编码输出 → Annex-B 访问单元（IDR 前置 SPS/PPS）。
    private static func annexB(fromEncoded sampleBuffer: CMSampleBuffer,
                               cachedParamSets: inout [Data]?) throws -> Data {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw CPError.malformed("编码输出缺格式描述")
        }
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first {
            isKeyframe = (first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool) == false
        } else {
            isKeyframe = false
        }
        var output = Data()
        if isKeyframe {
            // 从编码器格式描述取 SPS/PPS（数量可能随会话变化）
            var sets: [Data] = []
            var index: Int = 0
            while true {
                var size = 0
                var headerLength: Int32 = 0
                var pointer: UnsafePointer<UInt8>?
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: &headerLength) == noErr,
                    let pointer, size > 0 else { break }
                sets.append(Data(bytes: pointer, count: size))
                index += 1
            }
            if sets.count >= 2 { cachedParamSets = sets }
            for set in cachedParamSets ?? sets {
                output.append(contentsOf: [0, 0, 0, 1])
                output.append(set)
            }
        }
        // 载荷：AVCC → Annex-B
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw CPError.malformed("编码输出缺数据块")
        }
        let total = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: total)
        let copied = bytes.withUnsafeMutableBytes { pointer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total,
                                       destination: pointer.baseAddress!)
        }
        guard copied == kCMBlockBufferNoErr else { throw CPError.malformed("编码输出读取失败") }
        var offset = 0
        while offset + 4 <= total {
            let length = Int(bytes.be32(offset))
            offset += 4
            guard length > 0, offset + length <= total else { throw CPError.malformed("编码 NAL 长度") }
            output.append(contentsOf: [0, 0, 0, 1])
            output.append(bytes.dropFirst(offset).prefix(length))
            offset += length
        }
        return output
    }
}
