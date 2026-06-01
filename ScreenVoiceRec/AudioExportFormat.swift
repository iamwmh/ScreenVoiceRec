//
//  AudioExportFormat.swift
//  ScreenVoiceRec
//

import AVFoundation
import CoreAudio
import Foundation

/// 常见压缩 / 容器格式（PCM 为未压缩，便于兼容）。
enum AudioExportFormat: String, CaseIterable, Identifiable {
    case aacM4A
    case alacM4A
    case flac
    case linearPCM_WAV

    var id: String { rawValue }

    var title: String {
        switch self {
        case .aacM4A: return L10n.tr("format.aac")
        case .alacM4A: return L10n.tr("format.alac")
        case .flac: return L10n.tr("format.flac")
        case .linearPCM_WAV: return L10n.tr("format.wav")
        }
    }

    var fileExtension: String {
        switch self {
        case .aacM4A, .alacM4A: return "m4a"
        case .flac: return "caf"
        case .linearPCM_WAV: return "wav"
        }
    }

    var avFileType: AVFileType {
        switch self {
        case .aacM4A, .alacM4A: return .m4a
        /// `public.flac` 不是 `AVAssetWriter` 在 macOS 上支持的容器 UTI；FLAC 码流需写入 Core Audio Format（`.caf`，`com.apple.coreaudio-format`）。
        case .flac: return AVFileType(rawValue: "com.apple.coreaudio-format")
        case .linearPCM_WAV: return .wav
        }
    }

    /// 根据 ScreenCaptureKit 送来的 PCM 流构造 `AVAssetWriter` 的音频输出设置。
    /// - Parameter encoderBitDepthHint: 仅用于 ALAC；须为 `NSNumber`。**AAC 与 FLAC** 不得带 `AVEncoderBitDepthHintKey`（系统会拒绝）。
    func outputSettings(sampleRate: Double, channelCount: Int, encoderBitDepthHint: Int = 24) -> [String: Any] {
        let channels = max(1, channelCount)
        let hintBits = max(16, min(encoderBitDepthHint, 32))
        let hintNumber = NSNumber(value: hintBits)
        switch self {
        case .aacM4A:
            return [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        case .alacM4A:
            return [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: hintNumber
            ]
        case .flac:
            return [
                AVFormatIDKey: Int(kAudioFormatFLAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels
            ]
        case .linearPCM_WAV:
            return [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        }
    }

    /// 与 ScreenCaptureKit 首帧构造 WAV 用的线性 PCM 输出设置。
    ///
    /// SCK 常见为 **non-interleaved float**；标准 `.wav` + `AVAssetWriter` 通常只接受 **interleaved** PCM。
    /// 在提供 `sourceFormatHint` 时由 Writer 在 `append` 时做转换，因此这里**固定输出为 interleaved**，
    /// 切勿再按输入把 `IsNonInterleaved` 设为 `true`，否则常见 `canAdd == false` 或 `append` 失败。
    static func wavOutputSettings(from asbd: AudioStreamBasicDescription, force16BitInterleaved: Bool = false) -> [String: Any] {
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48_000
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let flags = asbd.mFormatFlags
        var settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMIsBigEndianKey: NSNumber(value: false),
            AVLinearPCMIsNonInterleaved: NSNumber(value: false)
        ]
        if force16BitInterleaved {
            settings[AVLinearPCMIsFloatKey] = NSNumber(value: false)
            settings[AVLinearPCMBitDepthKey] = 16
            return settings
        }
        if (flags & UInt32(kAudioFormatFlagIsFloat)) != 0 {
            settings[AVLinearPCMIsFloatKey] = NSNumber(value: true)
            settings[AVLinearPCMBitDepthKey] = 32
        } else {
            settings[AVLinearPCMIsFloatKey] = NSNumber(value: false)
            let bits = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : 16
            settings[AVLinearPCMBitDepthKey] = max(16, min(bits, 32))
        }
        return settings
    }
}
