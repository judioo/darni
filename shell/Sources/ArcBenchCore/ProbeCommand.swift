import Foundation

/// `arc-vs-rearc probe …`: single measurements for the performance check
/// (perf/darni_perf/probe.py drives it; docs/PERFORMANCE-CHIP.md). Each prints one JSON
/// object on stdout.
///
///     probe launch --bundle-id ID [--timeout-ms MS] -- OPEN_ARGS...
///         runs /usr/bin/open OPEN_ARGS and times it to the first browser-sized window of a
///         NEW process with that bundle id
///     probe window --pid PID
///         the process's browser windows (id, bounds, display, refresh rate)
///     probe frame --pid PID --window ID --rect X,Y,W,H
///         moves and sizes the window (Accessibility)
///     probe key --pid PID --window ID --chord CHORD [--measure frames|new-window|none]
///               [--region window|content|X0,Y0,X1,Y1] [--sidebar-fraction F]
///               [--timeout-ms MS] [--quiet-ms MS] [--pre-quiet-ms MS]
///         posts one key to that window (frontmost and key, checked first) and times the
///         first changed frame, or the new window
///     probe quit --pid PID [--timeout-ms MS]
///         asks that one process to quit (as ⌘Q does) and waits for it to exit; never forces
///     probe record --pid PID --out FILE.mp4 [--seconds S] [--fps N] [--stop-file PATH]
///         records only that app's windows on the display it is on, until S seconds, the
///         stop file appears, SIGINT/SIGTERM, or the input gate goes
///
/// Every command that shows, moves, captures or types needs the input gate, an unlocked
/// screen and, for keys, the input lock already held by the caller (the runner holds it
/// for the whole session; the probe never takes or frees it).
public enum ProbeCommand: Equatable, Sendable {
    case launch(bundleID: String, openArguments: [String], timeoutMs: Int)
    case window(pid: Int32)
    case frame(pid: Int32, window: UInt32, rect: [Double])
    case key(KeyProbe)
    case record(pid: Int32, out: String, seconds: Double, fps: Int, stopFile: String?)
    case quit(pid: Int32, timeoutMs: Int)

    public enum KeyMeasure: String, Equatable, Sendable { case frames, newWindow = "new-window", none }

    public struct KeyProbe: Equatable, Sendable {
        public var pid: Int32
        public var window: UInt32
        public var chord: KeyChord
        public var measure: KeyMeasure = .frames
        public var region: Region = .window
        public var timeoutMs = 3000
        public var quietMs = 150
        public var preQuietMs = 300
    }

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String
        public init(_ description: String) { self.description = description }
    }

    public static func parse(_ arguments: [String]) throws -> ProbeCommand {
        guard let verb = arguments.first else { throw UsageError("probe: launch, window, frame, key, quit or record") }
        var rest = Array(arguments.dropFirst())
        var trailing: [String] = []
        if let dash = rest.firstIndex(of: "--") {
            trailing = Array(rest[(dash + 1)...])
            rest = Array(rest[..<dash])
        }
        var values: [String: String] = [:]
        var index = 0
        while index < rest.count {
            let name = rest[index]
            guard name.hasPrefix("--"), index + 1 < rest.count else { throw UsageError("probe \(verb): expected --name value, got \(name)") }
            values[String(name.dropFirst(2))] = rest[index + 1]
            index += 2
        }
        func take(_ name: String) throws -> String {
            guard let value = values.removeValue(forKey: name) else { throw UsageError("probe \(verb): --\(name) is required") }
            return value
        }
        func int<T: FixedWidthInteger>(_ name: String, _ range: ClosedRange<T>, default fallback: T? = nil) throws -> T {
            guard let text = values.removeValue(forKey: name) else {
                if let fallback { return fallback }
                throw UsageError("probe \(verb): --\(name) is required")
            }
            guard let number = T(text), range.contains(number) else { throw UsageError("probe \(verb): --\(name) \(text) is not in \(range)") }
            return number
        }
        func double(_ name: String, _ range: ClosedRange<Double>, default fallback: Double) throws -> Double {
            guard let text = values.removeValue(forKey: name) else { return fallback }
            guard let number = Double(text), range.contains(number) else { throw UsageError("probe \(verb): --\(name) \(text) is not in \(range)") }
            return number
        }
        let command: ProbeCommand
        switch verb {
        case "launch":
            guard !trailing.isEmpty else { throw UsageError("probe launch: the arguments for open go after --") }
            command = .launch(bundleID: try take("bundle-id"), openArguments: trailing, timeoutMs: try int("timeout-ms", 1000 ... 120_000, default: 60000))
        case "window":
            command = .window(pid: try int("pid", 1 ... Int32.max))
        case "frame":
            let pid: Int32 = try int("pid", 1 ... Int32.max)
            let window: UInt32 = try int("window", 1 ... UInt32.max)
            let rect = try take("rect").split(separator: ",").map { Double($0) }
            guard rect.count == 4, rect.allSatisfy({ $0 != nil }), rect[2]! > 0, rect[3]! > 0 else {
                throw UsageError("probe frame: --rect is X,Y,W,H with a positive size")
            }
            command = .frame(pid: pid, window: window, rect: rect.map { $0! })
        case "key":
            let text = try take("chord")
            guard let chord = ProbeChord.parse(text) else { throw UsageError("probe key: unknown chord \(text)") }
            if let refusal = ProbeChord.refusal(chord) { throw UsageError("probe key: \(refusal)") }
            var probe = KeyProbe(pid: try int("pid", 1 ... Int32.max), window: try int("window", 1 ... UInt32.max), chord: chord)
            if let measure = values.removeValue(forKey: "measure") {
                guard let parsed = KeyMeasure(rawValue: measure) else { throw UsageError("probe key: --measure frames, new-window or none") }
                probe.measure = parsed
            }
            let fraction = try double("sidebar-fraction", 0.05 ... 0.6, default: 0.22)
            if let region = values.removeValue(forKey: "region") {
                guard let parsed = Region.parse(region, sidebarFraction: fraction) else { throw UsageError("probe key: --region \(region)") }
                probe.region = parsed
            }
            probe.timeoutMs = try int("timeout-ms", 100 ... 60000, default: 3000)
            probe.quietMs = try int("quiet-ms", 1 ... 10000, default: 150)
            probe.preQuietMs = try int("pre-quiet-ms", 0 ... 10000, default: 300)
            command = .key(probe)
        case "record":
            command = .record(pid: try int("pid", 1 ... Int32.max), out: try take("out"),
                              seconds: try double("seconds", 1 ... 7200, default: 1800), fps: try int("fps", 1 ... 60, default: 30),
                              stopFile: values.removeValue(forKey: "stop-file"))
        case "quit":
            command = .quit(pid: try int("pid", 1 ... Int32.max), timeoutMs: try int("timeout-ms", 1000 ... 120_000, default: 20000))
        default:
            throw UsageError("probe: unknown command \(verb) (launch, window, frame, key, quit, record)")
        }
        if let extra = values.keys.sorted().first { throw UsageError("probe \(verb): unknown option --\(extra)") }
        return command
    }
}
