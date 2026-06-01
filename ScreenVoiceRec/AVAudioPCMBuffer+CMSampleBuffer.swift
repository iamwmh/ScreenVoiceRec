//
//  AVAudioPCMBuffer+CMSampleBuffer.swift
//  ScreenVoiceRec
//

import AVFoundation
import CoreMedia

extension AVAudioPCMBuffer {
    /// 将 float PCM（含非交错）打包为交错 float 后生成 `CMSampleBuffer`，供 `AVAssetWriterInput` 使用。
    func makeCMSampleBuffer(presentationTimeStamp: CMTime) -> CMSampleBuffer? {
        let n = Int(frameLength)
        guard n > 0 else { return nil }
        let ch = Int(format.channelCount)
        guard ch >= 1, let interleavedFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(ch),
            interleaved: true
        ) else { return nil }

        let bytesPerFrame = MemoryLayout<Float>.size * ch
        let totalBytes = n * bytesPerFrame
        var data = Data(count: totalBytes)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            if let planes = floatChannelData {
                if format.isInterleaved {
                    memcpy(base, planes[0], totalBytes)
                } else {
                    for i in 0..<n {
                        for c in 0..<ch {
                            base[i * ch + c] = planes[c][i]
                        }
                    }
                }
            }
        }

        var asbd = interleavedFmt.streamDescription.pointee
        var formatDescription: CMFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let fmt = formatDescription else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let bb = blockBuffer else { return nil }

        status = data.withUnsafeBytes { ptr -> OSStatus in
            guard let addr = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: addr,
                blockBuffer: bb,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard status == noErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(interleavedFmt.sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(n),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr else { return nil }
        return sampleBuffer
    }
}
