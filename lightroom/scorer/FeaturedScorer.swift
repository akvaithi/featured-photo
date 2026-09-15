import Foundation

/// featured-scorer — the pixel half of Featured Photo, as a command-line tool.
///
/// Two ways in:
///
///   featured-scorer --folder ~/Pictures/shoot     scan a folder of files
///   featured-scorer < job.json > result.json      serve the Lightroom plug-in
///
/// The folder mode is the standalone one: no Photos library, no catalog, just
/// image files, EXIF and the same algorithm. The stdin mode is what the plug-in
/// speaks, because Lightroom's SDK is Lua and cannot analyse an image; there the
/// plug-in has already done the catalog-metadata gating and sends only groups.
///
/// Both meet in `Pipeline`. See lightroom/README.md.
@main
struct FeaturedScorer {

    static let version = "0.2.0"

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--version") {
            print(version)
            return
        }
        if args.contains("--help") || args.contains("-h") {
            print(usage)
            return
        }

        do {
            if let index = args.firstIndex(of: "--folder") {
                guard index + 1 < args.count else { throw ScorerError.missingValue("--folder") }
                try await runFolder(path: args[index + 1], args: args)
            } else {
                try await runJob()
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static let usage = """
        featured-scorer \(version)

        Groups near-identical photos and picks the best frame of each group.

        FOLDER MODE
          featured-scorer --folder <path> [options]

            --time-window <seconds>   max gap between frames in one burst (default 12)
            --threshold <distance>    similarity cutoff, lower is stricter (default 0.5)
            --any-camera              group frames from different cameras too
            --no-recurse              do not descend into subfolders
            --analysis-size <pixels>  longest edge Vision sees (default 256)
            --json                    machine-readable output

        PLUG-IN MODE
          featured-scorer < job.json > result.json

          Job:    { "similarityThreshold": 0.5, "analysisSize": 256,
                    "groups": [ { "photos": [ { "id": "…", "path": "…" } ] } ] }
          Result: { "version": "…", "stacks": [ { "items": [ … ] } ], "unreadable": [ … ] }

        Progress goes to stderr; stdout carries only the result.
        """

    enum ScorerError: LocalizedError {
        case emptyInput
        case missingValue(String)
        case badValue(String, String)
        case notADirectory(String)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "no job was supplied on stdin (did you mean --folder?)"
            case .missingValue(let flag):
                return "\(flag) needs a value"
            case .badValue(let flag, let value):
                return "\(flag) does not accept '\(value)'"
            case .notADirectory(let path):
                return "not a folder: \(path)"
            }
        }
    }

    // MARK: - Argument helpers

    static func value(_ flag: String, in args: [String]) throws -> String? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard index + 1 < args.count else { throw ScorerError.missingValue(flag) }
        return args[index + 1]
    }

    static func double(_ flag: String, in args: [String], default fallback: Double) throws -> Double {
        guard let text = try value(flag, in: args) else { return fallback }
        guard let parsed = Double(text) else { throw ScorerError.badValue(flag, text) }
        return parsed
    }

    static func int(_ flag: String, in args: [String], default fallback: Int) throws -> Int {
        guard let text = try value(flag, in: args) else { return fallback }
        guard let parsed = Int(text) else { throw ScorerError.badValue(flag, text) }
        return parsed
    }

    // MARK: - Folder mode

    static func runFolder(path: String, args: [String]) async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw ScorerError.notADirectory(url.path) }

        var options = FolderScan.Options()
        options.timeWindow = try double("--time-window", in: args, default: options.timeWindow)
        options.threshold = try double("--threshold", in: args, default: options.threshold)
        options.analysisSize = try int("--analysis-size", in: args, default: options.analysisSize)
        options.requireSameCamera = !args.contains("--any-camera")
        options.recursive = !args.contains("--no-recurse")

        let wantsJSON = args.contains("--json")
        let report = await FolderScan.run(root: url, options: options) { index, total in
            progress("group \(index)/\(total)")
        }

        if wantsJSON {
            // Same shape as plug-in mode, so anything that parses one parses both.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let result = Result(
                version: version,
                stacks: report.stacks,
                unreadable: report.unreadable
            )
            FileHandle.standardOutput.write(try encoder.encode(result))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print(FolderScan.describe(report, options: options))
        }
    }

    // MARK: - Plug-in mode

    struct Job: Decodable {
        struct Photo: Decodable {
            let id: String
            let path: String
        }
        struct Group: Decodable {
            let photos: [Photo]
        }
        /// Feature-print distance below which two photos are "the same shot".
        var similarityThreshold: Double = 0.5
        /// Longest edge Vision sees. Small keeps it fast; the models are robust to it.
        var analysisSize: Int = 256
        var groups: [Group]
    }

    struct Result: Encodable {
        let version: String
        let stacks: [Pipeline.Stack]
        /// Photos whose file could not be decoded. They are never stacked.
        let unreadable: [String]
    }

    static func runJob() async throws {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty else { throw ScorerError.emptyInput }
        let job = try JSONDecoder().decode(Job.self, from: data)

        let groups = job.groups.map { group in
            group.photos.map { Pipeline.Input(id: $0.id, path: $0.path) }
        }
        let output = await Pipeline.run(
            groups: groups,
            threshold: job.similarityThreshold,
            analysisSize: job.analysisSize
        ) { index, total in
            progress("group \(index)/\(total)")
        }

        progress("done: \(output.stacks.count) stacks")
        let result = Result(version: version, stacks: output.stacks, unreadable: output.unreadable)
        FileHandle.standardOutput.write(try JSONEncoder().encode(result))
    }

    /// Progress goes to stderr — stdout carries the JSON the plug-in parses.
    static func progress(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }
}
