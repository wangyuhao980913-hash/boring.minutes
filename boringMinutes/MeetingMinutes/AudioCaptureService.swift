//
//  AudioCaptureService.swift
//  boringNotch
//
//  ScreenCaptureKit 双路音频采集（系统音频 + 麦克风）
//  两路音频统一 16kHz Int16 单声道，混音成一路后写文件并发送 ASR
//  重要：音频写入和混音必须在回调队列同步完成，
//  CMSampleBuffer 不能跨线程异步传递（会失效）
//

import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

class AudioCaptureService: NSObject, ObservableObject {

    @MainActor @Published var isCapturing = false
    @MainActor @Published var audioLevel: Float = 0

    // 全链路统一格式
    static let sampleRate: Double = 16000
    static let channelCount: Int = 1

    private var stream: SCStream?
    private var streamOutput: AudioStreamOutput?

    // 用标准 AVAudioFile 写 AAC m4a（内部自动完成 PCM→AAC 编码，避免手工 CMSampleBuffer 导致的编码失败）
    private var audioFile: AVAudioFile?
    private var writtenSampleCount: Int64 = 0
    private var frameCount: Int = 0

    // #region agent log
    private var dbgSystemCallbacks = 0
    private var dbgMicCallbacks = 0
    private var dbgExtractFails = 0
    private var dbgMixedEmpty = 0
    private var dbgWriterSkips = 0
    private var dbgWriterAppends = 0
    // 两路电平诊断：分别累计系统/麦克风的平方和与样本数，停止时算 RMS
    private var dbgSystemSumSq: Double = 0
    private var dbgSystemSampleCount: Int = 0
    private var dbgMicSumSq: Double = 0
    private var dbgMicSampleCount: Int = 0
    // #endregion

    private let mixer = AudioMixer()
    private var hasMicrophone = false

    // 麦克风改由 AVAudioEngine 采集，以便启用 VPIO（系统级回声消除 AEC + 降噪 + 自动增益）。
    // 系统声仍由 ScreenCaptureKit 直采，两路照旧在 audioQueue 上混成一路。
    private var micEngine: AVAudioEngine?
    private var micVoiceProcessingEnabled = false

    private let audioQueue = DispatchQueue(label: "com.boringnotch.audio-capture", qos: .userInteractive)

    var onPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    @MainActor private(set) var localAudioFileURL: URL?

