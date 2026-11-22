import Testing
@testable import ArcBenchCore

/// The performance check's probe command line.
struct ProbeCommandTests {
    @Test func launchKeepsTheOpenArgumentsAfterTheDashes() throws {
        let command = try ProbeCommand.parse(["launch", "--bundle-id", "com.google.Chrome", "--", "-n", "-a", "/Applications/Google Chrome.app",
                                              "--args", "--user-data-dir=/tmp/x", "--", "http://127.0.0.1:9/p"])
        #expect(command == .launch(bundleID: "com.google.Chrome",
                                   openArguments: ["-n", "-a", "/Applications/Google Chrome.app", "--args", "--user-data-dir=/tmp/x", "--", "http://127.0.0.1:9/p"],
                                   timeoutMs: 60000))
        #expect(throws: ProbeCommand.UsageError.self) { try ProbeCommand.parse(["launch", "--bundle-id", "x"]) }
        #expect(throws: ProbeCommand.UsageError.self) { try ProbeCommand.parse(["launch", "--", "-n"]) }
    }

    @Test func keyDefaultsAndOptions() throws {
        let plain = try ProbeCommand.parse(["key", "--pid", "42", "--window", "7", "--chord", "cmd+t"])
        #expect(plain == .key(.init(pid: 42, window: 7, chord: .commandT)))
        let full = try ProbeCommand.parse(["key", "--pid", "42", "--window", "7", "--chord", "cmd+2", "--measure", "frames",
                                           "--region", "content", "--sidebar-fraction", "0.2", "--timeout-ms", "2000"])
        guard case let .key(probe) = full else { Issue.record("not a key probe"); return }
        #expect(probe.chord == .digit(2, .command))
        #expect(probe.region == .content(0.2))
        #expect(probe.timeoutMs == 2000)
        let window = try ProbeCommand.parse(["key", "--pid", "42", "--window", "7", "--chord", "cmd+n", "--measure", "new-window"])
        guard case let .key(newWindow) = window else { Issue.record("not a key probe"); return }
        #expect(newWindow.measure == .newWindow)
    }

    @Test func keyRefusesControlWithADigitBeforeAnythingRuns() {
        #expect(throws: ProbeCommand.UsageError.self) {
            try ProbeCommand.parse(["key", "--pid", "42", "--window", "7", "--chord", "ctrl+2"])
        }
    }

    @Test func rejectsUnknownOptionsAndBadValues() {
        for arguments in [["key", "--pid", "42", "--window", "7", "--chord", "cmd+t", "--colour", "red"],
                          ["key", "--pid", "0", "--window", "7", "--chord", "cmd+t"],
                          ["key", "--pid", "42", "--window", "7", "--chord", "cmd+t", "--measure", "pixels"],
                          ["frame", "--pid", "42", "--window", "7", "--rect", "0,0,1440"],
                          ["frame", "--pid", "42", "--window", "7", "--rect", "0,0,0,900"],
                          ["record", "--pid", "42"], ["teleport"], []] {
            #expect(throws: ProbeCommand.UsageError.self) { try ProbeCommand.parse(arguments) }
        }
    }

    @Test func quitTakesAPidAndAnOptionalTimeout() throws {
        #expect(try ProbeCommand.parse(["quit", "--pid", "42"]) == .quit(pid: 42, timeoutMs: 20000))
        #expect(try ProbeCommand.parse(["quit", "--pid", "42", "--timeout-ms", "5000"]) == .quit(pid: 42, timeoutMs: 5000))
        #expect(throws: ProbeCommand.UsageError.self) { try ProbeCommand.parse(["quit"]) }
    }

    @Test func frameAndRecord() throws {
        #expect(try ProbeCommand.parse(["frame", "--pid", "42", "--window", "7", "--rect", "40,60,1440,900"])
            == .frame(pid: 42, window: 7, rect: [40, 60, 1440, 900]))
        #expect(try ProbeCommand.parse(["record", "--pid", "42", "--out", "/tmp/a.mp4", "--seconds", "600", "--stop-file", "/tmp/stop"])
            == .record(pid: 42, out: "/tmp/a.mp4", seconds: 600, fps: 30, stopFile: "/tmp/stop"))
    }
}
