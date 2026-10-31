import AVFoundation
import Foundation
import XCTest
@testable import SingCore

final class AudioProcessorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("sing-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fixture(rate: Double = 48000, channels: UInt32 = 2,
                         frames: UInt32 = 24013, name: String = "input.wav") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                let time = Double(frame) / rate
                samples[channel][frame] = Float(0.2 * sin(2 * .pi * Double(440 + 173 * channel) * time)
                    + 0.07 * cos(2 * .pi * 123 * time))
            }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        return url
    }

    private func samples(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                 frameCapacity: UInt32(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        return (0..<Int(file.processingFormat.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
        }
    }

    func testZeroMixPreservesTimingSamplesAndStereo() throws {
        for rate in [24000.0, 44100.0, 48000.0] {
            for quality in [Quality.standard, .high] {
                if quality == .high, !(try processorInfo()).qualities.contains("high") { continue }
                let input = try fixture(rate: rate)
                let output = directory.appendingPathComponent("dry.wav")
                let result = try processAudio(input: input, output: output, mix: 0,
                                              quality: quality, overwrite: true)
                XCTAssertEqual(result.sampleRate, rate)
                XCTAssertEqual(result.channels, 2)
                XCTAssertEqual(result.frames, 24013)
                let original = try samples(input)
                let dry = try samples(output)
                XCTAssertEqual(dry.count, original.count)
                for channel in original.indices {
                    XCTAssertEqual(dry[channel].count, original[channel].count)
                    let error = zip(original[channel], dry[channel]).map { abs($0 - $1) }.max()!
                    XCTAssertLessThan(error, 0.0001, "\(rate) Hz / \(quality): dry signal must retain beginning, tail, and alignment")
                }
            }
        }
    }

    func testVocalsAndInstrumentalReconstructInput() throws {
        guard (try processorInfo()).mix.minimum <= -100 else {
            throw XCTSkip("Installed processor does not expose negative mix.")
        }
        let input = try fixture(frames: 48019)
        let vocals = directory.appendingPathComponent("vocals.wav")
        let instrumental = directory.appendingPathComponent("instrumental.wav")
        for quality in [Quality.standard, .high] {
            if quality == .high, !(try processorInfo()).qualities.contains("high") { continue }
            _ = try processAudio(input: input, output: vocals, mix: 100, quality: quality, overwrite: true)
            _ = try processAudio(input: input, output: instrumental, mix: -100, quality: quality, overwrite: true)
            let original = try samples(input)
            let voice = try samples(vocals)
            let backing = try samples(instrumental)
            XCTAssertEqual(voice.map(\.count), original.map(\.count))
            XCTAssertEqual(backing.map(\.count), original.map(\.count))
            for channel in original.indices {
                var maxError: Float = 0
                var difference: Double = 0
                for index in original[channel].indices {
                    XCTAssertTrue(voice[channel][index].isFinite)
                    XCTAssertTrue(backing[channel][index].isFinite)
                    maxError = max(maxError, abs(voice[channel][index] + backing[channel][index] - original[channel][index]))
                    difference += Double(abs(voice[channel][index] - original[channel][index]))
                }
                XCTAssertLessThan(maxError, 0.001, "\(quality): separated outputs must reconstruct the aligned input")
                XCTAssertGreaterThan(difference / Double(original[channel].count), 0.01,
                                     "The voice model must actually change the tonal fixture")
            }
        }
    }

    func testVeryShortMonoInputIsFlushed() throws {
        let input = try fixture(channels: 1, frames: 7)
        let output = directory.appendingPathComponent("short.wav")
        let result = try processAudio(input: input, output: output, mix: 0)
        XCTAssertEqual(result.frames, 7)
        let original = try samples(input)[0]
        let processed = try samples(output)[0]
        XCTAssertEqual(processed.count, 7)
        for (a, b) in zip(original, processed) { XCTAssertEqual(a, b, accuracy: 0.0001) }
    }

    func testExistingOutputSurvivesFailureAndRequiresForce() throws {
        let input = try fixture()
        let output = directory.appendingPathComponent("existing.wav")
        let sentinel = Data("keep this file".utf8)
        try sentinel.write(to: output)
        XCTAssertThrowsError(try processAudio(input: input, output: output, mix: 100))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        XCTAssertThrowsError(try processAudio(input: directory.appendingPathComponent("missing.wav"),
                                              output: output, mix: 100, overwrite: true))
        XCTAssertEqual(try Data(contentsOf: output), sentinel)
        _ = try processAudio(input: input, output: output, mix: 100, overwrite: true)
        XCTAssertNotEqual(try Data(contentsOf: output), sentinel)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".sing-") })
    }

    func testInputCannotBeOverwrittenThroughAliases() throws {
        let input = try fixture()
        let before = try Data(contentsOf: input)
        let hardLink = directory.appendingPathComponent("hard.wav")
        let symlink = directory.appendingPathComponent("sym.wav")
        try FileManager.default.linkItem(at: input, to: hardLink)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: input)
        for output in [input, hardLink, symlink] {
            XCTAssertThrowsError(try processAudio(input: input, output: output, mix: 100, overwrite: true))
        }
        XCTAssertEqual(try Data(contentsOf: input), before)
    }

    func testInvalidMixAndOutputFormatFailWithoutOutput() throws {
        let input = try fixture()
        let output = directory.appendingPathComponent("invalid.wav")
        for mix: Float in [.nan, .infinity, -101, 101] {
            XCTAssertThrowsError(try processAudio(input: input, output: output, mix: mix))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertThrowsError(try processAudio(input: input, output: directory.appendingPathComponent("invalid.mp3"), mix: 100))
    }
}