    // 16kHz Int16 单声道格式（用于回调 ASR 和写文件）
    private lazy var int16Format: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(Self.channelCount),
            interleaved: true
        )!
    }()

    // MARK: - 开始采集

    @MainActor
    func startCapture(outputURL: URL) async throws {
        guard !isCapturing else { return }

        localAudioFileURL = outputURL

        // 屏幕录制权限：先检查，未授权则「主动发起系统请求」。
        // 这一步会把本 app 加入 系统设置 → 隐私与安全性 → 屏幕录制 列表并弹出授权窗；
        // 若之前从未请求过，仅靠检查是不会让 app 出现在该列表里的。
        // 注意：macOS 上首次授予屏幕录制权限后，通常需要重启 app 才会真正生效。
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            DebugSessionLog.write(
                hypothesisId: "P",
                location: "AudioCaptureService.startCapture.entry",
                message: "permission_requested",
                data: [
                    "cgRequestGranted": granted,
                    "runtimeBundleId": Bundle.main.bundleIdentifier ?? "nil",
                    "appPath": Bundle.main.bundlePath,
                ]
            )
            if !granted {
                throw AudioCaptureError.screenRecordingDenied
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            NSLog("AudioCaptureService: SCShareableContent 获取失败: \(error)")
            throw AudioCaptureError.screenRecordingDenied
        }

        guard let display = content.displays.first else {
            throw AudioCaptureError.noDisplayFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        config.capturesAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = Self.channelCount

        // 麦克风不再走 SCStream，改由 AVAudioEngine + VPIO 采集（见 startMicrophoneEngine）。
        // 先启动麦克风引擎拿到是否成功，作为 hasMicrophone，再据此初始化混音器。
        hasMicrophone = startMicrophoneEngine()

        mixer.reset(hasMicrophone: hasMicrophone)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            audioQueue.async { [self] in
                do {
                    try self.setupAssetWriter(outputURL: outputURL)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        let output = AudioStreamOutput(service: self)

        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)

        try await newStream.startCapture()

        self.stream = newStream
        self.streamOutput = output
        self.isCapturing = true

        // #region agent log
        dbgSystemCallbacks = 0
        dbgMicCallbacks = 0
        dbgExtractFails = 0
        dbgMixedEmpty = 0
        dbgWriterSkips = 0
        dbgWriterAppends = 0
        dbgSystemSumSq = 0
        dbgSystemSampleCount = 0
        dbgMicSumSq = 0
        dbgMicSampleCount = 0
        DebugSessionLog.write(
            hypothesisId: "E",
            location: "AudioCaptureService.startCapture",
            message: "capture_started",
            data: [
                "hasMicrophone": hasMicrophone,
                "outputPath": outputURL.path,
                "displayCount": content.displays.count,
            ]
        )
        // #endregion

        NSLog("AudioCaptureService: ✅ 采集已启动 (16kHz, 麦克风: \(hasMicrophone)), 输出: \(outputURL.path)")
    }

    // MARK: - 停止采集

    @MainActor
    func stopCapture() async {
        guard isCapturing else { return }

        if let stream = stream {
            try? await stream.stopCapture()
        }
        stream = nil
        streamOutput = nil

        // 停止麦克风引擎并移除 tap
        stopMicrophoneEngine()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { [self] in
                // 冲刷混音器里残留的样本
                let remaining = self.mixer.drainRemaining()
                if !remaining.isEmpty {
                    self.writeMixedSamples(remaining)
                }
                self.finishWritingSync()
                continuation.resume()
            }
        }

        isCapturing = false
        NSLog("AudioCaptureService: 采集已停止")
    }

    // MARK: - 麦克风采集（AVAudioEngine + VPIO 回声消除）

    /// 启动麦克风引擎，尽力开启 VPIO（系统级 AEC/降噪/自动增益）。
    /// 返回是否成功启动（作为 hasMicrophone）。VPIO 开启失败不影响录音，只是外放会有回音。
    private func startMicrophoneEngine() -> Bool {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        // 开启 VPIO：把扬声器外放、被麦克风重新收到的系统声从麦克风里减掉。
        // 某些聚合/虚拟声卡（BlackHole、Loopback 等）可能启用失败，此时退化为原始采集，仍可录音。
        micVoiceProcessingEnabled = false
        do {
            try input.setVoiceProcessingEnabled(true)
            micVoiceProcessingEnabled = true
        } catch {
            NSLog("AudioCaptureService: VPIO 启用失败，退化为无回声消除的原始采集: \(error)")
        }

        // 关闭 VPIO 的「压低其他音频」行为，否则 ScreenCaptureKit 采到的系统声会被压到几乎静音。
        if micVoiceProcessingEnabled, #available(macOS 14.0, *) {
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: false,
                    duckingLevel: .min
                )
        }

        // 开启 VPIO 后麦克风格式可能变多声道，用 format: nil 让 tap 自动采用节点当前格式。
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.handleMicBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            NSLog("AudioCaptureService: 麦克风引擎启动失败: \(error)")
            input.removeTap(onBus: 0)
            return false
        }

        self.micEngine = engine
        NSLog("AudioCaptureService: 麦克风引擎已启动 (VPIO/AEC: \(micVoiceProcessingEnabled))")
        return true
    }

    private func stopMicrophoneEngine() {
        guard let engine = micEngine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micEngine = nil
    }

    /// 麦克风 tap 回调（在音频引擎线程）：取第 0 声道 float → Int16 → 重采样到 16kHz，
    /// 再切到 audioQueue 上喂给混音器，与系统声在同一串行队列上混合。
    /// 注意：VPIO 会把麦克风格式变多声道，只能手动取第 0 声道，不能用 AVAudioConverter（会崩）。
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let srcRate = buffer.format.sampleRate
        let ch0 = channels[0]

        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let f = max(-1.0, min(1.0, ch0[i]))
            samples.append(Int16(f * 32767.0))
        }

        if srcRate > 0, abs(srcRate - Self.sampleRate) > 1 {
            samples = Self.resampleTo16k(samples, from: srcRate)
        }

        audioQueue.async { [weak self] in
            guard let self else { return }

            // #region agent log
            self.dbgMicCallbacks += 1
            var sumSq: Double = 0
            for s in samples { let v = Double(s); sumSq += v * v }
            self.dbgMicSumSq += sumSq
            self.dbgMicSampleCount += samples.count
            // #endregion

            let mixed = self.mixer.push(samples: samples, from: .microphone)
            if !mixed.isEmpty {
                self.writeMixedSamples(mixed)
            }
        }
    }

    // MARK: - 录音文件写入（仅在 audioQueue 上调用）

    private func setupAssetWriter(outputURL: URL) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let dir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 无损 WAV（LPCM int16）输出：写入缓冲不经过任何编码器，物理上不会失败。
        // 录制结束后再由 MeetingManager 一次性转成 m4a（AVAssetExportSession），避免实时 AAC 编码在本机翻车。
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: Self.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: outputURL, settings: settings)
        } catch {
            // #region agent log
            DebugSessionLog.write(
                hypothesisId: "W",
                location: "AudioCaptureService.setupAssetWriter",
                message: "writer_setup_FAILED",
                data: ["error": error.localizedDescription, "outputURL": outputURL.path]
            )
            // #endregion
            throw error
        }

        self.audioFile = file
        self.writtenSampleCount = 0
        self.frameCount = 0

        // #region agent log
        DebugSessionLog.write(
            hypothesisId: "W",
            location: "AudioCaptureService.setupAssetWriter",
            message: "writer_setup_done",
            data: [
                "processingFormat": String(describing: file.processingFormat),
                "int16Format": String(describing: int16Format),
                "outputURL": outputURL.path,
                "settings": String(describing: settings),
            ]
        )
        // #endregion

        NSLog("AudioCaptureService: AVAudioFile 初始化成功")
    }

    /// SCStream 回调（在 audioQueue 上）——把样本喂给混音器，取回混音结果
    func handleAudioSample(_ sampleBuffer: CMSampleBuffer, isMicrophone: Bool) {
        // #region agent log
        if isMicrophone { dbgMicCallbacks += 1 } else { dbgSystemCallbacks += 1 }
        let totalCallbacks = dbgSystemCallbacks + dbgMicCallbacks
        if totalCallbacks == 1 || totalCallbacks % 200 == 0 {
            DebugSessionLog.write(
                hypothesisId: "A",
                location: "AudioCaptureService.handleAudioSample",
                message: "stream_callback",
                data: [
                    "isMicrophone": isMicrophone,
                    "systemCallbacks": dbgSystemCallbacks,
                    "micCallbacks": dbgMicCallbacks,
                    "sampleValid": sampleBuffer.isValid,
                    "numSamples": CMSampleBufferGetNumSamples(sampleBuffer),
                ]
            )
        }
        // #endregion

        guard let extracted = Self.extractInt16Samples(from: sampleBuffer) else {
            // #region agent log
            dbgExtractFails += 1
            if dbgExtractFails <= 3 || dbgExtractFails % 50 == 0 {
                DebugSessionLog.write(
                    hypothesisId: "B",
                    location: "AudioCaptureService.handleAudioSample",
                    message: "extract_failed",
                    data: [
                        "isMicrophone": isMicrophone,
                        "extractFailCount": dbgExtractFails,
                        "sampleValid": sampleBuffer.isValid,
                    ]
                )
            }
            // #endregion
            return
        }

        // 统一重采样到 16kHz：麦克风常以 48kHz 送入，若不转换会导致时长成倍拉长、声音变慢
        var samples = extracted.samples
        if extracted.sampleRate > 0, abs(extracted.sampleRate - Self.sampleRate) > 1 {
            samples = Self.resampleTo16k(samples, from: extracted.sampleRate)
            // #region agent log
            if isMicrophone && (dbgMicCallbacks == 1 || dbgMicCallbacks % 200 == 0) {
                DebugSessionLog.write(
                    hypothesisId: "R",
                    location: "AudioCaptureService.handleAudioSample",
                    message: "resampled",
                    data: [
                        "isMicrophone": isMicrophone,
                        "srcRate": extracted.sampleRate,
                        "srcCount": extracted.samples.count,
                        "dstCount": samples.count,
                    ]
                )
            }
            // #endregion
        }

        // 诊断：累计两路各自的能量（放大前的原始电平）
        var sumSq: Double = 0
        for s in samples { let v = Double(s); sumSq += v * v }
        if isMicrophone {
            dbgMicSumSq += sumSq
            dbgMicSampleCount += samples.count
        } else {
            dbgSystemSumSq += sumSq
            dbgSystemSampleCount += samples.count
        }

        let source: AudioMixer.Source = isMicrophone ? .microphone : .system
        let mixed = mixer.push(samples: samples, from: source)

        if !mixed.isEmpty {
            writeMixedSamples(mixed)
        } else {
            // #region agent log
            dbgMixedEmpty += 1
            if dbgMixedEmpty <= 3 || dbgMixedEmpty % 100 == 0 {
                DebugSessionLog.write(
                    hypothesisId: "C",
                    location: "AudioCaptureService.handleAudioSample",
                    message: "mixer_output_empty",
                    data: [
                        "isMicrophone": isMicrophone,
                        "inputSamples": samples.count,
                        "mixedEmptyCount": dbgMixedEmpty,
                        "hasMicrophone": hasMicrophone,
                    ]
                )
            }
            // #endregion
        }
    }

    /// 把混音后的 Int16 样本写入文件 + 回调 ASR + 更新电平
    private func writeMixedSamples(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        frameCount += 1

        // 封装成 AVAudioPCMBuffer
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: int16Format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let dst = buffer.int16ChannelData {
            samples.withUnsafeBufferPointer { src in
                dst[0].update(from: src.baseAddress!, count: samples.count)
            }
        }

        // 写文件：按 AVAudioFile 的处理格式（float32 或 int16）填充缓冲后写入 WAV
        if let file = audioFile,
           let outBuffer = AVAudioPCMBuffer(
               pcmFormat: file.processingFormat,
               frameCapacity: AVAudioFrameCount(samples.count)
           )
        {
            outBuffer.frameLength = AVAudioFrameCount(samples.count)
            if let dst = outBuffer.floatChannelData {
                let scale: Float = 1.0 / 32768.0
                for i in 0..<samples.count {
                    dst[0][i] = Float(samples[i]) * scale
                }
            } else if let dst = outBuffer.int16ChannelData {
                for i in 0..<samples.count {
                    dst[0][i] = samples[i]
                }
            }
            do {
                try file.write(from: outBuffer)
                writtenSampleCount += Int64(samples.count)
                // #region agent log
                dbgWriterAppends += 1
                // #endregion
            } catch {
                // #region agent log
                dbgWriterSkips += 1
                if dbgWriterSkips <= 3 || dbgWriterSkips % 50 == 0 {
                    DebugSessionLog.write(
                        hypothesisId: "D",
                        location: "AudioCaptureService.writeMixedSamples",
                        message: "writer_skip",
                        data: [
                            "writeError": error.localizedDescription,
                            "fileProcessingFormat": String(describing: file.processingFormat),
                            "outBufferFormat": String(describing: outBuffer.format),
                            "writerSkipCount": dbgWriterSkips,
                            "sampleCount": samples.count,
                        ]
                    )
                }
                // #endregion
            }
        }

        // 回调 ASR
        onPCMBuffer?(buffer)

        // 更新电平
        updateAudioLevel(samples)
    }

    private func finishWritingSync() {
        NSLog("AudioCaptureService: finishWriting - 写入帧数: \(frameCount), 样本数: \(writtenSampleCount)")

        // 两路电平诊断（放大前的原始 RMS，满值 32767）：
        // - micCallbacks=0 或 micSampleCount=0  => 麦克风根本没采到数据（权限/配置问题）
        // - micRMS 远小于 systemRMS              => 麦克风电平天然偏低，需要更大的 micGain
        let systemRMS = dbgSystemSampleCount > 0 ? sqrt(dbgSystemSumSq / Double(dbgSystemSampleCount)) : 0
        let micRMS = dbgMicSampleCount > 0 ? sqrt(dbgMicSumSq / Double(dbgMicSampleCount)) : 0
        let ratio = micRMS > 0 ? systemRMS / micRMS : -1
        NSLog(String(
            format: "AudioMixerDiag: systemCallbacks=%d micCallbacks=%d | systemRMS=%.1f micRMS=%.1f | 系统/麦克风电平比=%.2f (当前 systemGain=%.2f micGain=%.2f)",
            dbgSystemCallbacks, dbgMicCallbacks, systemRMS, micRMS, ratio,
            AudioMixer.systemGain, AudioMixer.micGain
        ))

        let writerPath = audioFile?.url.path ?? ""

        // AVAudioFile 在释放时 flush 并 finalize，置 nil 即完成写入
        self.audioFile = nil

        var fileSize: Int64 = 0
        if !writerPath.isEmpty,
           let attrs = try? FileManager.default.attributesOfItem(atPath: writerPath),
           let size = attrs[.size] as? Int64 {
            fileSize = size
            NSLog("AudioCaptureService: ✅ 文件完成, \(size) bytes")
        }

        // #region agent log
        DebugSessionLog.write(
            hypothesisId: "D",
            location: "AudioCaptureService.finishWritingSync",
            message: "capture_finished",
            data: [
                "frameCount": frameCount,
                "writtenSampleCount": writtenSampleCount,
                "systemCallbacks": dbgSystemCallbacks,
                "micCallbacks": dbgMicCallbacks,
                "extractFails": dbgExtractFails,
                "mixedEmpty": dbgMixedEmpty,
                "writerSkips": dbgWriterSkips,
                "writerAppends": dbgWriterAppends,
                "fileSizeBytes": fileSize,
                "outputPath": writerPath,
            ]
        )
        // #endregion
    }

    // MARK: - WAV 转 m4a（录制结束后一次性转码，不在实时链路里做编码）

    /// 把无损 WAV 用 AVAssetExportSession（AppleM4A 预设）转成 AAC m4a。
    /// 这是「录完再压一次」的一次性转码，比实时 AAC 编码稳定得多。
    static func exportToM4A(source: URL, destination: URL) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioCaptureError.writerSetupFailed
        }
        export.outputURL = destination
        export.outputFileType = .m4a

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                continuation.resume()
            }
        }

        if export.status != .completed {
            throw export.error ?? AudioCaptureError.writerSetupFailed
        }
    }

    // MARK: - CMSampleBuffer -> Int16 样本

    static func extractInt16Samples(from sampleBuffer: CMSampleBuffer) -> (samples: [Int16], sampleRate: Double)? {
        guard sampleBuffer.isValid,
              let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)?.pointee
        else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let sampleRate = asbd.mSampleRate
        let channels = Int(asbd.mChannelsPerFrame)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0

        // 先查询 AudioBufferList 所需大小（固定 sizeof 在 macOS 26 上会失败）
        var bufferListSize = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &bufferListSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard status == noErr, bufferListSize > 0 else { return nil }

        let listPointer = UnsafeMutableRawPointer.allocate(
            byteCount: bufferListSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { listPointer.deallocate() }

        var blockBuffer: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: listPointer.assumingMemoryBound(to: AudioBufferList.self),
            bufferListSize: bufferListSize,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(
            listPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        guard let firstBuffer = buffers.first, let data = firstBuffer.mData else { return nil }

        var result = [Int16]()
        result.reserveCapacity(frameCount)

        if isFloat {
            // Float32 -> Int16（取第一声道，交错或非交错都取步长）
            let floatPtr = data.assumingMemoryBound(to: Float32.self)
            let totalFloats = Int(firstBuffer.mDataByteSize) / MemoryLayout<Float32>.size
            let stride = (channels > 0 && totalFloats >= frameCount * channels) ? channels : 1
            var i = 0
            while i < totalFloats && result.count < frameCount {
                let f = max(-1.0, min(1.0, floatPtr[i]))
                result.append(Int16(f * 32767.0))
                i += stride
            }
        } else {
            // Int16
            let int16Ptr = data.assumingMemoryBound(to: Int16.self)
            let totalInts = Int(firstBuffer.mDataByteSize) / MemoryLayout<Int16>.size
            let stride = (channels > 0 && totalInts >= frameCount * channels) ? channels : 1
            var i = 0
            while i < totalInts && result.count < frameCount {
                result.append(int16Ptr[i])
                i += stride
            }
        }

        return result.isEmpty ? nil : (result, sampleRate)
    }

    /// 线性插值重采样到 16kHz（单声道 Int16），兼容 44.1k/48k 等任意源率。
    /// 对语音 + ASR 足够，且无外部依赖、不会失败。
    static func resampleTo16k(_ samples: [Int16], from srcRate: Double) -> [Int16] {
        guard srcRate > 0, samples.count > 1 else { return samples }
        let dstRate = Self.sampleRate
        let ratio = dstRate / srcRate
        let dstCount = Int((Double(samples.count) * ratio).rounded())
        guard dstCount > 1 else { return samples }

        var output = [Int16]()
        output.reserveCapacity(dstCount)
        let srcMaxIndex = samples.count - 1
        for i in 0..<dstCount {
            let srcPos = Double(i) / ratio
            let idx = Int(srcPos)
            if idx >= srcMaxIndex {
                output.append(samples[srcMaxIndex])
            } else {
                let frac = srcPos - Double(idx)
                let a = Double(samples[idx])
                let b = Double(samples[idx + 1])
                let value = a + (b - a) * frac
                output.append(Int16(max(-32768.0, min(32767.0, value))))
            }
        }
        return output
    }

    // MARK: - 音频电平

    private func updateAudioLevel(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var sum: Float = 0
        for s in samples {
            let v = Float(s) / Float(Int16.max)
            sum += v * v
        }
        let rms = sqrt(sum / Float(samples.count))
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = rms
        }
    }
}

