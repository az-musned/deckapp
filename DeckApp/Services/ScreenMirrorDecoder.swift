import CoreMedia
import Foundation
import VideoToolbox

/// Decodes H.264 Annex-B access units (as sent by the Windows Agent) into displayable
/// `CMSampleBuffer`s. Scoped to a single WebSocket connection -- construct a fresh instance
/// per `ScreenMirrorClient.receiveStream` call, mirroring the existing per-connection
/// `ScreenStreamSequenceTracker` pattern.
final class ScreenMirrorDecoder {
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var lastParameterSets: (sps: Data, pps: Data)?

    /// Returns a ready-to-display sample buffer, or nil if this access unit didn't produce
    /// one (e.g. a non-keyframe arrived before the session has been configured from SPS/PPS,
    /// which can happen briefly right after connecting until the requested keyframe arrives).
    func decode(_ wireFrame: ScreenStreamWireFrame) -> CMSampleBuffer? {
        let nalUnits = Self.splitAnnexB(wireFrame.annexB)
        var sliceNalUnits: [Data] = []
        var sps: Data?
        var pps: Data?

        for nal in nalUnits {
            guard let firstByte = nal.first else { continue }
            switch firstByte & 0x1F {
            case 7: sps = nal
            case 8: pps = nal
            case 1, 5: sliceNalUnits.append(nal)
            default: break // AUD, SEI, and other non-slice NAL units are not fed to VideoToolbox.
            }
        }

        if let sps, let pps {
            let isNewParameterSets = lastParameterSets.map { $0.sps != sps || $0.pps != pps } ?? true
            if isNewParameterSets || session == nil {
                guard configureSession(sps: sps, pps: pps) else { return nil }
                lastParameterSets = (sps, pps)
            }
        }

        guard let session, let formatDescription, !sliceNalUnits.isEmpty else { return nil }
        guard let blockBuffer = Self.makeAVCCBlockBuffer(from: sliceNalUnits) else { return nil }

        let presentationTime = CMTime(value: wireFrame.timestampMilliseconds, timescale: 1000)
        var timingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSizes = [blockBuffer.dataLength]

        var sourceSampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSizes,
            sampleBufferOut: &sourceSampleBuffer
        )
        guard createStatus == noErr, let sourceSampleBuffer else { return nil }

        var decodedImageBuffer: CVImageBuffer?
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sourceSampleBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { status, _, imageBuffer, _, _ in
            guard status == noErr else { return }
            decodedImageBuffer = imageBuffer
        }
        guard decodeStatus == noErr, let decodedImageBuffer else { return nil }

        var outputFormatDescription: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: decodedImageBuffer,
            formatDescriptionOut: &outputFormatDescription
        )
        guard let outputFormatDescription else { return nil }

        var outputTimingInfo = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var outputSampleBuffer: CMSampleBuffer?
        let wrapStatus = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: decodedImageBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: outputFormatDescription,
            sampleTiming: &outputTimingInfo,
            sampleBufferOut: &outputSampleBuffer
        )
        guard wrapStatus == noErr else { return nil }
        return outputSampleBuffer
    }

    private func configureSession(sps: Data, pps: Data) -> Bool {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil

        var newFormatDescription: CMVideoFormatDescription?
        let parameterSetSizes = [sps.count, pps.count]
        let createTypeStatus = sps.withUnsafeBytes { spsBuffer -> OSStatus in
            pps.withUnsafeBytes { ppsBuffer -> OSStatus in
                guard let spsBase = spsBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return kCVReturnError
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                return pointers.withUnsafeBufferPointer { pointersBuffer in
                    parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointersBuffer.baseAddress!,
                            parameterSetSizes: sizesBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newFormatDescription
                        )
                    }
                }
            }
        }
        guard createTypeStatus == noErr, let newFormatDescription else { return false }

        let imageBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var newSession: VTDecompressionSession?
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: newFormatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession else { return false }

        session = newSession
        formatDescription = newFormatDescription
        return true
    }

    private static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var startCodeStarts: [Int] = []
        var index = 0
        while index + 4 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                startCodeStarts.append(index)
                index += 4
            } else {
                index += 1
            }
        }
        var nalUnits: [Data] = []
        for (position, start) in startCodeStarts.enumerated() {
            let nalStart = start + 4
            let nalEnd = position + 1 < startCodeStarts.count ? startCodeStarts[position + 1] : bytes.count
            guard nalStart < nalEnd else { continue }
            nalUnits.append(Data(bytes[nalStart..<nalEnd]))
        }
        return nalUnits
    }

    private static func makeAVCCBlockBuffer(from nalUnits: [Data]) -> CMBlockBuffer? {
        var avcc = Data()
        for nal in nalUnits {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let allocateStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocateStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = avcc.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }
        return blockBuffer
    }

    deinit {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }
}
