import AudioToolbox
import Foundation

public struct SingError: Error, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else {
        throw SingError("\(operation) failed (OSStatus \(status)).")
    }
}

public enum Quality: String, Codable, CaseIterable {
    case auto, standard, high
}

public struct ParameterRange: Codable {
    public let minimum: Float
    public let maximum: Float
    public let defaultValue: Float

    func contains(_ value: Float) -> Bool { value >= minimum && value <= maximum }
}

public struct ProcessorInfo: Codable {
    public let name: String
    public let component: String
    public let macOS: String
    public let mix: ParameterRange
    public let qualities: [String]
    public let modelDirectory: String
}

final class IsolationUnit {
    let unit: AudioUnit

    init() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw SingError("Apple's AUSoundIsolation is unavailable. Use macOS 13 or later with the built-in AudioDSP component installed.")
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "Opening AUSoundIsolation")
        guard let instance else { throw SingError("AUSoundIsolation returned no instance.") }
        unit = instance
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    func range(_ parameter: AudioUnitParameterID) throws -> ParameterRange {
        var info = AudioUnitParameterInfo()
        var size = UInt32(MemoryLayout.size(ofValue: info))
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo,
                                       kAudioUnitScope_Global, parameter, &info, &size),
                  "Reading parameter \(parameter)")
        if info.flags.contains(.flag_CFNameRelease) {
            info.cfNameString?.release()
        }
        return ParameterRange(minimum: info.minValue, maximum: info.maxValue,
                              defaultValue: info.defaultValue)
    }

    func configure(mix: Float, quality: Quality) throws -> Quality {
        let mixRange = try range(kAUSoundIsolationParam_WetDryMixPercent)
        guard mix.isFinite, mixRange.contains(mix) else {
            throw SingError("This macOS processor supports mix values from \(mixRange.minimum) to \(mixRange.maximum); requested \(mix).")
        }
        let qualityRange = try range(kAUSoundIsolationParam_SoundToIsolate)
        let resolved: Quality = quality == .auto
            ? (qualityRange.contains(0) ? .high : .standard) : quality
        let selector: Float = resolved == .high ? 0 : 1
        guard qualityRange.contains(selector) else {
            throw SingError("The \(resolved.rawValue) voice model is unavailable on this macOS version. Try --quality auto.")
        }
        try check(AudioUnitSetParameter(unit, kAUSoundIsolationParam_SoundToIsolate,
                                        kAudioUnitScope_Global, 0, selector, 0), "Selecting voice model")
        try check(AudioUnitSetParameter(unit, kAUSoundIsolationParam_WetDryMixPercent,
                                        kAudioUnitScope_Global, 0, mix, 0), "Setting mix")
        return resolved
    }

    func latency() throws -> Double {
        var seconds: Float64 = 0
        var size = UInt32(MemoryLayout.size(ofValue: seconds))
        try check(AudioUnitGetProperty(unit, kAudioUnitProperty_Latency,
                                       kAudioUnitScope_Global, 0, &seconds, &size), "Reading latency")
        guard seconds.isFinite, seconds >= 0, seconds < 10 else {
            throw SingError("The processor reported an invalid latency: \(seconds).")
        }
        return seconds
    }
}

public func processorInfo() throws -> ProcessorInfo {
    let host = try IsolationUnit()
    let qualityRange = try host.range(kAUSoundIsolationParam_SoundToIsolate)
    return ProcessorInfo(
        name: "Apple AUSoundIsolation", component: "aufx/vois/appl",
        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        mix: try host.range(kAUSoundIsolationParam_WetDryMixPercent),
        qualities: qualityRange.contains(0) ? ["standard", "high"] : ["standard"],
        modelDirectory: "/System/Library/Components/AudioDSP.component/Contents/Resources/Tunings/Generic/AU/SoundIsolation"
    )
}