// MARK: - 轻量混音器

/// 两路 16kHz Int16 单声道音频，按到达顺序累积对齐，逐样本相加成一路。
/// 内置双路自适应增益（AGC）：根据两路实时 RMS 电平同时动态调整 systemGain 和 micGain，
/// 让混合后麦克风（本地人声）与系统声（远端参会者）始终保持 6:4 的目标比例。
/// 只在 audioQueue 上串行访问，无需额外加锁。
final class AudioMixer {
    enum Source { case system, microphone }

    private var systemBuf = [Int16]()
    private var micBuf = [Int16]()
    private var hasMicrophone = true

    private let maxBuffered = 16000

    // MARK: - 双路自适应增益（AGC）

    static var systemGain: Float = 1.0
    static var micGain: Float = 1.0

    private static let agcWindowSamples = 8000        // 约 0.5 秒 @16kHz，更快响应音量变化
    private static let agcSmoothFactor: Float = 0.15
    private static let gainMin: Float = 0.3
    private static let gainMax: Float = 8.0            // 允许更大的麦克风增益补偿
    private static let targetPeak: Float = 14000
    private static let micRatio: Float = 0.7           // 麦克风目标占比（人声必须压过系统声）
    private static let sysRatio: Float = 0.3           // 系统声目标占比
    private static let silenceThreshold: Double = 50
    private static let micGainFloor: Float = 1.5       // 麦克风增益下限，始终给人声一个基础提升

