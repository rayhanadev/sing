import AudioToolbox
import AVFoundation
import Darwin
import Foundation

public struct ProcessingResult: Codable {
    public let input: String
    public let output: String
    public let mix: Float
    public let quality: Quality
    public let sampleRate: Double
    public let channels: UInt32
    public let frames: Int64
    public let durationSeconds: Double
    public let processingSeconds: Double
    public let latencyFrames: Int64
}

// AudioUnitRender pulls synchronously on the calling thread. This source never
// touches a microphone or an output device, and pads EOF with silence to flush
// the model's delayed output.
private final class FileSource {
    let file: AVAudioFile
    let buffer: AVAudioPCMBuffer
    var error: Error?

    init(file: AVAudioFile, capacity: AVAudioFrameCount) throws {
        self.file = file
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw SingError("Couldn't allocate the input audio buffer.")
        }
        self.buffer = buffer
    }

    func render(_ frames: UInt32, into data: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let data, frames <= buffer.frameCapacity else { return kAudio_ParamError }
        do {
            buffer.frameLength = 0
            let available = min(Int64(frames), max(0, file.length - file.framePosition))
            if available > 0 { try file.read(into: buffer, frameCount: UInt32(available)) }
            let readFrames = buffer.frameLength
            buffer.frameLength = frames
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let destination = UnsafeMutableAudioBufferListPointer(data)
            guard source.count == destination.count else { return kAudio_ParamError }
            for channel in 0..<source.count {
                guard let samples = source[channel].mData else { return kAudio_ParamError }
                let byteCount = Int(frames) * MemoryLayout<Float>.size
                memset(samples.advanced(by: Int(readFrames) * MemoryLayout<Float>.size), 0,
                       Int(frames - readFrames) * MemoryLayout<Float>.size)
                if let target = destination[channel].mData {
                    guard destination[channel].mDataByteSize >= byteCount else { return kAudio_ParamError }
                    memcpy(target, samples, byteCount)
                } else {
                    destination[channel].mData = samples
                }
                destination[channel].mDataByteSize = UInt32(byteCount)
            }
            return noErr
        } catch {
            self.error = SingError("Reading input at frame \(file.framePosition): \(error.localizedDescription)")
            return kAudio_ParamError
        }
    }
}

