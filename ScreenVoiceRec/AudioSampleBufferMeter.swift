//
//  AudioSampleBufferMeter.swift
//  ScreenVoiceRec
//

import CoreMedia
import Foundation

/// 从 ScreenCaptureKit 送来的 `CMSampleBuffer` 估算瞬时音量，供电平条使用。
enum AudioSampleBufferMeter {
    /// 0...1，已做简单对数映射，静音接近 0。
    static func normalizedLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return 0 }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return 0 }
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)
        else { return 0 }

        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & UInt32(kAudioFormatFlagIsFloat)) != 0
        guard isFloat else { return 0.15 }

        var sizeNeeded: size_t = 0
        let st1 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )
        guard st1 == noErr, sizeNeeded > 0 else { return 0 }

        var blockBuffer: CMBlockBuffer?

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(sizeNeeded), alignment: 16)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)

        let st2 = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        defer { blockBuffer = nil }
        guard st2 == noErr else { return 0 }

        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        var peak: Float = 0
        for buffer in abl {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let byteCount = Int(buffer.mDataByteSize)
            let count = byteCount / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let ptr = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count {
                let a = abs(ptr[i])
                if a > peak { peak = a }
            }
        }

        // 峰值 → 分贝 → 映射到 0...1（约 -60dB～0dB）
        let floor: Float = 1e-7
        let db = 20 * Float(log10(Double(max(peak, floor))))
        let minDb: Float = -55
        let maxDb: Float = 0
        let t = (db - minDb) / (maxDb - minDb)
        return max(0, min(1, t))
    }
}