    private var systemSumSq: Double = 0
    private var systemSampleCount: Int = 0
    private var micSumSq: Double = 0
    private var micSampleCount: Int = 0
    private var agcReady = false

    func reset(hasMicrophone: Bool) {
        systemBuf.removeAll(keepingCapacity: true)
        micBuf.removeAll(keepingCapacity: true)
        self.hasMicrophone = hasMicrophone
        Self.systemGain = 1.0
        Self.micGain = 1.0
        systemSumSq = 0
        systemSampleCount = 0
        micSumSq = 0
        micSampleCount = 0
        agcReady = false
    }

    /// 推入一路样本，返回可以立即输出的混音结果（可能为空）
    func push(samples: [Int16], from source: Source) -> [Int16] {
        if !hasMicrophone {
            return source == .system ? samples : []
        }

        // 累加 RMS 能量（用放大前的原始电平）
        var sumSq: Double = 0
        for s in samples { let v = Double(s); sumSq += v * v }
        switch source {
        case .system:
            systemBuf.append(contentsOf: samples)
            systemSumSq += sumSq
            systemSampleCount += samples.count
        case .microphone:
            micBuf.append(contentsOf: samples)
            micSumSq += sumSq
            micSampleCount += samples.count
        }

        // 每个 AGC 窗口重新计算增益
        let totalSamples = min(systemSampleCount, micSampleCount)
        if totalSamples >= Self.agcWindowSamples {
            recalculateGain()
        }

        var output = [Int16]()

        let pairCount = min(systemBuf.count, micBuf.count)
        if pairCount > 0 {
            output.reserveCapacity(pairCount)
            for i in 0..<pairCount {
                output.append(Self.mixSample(systemBuf[i], micBuf[i]))
            }
            systemBuf.removeFirst(pairCount)
            micBuf.removeFirst(pairCount)
        }

        if systemBuf.count > maxBuffered {
            let overflow = systemBuf.count - maxBuffered
            output.append(contentsOf: systemBuf.prefix(overflow))
            systemBuf.removeFirst(overflow)
        }
        if micBuf.count > maxBuffered {
            let overflow = micBuf.count - maxBuffered
            output.append(contentsOf: micBuf.prefix(overflow))
            micBuf.removeFirst(overflow)
        }

        return output
    }