public func processAudio(input: URL, output: URL, mix: Float, quality: Quality = .auto,
                         overwrite: Bool = false) throws -> ProcessingResult {
    let started = ProcessInfo.processInfo.systemUptime
    let manager = FileManager.default
    let input = input.standardizedFileURL
    let output = output.standardizedFileURL
    guard mix.isFinite, (-100...100).contains(mix) else {
        throw SingError("Mix must be a finite number from -100 to 100.")
    }
    guard output.pathExtension.lowercased() == "wav" else {
        throw SingError("Output must have a .wav extension (32-bit float WAV).")
    }
    guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else {
        throw SingError("Input and output must be different files.")
    }
    if let a = try? manager.attributesOfItem(atPath: input.path),
       let b = try? manager.attributesOfItem(atPath: output.path),
       let ai = a[.systemFileNumber] as? NSNumber, let bi = b[.systemFileNumber] as? NSNumber,
       let ad = a[.systemNumber] as? NSNumber, let bd = b[.systemNumber] as? NSNumber,
       ai == bi, ad == bd {
        throw SingError("Input and output refer to the same file.")
    }
    if manager.fileExists(atPath: output.path), !overwrite {
        throw SingError("Output already exists: \(output.path). Use --force to replace it.")
    }
    var isDirectory: ObjCBool = false
    guard manager.fileExists(atPath: output.deletingLastPathComponent().path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw SingError("Output directory does not exist: \(output.deletingLastPathComponent().path).")
    }

    let file: AVAudioFile
    do {
        file = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw SingError("Couldn't decode input \(input.path): \(error.localizedDescription)")
    }
    let format = file.processingFormat
    guard (1...2).contains(format.channelCount), file.length > 0 else {
        throw SingError("Input must contain nonempty mono or stereo audio.")
    }
    // Classic WAV uses 32-bit chunk lengths. Fail before starting a long render.
    guard file.length <= (Int64(UInt32.max) - 4096) / (Int64(format.channelCount) * 4) else {
        throw SingError("The output would exceed WAV's 4 GiB limit. Split the input into shorter files.")
    }

    let host = try IsolationUnit()
    let resolvedQuality = try host.configure(mix: mix, quality: quality)
    var streamFormat = format.streamDescription.pointee
    for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
        try check(AudioUnitSetProperty(host.unit, kAudioUnitProperty_StreamFormat, scope, 0,
                                       &streamFormat, UInt32(MemoryLayout.size(ofValue: streamFormat))),
                  "Configuring audio format")
    }
    var blockSize: UInt32 = 4096
    try check(AudioUnitSetProperty(host.unit, kAudioUnitProperty_MaximumFramesPerSlice,
                                   kAudioUnitScope_Global, 0, &blockSize,
                                   UInt32(MemoryLayout.size(ofValue: blockSize))), "Configuring block size")
    let source = try FileSource(file: file, capacity: blockSize)
    var callback = AURenderCallbackStruct(
        inputProc: { refCon, _, _, _, frames, data in
            Unmanaged<FileSource>.fromOpaque(refCon).takeUnretainedValue().render(frames, into: data)
        },
        inputProcRefCon: Unmanaged.passUnretained(source).toOpaque()
    )
    try check(AudioUnitSetProperty(host.unit, kAudioUnitProperty_SetRenderCallback,
                                   kAudioUnitScope_Input, 0, &callback,
                                   UInt32(MemoryLayout.size(ofValue: callback))), "Connecting input file")
    try check(AudioUnitInitialize(host.unit), "Initializing AUSoundIsolation")
    defer {
        AudioUnitUninitialize(host.unit)
        withExtendedLifetime(source) {}
    }
    let latencyFrames = Int64((try host.latency() * format.sampleRate).rounded())
    guard let rendered = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize),
          let trimmed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockSize) else {
        throw SingError("Couldn't allocate the output audio buffers.")
    }

    let temporary = output.deletingLastPathComponent()
        .appendingPathComponent(".sing-\(UUID().uuidString).wav")
    defer { try? manager.removeItem(at: temporary) }
    var writer: AVAudioFile?
    do {
        writer = try AVAudioFile(forWriting: temporary, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    } catch {
        throw SingError("Couldn't create output WAV: \(error.localizedDescription)")
    }

    let totalFrames = file.length + latencyFrames
    var renderedFrames: Int64 = 0
    var writtenFrames: Int64 = 0
    while renderedFrames < totalFrames {
        let count = UInt32(min(Int64(blockSize), totalFrames - renderedFrames))
        rendered.frameLength = count
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = Double(renderedFrames)
        timestamp.mFlags = .sampleTimeValid
        var flags: AudioUnitRenderActionFlags = []
        let status = AudioUnitRender(host.unit, &flags, &timestamp, 0, count, rendered.mutableAudioBufferList)
        if let error = source.error { throw error }
        try check(status, "Rendering audio")

        let skip = min(Int64(count), max(0, latencyFrames - renderedFrames))
        let keep = Int64(count) - skip
        if keep > 0 {
            trimmed.frameLength = UInt32(keep)
            guard let src = rendered.floatChannelData, let dst = trimmed.floatChannelData else {
                throw SingError("The processor returned an invalid audio buffer.")
            }
            for channel in 0..<Int(format.channelCount) {
                let samples = src[channel].advanced(by: Int(skip))
                for index in 0..<Int(keep) where !samples[index].isFinite {
                    throw SingError("The processor produced a non-finite sample.")
                }
                memcpy(dst[channel], samples, Int(keep) * MemoryLayout<Float>.size)
            }
            do {
                try writer?.write(from: trimmed)
            } catch {
                throw SingError("Writing output at frame \(writtenFrames): \(error.localizedDescription)")
            }
            writtenFrames += keep
        }
        renderedFrames += Int64(count)
    }
    guard writtenFrames == file.length else { throw SingError("The output frame count is incorrect.") }
    // Close the file before publishing it, so the WAV header is finalized.
    writer = nil
    let publishStatus = temporary.path.withCString { tempPath in
        output.path.withCString { outputPath in
            overwrite ? Darwin.rename(tempPath, outputPath) : Darwin.link(tempPath, outputPath)
        }
    }
    guard publishStatus == 0 else {
        let code = errno
        throw SingError("Couldn't save output: \(String(cString: strerror(code))). Existing output was preserved.")
    }
    return ProcessingResult(
        input: input.path, output: output.path, mix: mix, quality: resolvedQuality,
        sampleRate: format.sampleRate, channels: format.channelCount, frames: writtenFrames,
        durationSeconds: Double(writtenFrames) / format.sampleRate,
        processingSeconds: ProcessInfo.processInfo.systemUptime - started,
        latencyFrames: latencyFrames
    )
}
