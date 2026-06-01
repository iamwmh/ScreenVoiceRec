//
//  HeadphoneInputCaptureEngine.swift
//  ScreenVoiceRec
//

import AVFoundation
import CoreMedia
import Foundation

/// 从内置/外接音频输入设备录音（含 3.5 mm 耳机孔上的麦克风或线路输入），写入 `AVAssetWriter`。
final class HeadphoneInputCaptureEngine {
    private let writerQueue = DispatchQueue(label: "ScreenVoiceRec.mic.writer")
    private let audioEngine = AVAudioEngine()
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var isPaused = false
    private var outputURL: URL?
    private var exportFormat: AudioExportFormat = .aacM4A
    private var levelEmitCounter = 0
    private var presentationTime: CMTime = .zero

    var onError: ((Error) -> Void)?
    var onStopped: ((URL) -> Void)?
    var onRecordingSessionStarted: (() -> Void)?
    var onAudioLevel: ((Float) -> Void)?

    func setPaused(_ paused: Bool) {
        writerQueue.async { [weak self] in
            self?.isPaused = paused
        }
    }

    func start(outputURL: URL, format: AudioExportFormat) async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .audio)
            if !ok { throw CaptureError.microphonePermissionDenied }
        default:
            throw CaptureError.microphonePermissionDenied
        }

        self.outputURL = outputURL
        self.exportFormat = format
        sessionStarted = false
        isPaused = false
        levelEmitCounter = 0
        presentationTime = .zero

        try? FileManager.default.removeItem(at: outputURL)

        try assetWriter = AVAssetWriter(url: outputURL, fileType: format.avFileType)

        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, time in
            guard let self else { return }
            self.writerQueue.async {
                self.handleTapBuffer(buffer, audioTime: time)
            }
        }

        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            assetWriter = nil
            throw error
        }
    }

    func stop() async {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

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

                guard let writer else {
                    DispatchQueue.main.async {
                        if let u = self.outputURL {
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
                            } else if let u = self?.outputURL {
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
    }

    private func handleTapBuffer(_ pcmBuffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        if isPaused { return }

        let pts: CMTime
        if audioTime.sampleTime >= 0 {
            pts = CMTime(
                value: audioTime.sampleTime,
                timescale: CMTimeScale(pcmBuffer.format.sampleRate)
            )
        } else {
            let sec = AVAudioTime.seconds(forHostTime: audioTime.hostTime)
            pts = CMTime(seconds: sec, preferredTimescale: CMTimeScale(pcmBuffer.format.sampleRate))
        }

        guard let sampleBuffer = pcmBuffer.makeCMSampleBuffer(presentationTimeStamp: pts) else {
            DispatchQueue.main.async { self.onError?(CaptureError.unsupportedAudioFormat) }
            return
        }

        if audioInput == nil {
            configureWriterIfNeeded(with: sampleBuffer)
        }
        guard let input = audioInput, let writer = assetWriter else { return }
        guard input.isReadyForMoreMediaData else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
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

        guard writer.startWriting() else {
            let werr = writer.error?.localizedDescription
            DispatchQueue.main.async {
                self.onError?(CaptureError.writerFailed(L10n.tr("error.startwriting_failed", werr ?? "nil")))
            }
            audioInput = nil
            return
        }
    }
}