    /// 录制结束时冲刷两路残留
    func drainRemaining() -> [Int16] {
        var output = [Int16]()
        let n = max(systemBuf.count, micBuf.count)
        output.reserveCapacity(n)
        for i in 0..<n {
            let s = i < systemBuf.count ? systemBuf[i] : 0
            let m = i < micBuf.count ? micBuf[i] : 0
            output.append(Self.mixSample(s, m))
        }
        systemBuf.removeAll(keepingCapacity: true)
        micBuf.removeAll(keepingCapacity: true)
        NSLog("[AudioMixer] 录制结束增益: systemGain=%.2f micGain=%.2f agcReady=%@",
              Self.systemGain, Self.micGain, agcReady ? "true" : "false")
        return output
    }

    // MARK: - AGC 核心

    private func recalculateGain() {
        let sysRMS = systemSampleCount > 0 ? sqrt(systemSumSq / Double(systemSampleCount)) : 0
        let micRMS = micSampleCount > 0 ? sqrt(micSumSq / Double(micSampleCount)) : 0

        systemSumSq = 0; systemSampleCount = 0
        micSumSq = 0; micSampleCount = 0

        guard sysRMS > Self.silenceThreshold, micRMS > Self.silenceThreshold else { return }

        // 目标：混合后 micRMS*micGain : sysRMS*sysGain = 7:3
        let rawSysGain = min(max(Float(Double(Self.targetPeak) * Double(Self.sysRatio) / sysRMS), Self.gainMin), Self.gainMax)
        var rawMicGain = min(max(Float(Double(Self.targetPeak) * Double(Self.micRatio) / micRMS), Self.gainMin), Self.gainMax)

        // 麦克风增益不低于 micGainFloor，确保人声始终有基础提升
        rawMicGain = max(rawMicGain, Self.micGainFloor)

        // 当系统声比麦克风大时，额外压低系统增益（保护人声清晰度）
        if sysRMS > micRMS * 2 {
            let suppressFactor = Float(micRMS / sysRMS)
            let suppressed = rawSysGain * max(suppressFactor, 0.3)
            if suppressed < rawSysGain {
                NSLog("[AGC] 系统声过大，额外压低: sysRMS=%.0f micRMS=%.0f sysGain %.2f→%.2f", sysRMS, micRMS, rawSysGain, suppressed)
            }
        }

        if agcReady {
            let attackSmooth: Float = 0.7   // 快速降增益（系统声突然变大时更快反应）
            let releaseSmooth: Float = 0.08 // 慢慢升增益

            let sysFactor = rawSysGain < Self.systemGain ? attackSmooth : releaseSmooth
            let micFactor = rawMicGain < Self.micGain ? attackSmooth : releaseSmooth

            Self.systemGain = Self.systemGain * (1 - sysFactor) + rawSysGain * sysFactor
            Self.micGain = Self.micGain * (1 - micFactor) + rawMicGain * micFactor
        } else {
            Self.systemGain = rawSysGain
            Self.micGain = rawMicGain
            agcReady = true
        }

        // 最终保障：麦克风增益绝不低于 floor
        Self.micGain = max(Self.micGain, Self.micGainFloor)
    }

