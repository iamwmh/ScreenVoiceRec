//
//  ScreenAudioCaptureEngine.swift
//  ScreenVoiceRec
//

import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 使用 ScreenCaptureKit 拉取系统/窗口音频，并写入 `AVAssetWriter`。
final class ScreenAudioCaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    /// 音频写入与 `append` 必须在此队列串行执行。
    private let writerQueue = DispatchQueue(label: "ScreenVoiceRec.writer")
    /// 屏幕帧仅丢弃即可；与音频分队列，避免屏幕回调占满串行队列导致音频帧迟迟不送达。
    private let screenDropQueue = DispatchQueue(label: "ScreenVoiceRec.screen.drop")
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var stream: SCStream?
    private var sessionStarted = false
    private var isPaused = false
    private var outputURL: URL?
    private var exportFormat: AudioExportFormat = .aacM4A
    /// `stopCapture()` 后系统几乎总会回调 `didStopWithError`；与真实故障区分，避免误报并打断 `finishWriting` 收尾。
    private var isStoppingCapture = false

    var onError: ((Error) -> Void)?
    /// 写入成功后的输出文件 URL（与 `lastRecordingURL` 一致，避免竞态下丢失路径）。
    var onStopped: ((URL) -> Void)?
    /// 首帧音频已写入（`startSession` 已调用），用于界面区分「计时在走但未收到系统音频」。
    var onRecordingSessionStarted: (() -> Void)?
    /// 0...1，用于录音电平条（已节流）。
    var onAudioLevel: ((Float) -> Void)?

    private var levelEmitCounter: Int = 0

    func setPaused(_ paused: Bool) {
        writerQueue.async { [weak self] in
            self?.isPaused = paused
        }
    }

    func start(
        filter: SCContentFilter,
        outputURL: URL,
        format: AudioExportFormat,
        captureWidth: Int,
        captureHeight: Int
    ) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingPermissionDenied
        }

        self.outputURL = outputURL
        self.exportFormat = format
        sessionStarted = false
        isPaused = false
        isStoppingCapture = false
        levelEmitCounter = 0

        try? FileManager.default.removeItem(at: outputURL)

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        // 必须与捕获内容分辨率一致；此前固定 2×2 会导致整条流异常，系统音频样本可能始终不到达。
        config.width = max(64, captureWidth)
        config.height = max(64, captureHeight)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream

        do {
            try assetWriter = AVAssetWriter(url: outputURL, fileType: format.avFileType)
            try await stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenDropQueue)
            try await stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
            try await stream.startCapture()
        } catch {
            try? await stream.stopCapture()
            self.stream = nil
            assetWriter = nil
            audioInput = nil
            sessionStarted = false
            throw error
        }
    }

    /// 必须先停止采集，再在 `writerQueue` 上收尾并 **等待** `finishWriting` 完成，否则文件可能尚未落盘。
    func stop() async {
        isStoppingCapture = true
        let s = stream
        stream = nil
        if let s {
            try? await s.stopCapture()
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writerQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                if let input = self.audioInput, self.sessionStarted {
                    input.markAsFinished()
                }
                let writer = self.assetWriter
                let didStart = self.sessionStarted
                self.audioInput = nil
                self.assetWriter = nil
                self.sessionStarted = false

                let finishedURL = self.outputURL

                guard let writer else {
                    DispatchQueue.main.async {
                        if let u = finishedURL {
                            self.onStopped?(u)
                        }
                        continuation.resume()
                    }
                    return
                }

                if didStart {
                    writer.finishWriting {
                        DispatchQueue.main.async { [weak self] in
                            if let err = writer.error {
                                self?.onError?(err)
                            } else if let u = finishedURL {
                                self?.onStopped?(u)
                            }
                            continuation.resume()
                        }
                    }
                } else {
                    writer.cancelWriting()
                    DispatchQueue.main.async { [weak self] in
                        self?.onError?(CaptureError.noAudioSamplesBeforeStop)
                        continuation.resume()
                    }
                }
            }
        }
        isStoppingCapture = false
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // 回调已在 sampleHandlerQueue（writerQueue）上；勿再 async 到同一队列，否则音频处理晚于 stop，文件无法落盘。
        if outputType == .screen {
            return
        }
        guard outputType == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        if isPaused { return }

        if audioInput == nil {
            configureWriterIfNeeded(with: sampleBuffer)
        }
        guard let input = audioInput, let writer = assetWriter else { return }
        guard input.isReadyForMoreMediaData else { return }

        if !sessionStarted {
            let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: t)
            sessionStarted = true
            DispatchQueue.main.async { [weak self] in self?.onRecordingSessionStarted?() }
        }

        levelEmitCounter += 1
        if levelEmitCounter % 2 == 0 {
            let level = AudioSampleBufferMeter.normalizedLevel(from: sampleBuffer)
            DispatchQueue.main.async { [weak self] in self?.onAudioLevel?(level) }
        }

        if !input.append(sampleBuffer) {
            let err = writer.error ?? CaptureError.writerFailed(nil)
            DispatchQueue.main.async { [weak self] in self?.onError?(err) }
        }
    }

    private func configureWriterIfNeeded(with sampleBuffer: CMSampleBuffer) {
        guard let desc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
        else {
            DispatchQueue.main.async { self.onError?(CaptureError.unsupportedAudioFormat) }
            return
        }

        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let flags = UInt32(asbd.mFormatFlags)
        let encoderBitDepthHint: Int
        if (flags & UInt32(kAudioFormatFlagIsFloat)) != 0 {
            encoderBitDepthHint = 32
        } else {
            encoderBitDepthHint = max(16, min(Int(asbd.mBitsPerChannel), 32))
        }

        let input: AVAssetWriterInput
        switch exportFormat {
        case .linearPCM_WAV:
            let primary = AudioExportFormat.wavOutputSettings(from: asbd, force16BitInterleaved: false)
            let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: primary, sourceFormatHint: desc)
            if let writer = assetWriter, writer.canAdd(candidate) {
                input = candidate
            } else {
                let fallbackSettings = AudioExportFormat.wavOutputSettings(from: asbd, force16BitInterleaved: true)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: fallbackSettings, sourceFormatHint: desc)
            }
        default:
            let settings = exportFormat.outputSettings(
                sampleRate: sampleRate,
                channelCount: channels,
                encoderBitDepthHint: encoderBitDepthHint
            )
            input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: desc)
        }
        input.expectsMediaDataInRealTime = true

        guard let writer = assetWriter else {
            DispatchQueue.main.async { self.onError?(CaptureError.writerFailed("assetWriter=nil")) }
            return
        }
        guard writer.canAdd(input) else {
            let werr = writer.error?.localizedDescription
            DispatchQueue.main.async {
                self.onError?(CaptureError.writerFailed("canAdd=false, writer.error=\(werr ?? "nil")"))
            }
            return
        }
        writer.add(input)
        audioInput = input

        // 须在 `add` 之后、首帧 `append` / `startSession` 之前调用，避免长时间卡在 `isReadyForMoreMediaData == false` 导致从未开始会话、停止时无文件。
        guard writer.startWriting() else {
            let werr = writer.error?.localizedDescription
            DispatchQueue.main.async {
                self.onError?(CaptureError.writerFailed(L10n.tr("error.startwriting_failed", werr ?? "nil")))
            }
            audioInput = nil
            return
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 流已结束，避免仍持有引用导致下次「开始录音」状态异常。
        if stream === self.stream {
            self.stream = nil
        }
        if isStoppingCapture {
            return
        }
        DispatchQueue.main.async { self.onError?(error) }
    }
}

enum CaptureError: LocalizedError {
    case screenRecordingPermissionDenied
    case microphonePermissionDenied
    case unsupportedAudioFormat
    case writerFailed(String?)
    /// 停止前未收到任何音频帧，`AVAssetWriter` 无法开始会话，不会产生文件。
    case noAudioSamplesBeforeStop

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            return L10n.tr("error.permission.screen")
        case .microphonePermissionDenied:
            return L10n.tr("error.permission.microphone")
        case .unsupportedAudioFormat:
            return L10n.tr("error.unsupported_audio")
        case .writerFailed(let details):
            if let details, !details.isEmpty {
                return L10n.tr("error.writer_failed_detail", details)
            }
            return L10n.tr("error.writer_failed")
        case .noAudioSamplesBeforeStop:
            return L10n.tr("error.no_audio_before_stop")
        }
    }
}
