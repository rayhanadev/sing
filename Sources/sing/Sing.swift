import Foundation
import SingCore

private let version = "0.1.0"
private let usage = """
sing — local voice isolation with Apple's built-in macOS audio processor

USAGE
  sing vocals INPUT -o OUTPUT.wav [OPTIONS]
  sing instrumental INPUT -o OUTPUT.wav [OPTIONS]
  sing process INPUT -o OUTPUT.wav --mix NUMBER [OPTIONS]
  sing info [--json]

COMMANDS
  vocals         Isolate the voice (+100 mix).
  instrumental   Suppress the voice (-100 mix).
  process        Choose a mix from -100 to +100; 0 keeps the original mix.
  info           Inspect the installed processor and supported models.

OPTIONS
  -o, --output PATH      Required output path; 32-bit float WAV.
  --quality VALUE        auto (default), high, or standard.
  --mix NUMBER           Required for process; -100 through +100.
  --force                Replace an existing output after processing succeeds.
  --json                 Print a JSON result; errors are JSON on stderr.
  -h, --help             Show help.
  --version              Show version.

Accepts audio files decoded by macOS (including WAV, AIFF, MP3, M4A, FLAC).
Preserves sample rate, mono/stereo channels, and frame count. Runs offline.
Requires macOS 13+. Model and mix availability depend on the installed OS.
"""

private struct UsageError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct ErrorResult: Encodable {
    let error: String
    let exitCode: Int32
}

private struct Options {
    var command: String
    var input: String?
    var output: String?
    var mix: Float?
    var quality: Quality = .auto
    var force = false
    var json = false

    init(_ arguments: [String]) throws {
        guard let command = arguments.first, ["vocals", "instrumental", "process", "info"].contains(command) else {
            throw UsageError(message: "Expected vocals, instrumental, process, or info. Run sing --help.")
        }
        self.command = command
        var index = 1
        var seen = Set<String>()
        var positionalOnly = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if argument == "--", !positionalOnly { positionalOnly = true; continue }
            if positionalOnly || !argument.hasPrefix("-") {
                guard input == nil else { throw UsageError(message: "Only one input file is accepted.") }
                input = argument
                continue
            }
            let key = argument == "-o" ? "--output" : argument
            guard seen.insert(key).inserted else { throw UsageError(message: "Repeated option: \(argument).") }
            func value() throws -> String {
                guard index < arguments.count else { throw UsageError(message: "Missing value for \(argument).") }
                defer { index += 1 }
                return arguments[index]
            }
            switch key {
            case "--output": output = try value()
            case "--mix":
                let raw = try value()
                guard let parsed = Float(raw), parsed.isFinite, (-100...100).contains(parsed) else {
                    throw UsageError(message: "--mix must be a finite number from -100 to 100.")
                }
                mix = parsed
            case "--quality":
                let raw = try value()
                guard let parsed = Quality(rawValue: raw) else {
                    throw UsageError(message: "--quality must be auto, high, or standard.")
                }
                quality = parsed
            case "--force": force = true
            case "--json": json = true
            default: throw UsageError(message: "Unknown option: \(argument). Run sing --help.")
            }
        }
        if command == "info" {
            guard input == nil, seen.isSubset(of: ["--json"]) else {
                throw UsageError(message: "sing info only accepts --json.")
            }
        } else {
            guard input != nil, let output, !output.isEmpty else {
                throw UsageError(message: "An input file and -o OUTPUT.wav are required.")
            }
            if command == "process", mix == nil { throw UsageError(message: "sing process requires --mix.") }
            if command != "process", mix != nil { throw UsageError(message: "Use sing process for a custom --mix.") }
            if command == "vocals" { mix = 100 }
            if command == "instrumental" { mix = -100 }
        }
    }
}

private func json<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value) + Data([10])
}

@main
struct Sing {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty || arguments == ["--help"] || arguments == ["-h"]
            || (arguments.count == 2 && ["vocals", "instrumental", "process", "info"].contains(arguments[0])
                && ["--help", "-h"].contains(arguments[1])) {
            print(usage)
            return
        }
        if arguments == ["--version"] { print("sing \(version)"); return }
        do {
            let options = try Options(arguments)
            if options.command == "info" {
                let info = try processorInfo()
                if options.json {
                    FileHandle.standardOutput.write(try json(info))
                } else {
                    print("\(info.name) (\(info.component))")
                    print("\(info.macOS)")
                    print("Mix: \(info.mix.minimum)...\(info.mix.maximum)")
                    print("Models: \(info.qualities.joined(separator: ", "))")
                    print("Resources: \(info.modelDirectory)")
                }
            } else {
                let result = try processAudio(
                    input: URL(fileURLWithPath: options.input!), output: URL(fileURLWithPath: options.output!),
                    mix: options.mix!, quality: options.quality, overwrite: options.force
                )
                if options.json {
                    FileHandle.standardOutput.write(try json(result))
                } else {
                    print(result.output)
                    let details = String(format: "%.2fs audio in %.2fs · %@ model · mix %.0f\n",
                                         result.durationSeconds, result.processingSeconds,
                                         result.quality.rawValue, result.mix)
                    FileHandle.standardError.write(Data(details.utf8))
                }
            }
        } catch {
            let code: Int32 = error is UsageError ? 2 : 1
            if arguments.contains("--json"),
               let encoded = try? json(ErrorResult(error: error.localizedDescription, exitCode: code)) {
                FileHandle.standardError.write(encoded)
            } else {
                FileHandle.standardError.write(Data("sing: \(error.localizedDescription)\n".utf8))
            }
            exit(code)
        }
    }
}