    private static func mixSample(_ system: Int16, _ mic: Int16) -> Int16 {
        let sum = Int(Float(system) * systemGain) + Int(Float(mic) * micGain)
        if sum > Int(Int16.max) { return Int16.max }
        if sum < Int(Int16.min) { return Int16.min }
        return Int16(sum)
    }
}

// MARK: - SCStream 音频输出代理

private class AudioStreamOutput: NSObject, SCStreamOutput {
    let service: AudioCaptureService

    init(service: AudioCaptureService) {
        self.service = service
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else {
            // #region agent log
            DebugSessionLog.write(
                hypothesisId: "A",
                location: "AudioStreamOutput.stream",
                message: "invalid_sample_buffer",
                data: ["outputType": String(describing: type)]
            )
            // #endregion
            return
        }

        // 只处理系统声；麦克风改由 AVAudioEngine + VPIO 采集，不再来自 SCStream。
        if type == .audio {
            service.handleAudioSample(sampleBuffer, isMicrophone: false)
        }
    }
}

// MARK: - 错误类型

enum AudioCaptureError: LocalizedError, Equatable {
    case noDisplayFound
    case writerSetupFailed
    case microphoneNotAvailable
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .noDisplayFound: return "未找到可用的显示器"
        case .writerSetupFailed: return "录音文件初始化失败"
        case .microphoneNotAvailable: return "麦克风不可用"
        case .screenRecordingDenied: return "需要屏幕录制权限才能采集音频"
        }
    }
}
