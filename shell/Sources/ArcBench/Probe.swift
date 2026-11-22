import AppKit
import ArcBenchCore
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SidebarModel

/// `arc-vs-rearc probe …` (ProbeCommand): one measurement per call for the performance
/// check, from outside the browser, the same way for every browser. Exit 0 measured,
/// 1 failed (the JSON says why), 2 usage, 75 conditions (gate, lock, locked screen).
@MainActor
enum Probe {
    static func main(_ arguments: [String]) async -> Int32 {
        let command: ProbeCommand
        do {
            command = try ProbeCommand.parse(arguments)
        } catch {
            StandardError.write("\(error)\n")
            return 2
        }
        if case .window = command {} else {
            guard InputGuard.gateOpen else { return refuse("no input gate \(InputGuard.gate.path)") }
            guard !Session.screenLocked else { return refuse("the screen is locked") }
        }
        do {
            switch command {
            case let .launch(bundleID, arguments, timeoutMs):
                return emit(try await launch(bundleID: bundleID, openArguments: arguments, timeout: Double(timeoutMs) / 1000))
            case let .window(pid):
                return emit(["pid": Int(pid), "windows": WindowList.normal(pid: pid).filter(WindowList.isBrowserSized).map(describe)])
            case let .frame(pid, window, rect):
                let frame = CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3])
                guard AX.setFrame(pid, windowID: window, frame) else { throw Failure("could not set window \(window)'s frame") }
                try await Task.sleep(nanoseconds: 500_000_000)
                let now = WindowList.normal(pid: pid).first { $0.id == window }
                return emit(["ok": true, "window": now.map(describe) ?? [:]])
            case let .key(probe):
                guard InputGuard.lockHeld else { return refuse("the input lock \(InputGuard.lock.path) is not held by the caller") }
                return emit(try await key(probe))
            case let .quit(pid, timeoutMs):
                return emit(try await quit(pid: pid, timeout: Double(timeoutMs) / 1000))
            case let .record(pid, out, seconds, fps, stopFile):
                return emit(try await record(pid: pid, out: URL(fileURLWithPath: out), seconds: seconds, fps: fps, stopFile: stopFile))
            }
        } catch let error as GateClosed {
            _ = emit(["ok": false, "error": "\(error)"])
            return 75
        } catch {
            _ = emit(["ok": false, "error": "\(error)"])
            return 1
        }
    }

    private static func refuse(_ reason: String) -> Int32 {
        _ = emit(["ok": false, "refused": reason])
        return 75
    }

    @discardableResult
    private static func emit(_ object: [String: Any]) -> Int32 {
        var object = object
        if object["ok"] == nil { object["ok"] = true }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        print(String(decoding: data, as: UTF8.self))
        return object["ok"] as? Bool == false ? 1 : 0
    }

    private static func describe(_ window: WindowInfo) -> [String: Any] {
        ["id": Int(window.id), "x": window.bounds.minX, "y": window.bounds.minY, "width": window.bounds.width,
         "height": window.bounds.height, "display": Display.name(for: window.bounds), "refresh_hz": Display.refreshHz(for: window.bounds)]
    }

    // MARK: launch

    /// `open …` → the first browser-sized on-screen window of a process of `bundleID` that
    /// was not running before. Timed from just before `open` starts, on the host clock.
    static func launch(bundleID: String, openArguments: [String], timeout: Double) async throws -> [String: Any] {
        let before = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = openArguments
        let epoch = Date().timeIntervalSince1970
        let start = HostClock.now
        try process.run()
        let deadline = start + timeout
        var newPID: pid_t?
        while HostClock.now < deadline {
            if newPID == nil {
                newPID = runningPIDs(bundleID).first { !before.contains($0) }
            }
            if let pid = newPID, let window = WindowList.browserWindow(pid: pid) {
                let seen = HostClock.now
                process.waitUntilExit()
                return ["pid": Int(pid), "window": describe(window), "window_ms": (seen - start) * 1000,
                        "started_epoch_ms": epoch * 1000, "open_status": Int(process.terminationStatus)]
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure(newPID == nil ? "no new \(bundleID) process within \(Int(timeout)) s"
                                    : "\(bundleID) pid \(newPID!) showed no browser window within \(Int(timeout)) s")
    }

    /// Every process of the bundle, also ones LaunchServices has not registered yet.
    private static func runningPIDs(_ bundleID: String) -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier)
    }

    // MARK: key

    static func key(_ probe: ProbeCommand.KeyProbe) async throws -> [String: Any] {
        if let refusal = ProbeChord.refusal(probe.chord, reserved: MacShortcuts.reserved) { throw Failure(refusal) }
        guard let window = WindowList.normal(pid: probe.pid).first(where: { $0.id == probe.window }) else {
            throw Failure("window \(probe.window) of pid \(probe.pid) is not on screen")
        }
        let refreshHz = Display.refreshHz(for: window.bounds)
        let settings = DetectionSettings(areaThreshold: DiffSettings().areaThreshold, quiet: Double(probe.quietMs) / 1000,
                                         timeout: Double(probe.timeoutMs) / 1000)
        func ensureKey() throws {
            guard InputGuard.gateOpen else { throw GateClosed() }
            if AX.isKey(probe.pid, windowID: probe.window) { return }
            guard AX.activate(probe.pid, windowID: probe.window) || AX.activate(probe.pid, windowID: probe.window) else {
                throw Failure("the window is not key: \(AX.describeFocus(probe.pid, expected: probe.window))")
            }
        }
        switch probe.measure {
        case .none:
            try ensureKey()
            let posted = Keyboard.press(probe.chord)
            return ["posted": true, "chord": probe.chord.label, "posted_host_s": posted]
        case .newWindow:
            try ensureKey()
            let before = Set(WindowList.normal(pid: probe.pid).map(\.id))
            guard AX.isKey(probe.pid, windowID: probe.window) else { throw Failure("focus moved before the key") }
            let posted = Keyboard.press(probe.chord)
            let seen = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInteractive).async {
                    continuation.resume(returning: WindowList.waitForChange(pid: probe.pid, before: before, closing: nil, timeout: settings.timeout))
                }
            }
            guard let seen else { throw Failure("no new window within \(probe.timeoutMs) ms") }
            let opened = seen.window.flatMap { id in WindowList.normal(pid: probe.pid).first { $0.id == id } }
            return ["chord": probe.chord.label, "ms": (seen.time - posted) * 1000, "resolution_ms": seen.period * 1000,
                    "window": opened.map(describe) ?? ["id": Int(seen.window ?? 0)]]
        case .frames:
            let capture = WindowCapture(windowID: probe.window, regions: ["m": probe.region], diff: DiffSettings(), keepFrames: nil)
            try await capture.start(refreshHz: refreshHz, scale: 0.5)
            defer { Task { await capture.stop() } }
            for _ in 0 ..< 200 where !capture.hasFrame { try await Task.sleep(nanoseconds: 10_000_000) }
            guard capture.hasFrame else { throw Failure("no frame of window \(probe.window) within 2 s") }
            try ensureKey()
            // Post only into a still window (up to 3 s of waiting).
            let quietUntil = HostClock.now + 3
            var still = true
            while !capture.isQuiet(window: Double(probe.preQuietMs) / 1000, areaThreshold: settings.areaThreshold) {
                if HostClock.now > quietUntil { still = false; break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard AX.isKey(probe.pid, windowID: probe.window), InputGuard.gateOpen else { throw Failure("focus moved before the key") }
            capture.arm()
            let posted = Keyboard.press(probe.chord)
            var detection = Detection.pending
            while detection == .pending {
                try await Task.sleep(nanoseconds: 5_000_000)
                if let failure = capture.failure { throw Failure("capture stopped: \(failure)") }
                detection = Detector.detect(capture.samples("m"), postTime: posted, now: HostClock.now, settings: settings)
            }
            await capture.stop()
            var result: [String: Any] = ["chord": probe.chord.label, "resolution_ms": 1000 / Double(refreshHz),
                                         "refresh_hz": refreshHz, "window_was_still": still]
            switch detection {
            case let .measured(ack, settled):
                result["ack_ms"] = ack * 1000
                result["settled_ms"] = settled.map { $0 * 1000 } ?? NSNull()
            default:
                result["ok"] = false
                result["error"] = "no change within \(probe.timeoutMs) ms"
            }
            return result
        }
    }

    // MARK: quit

    /// The app's own quit (NSRunningApplication.terminate, as ⌘Q), then waits. Never forces.
    static func quit(pid: pid_t, timeout: Double) async throws -> [String: Any] {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return ["exited": true, "was_running": false] }
        let start = HostClock.now
        guard app.terminate() else { throw Failure("pid \(pid) did not accept the quit request") }
        while HostClock.now - start < timeout {
            if app.isTerminated || kill(pid, 0) != 0 { return ["exited": true, "ms": (HostClock.now - start) * 1000] }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw Failure("pid \(pid) was still running \(Int(timeout)) s after the quit request")
    }

    // MARK: record

    /// Records only the app's windows (an app filter on its display) to H.264 MP4.
    static func record(pid: pid_t, out: URL, seconds: Double, fps: Int, stopFile: String?) async throws -> [String: Any] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let app = content.applications.first(where: { $0.processID == pid }) else { throw Failure("no app with pid \(pid) on screen") }
        let windows = WindowList.normal(pid: pid)
        let anchor = windows.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }?.bounds
        let display = content.displays.first { anchor.map($0.frame.intersects) ?? false } ?? content.displays.first
        guard let display else { throw Failure("no display") }
        let scale = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID
        }?.backingScaleFactor ?? 2
        let width = Int(Double(display.width) * scale) & ~1
        let height = Int(Double(display.height) * scale) & ~1
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let recorder = try AppRecorder(out: out, width: width, height: height)
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.queueDepth = 8
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: recorder.queue)
        try await stream.startCapture()

        var stopReason = "time limit"
        let signals = SignalFlag([SIGINT, SIGTERM, SIGHUP])
        let started = HostClock.now
        while HostClock.now - started < seconds {
            if signals.raised { stopReason = "signal"; break }
            if let stopFile, FileManager.default.fileExists(atPath: stopFile) { stopReason = "stop file"; break }
            if !InputGuard.gateOpen { stopReason = "input gate removed"; break }
            if Session.screenLocked { stopReason = "screen locked"; break }
            if NSRunningApplication(processIdentifier: pid) == nil { stopReason = "app quit"; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await stream.stopCapture()
        let frames = await recorder.finish()
        return ["out": out.path, "frames": frames, "seconds": HostClock.now - started, "stopped_by": stopReason,
                "size": [width, height], "display": display.displayID]
    }
}

/// Writes SCStream frames to an MP4 as they come.
final class AppRecorder: NSObject, SCStreamOutput {
    let queue = DispatchQueue(label: "rearc.arc-vs-rearc.record", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private var started = false
    private var frames = 0

    init(out: URL, width: Int, height: Int) throws {
        writer = try AVAssetWriter(outputURL: out, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure("cannot write H.264 at \(width)×\(height)") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure("cannot start writing: \(writer.error.map { "\($0)" } ?? "?")") }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) { frames += 1 }
    }

    func finish() async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
        input.markAsFinished()
        if started {
            await writer.finishWriting()
        } else {
            writer.cancelWriting()
        }
        return frames
    }
}

/// Set once any of the signals arrives (the recorder stops at its next check).
final class SignalFlag: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var flag = false

    init(_ numbers: [Int32]) {
        for number in numbers {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in self?.lock.withLock { self?.flag = true } }
            source.resume()
            sources.append(source)
        }
    }

    var raised: Bool { lock.withLock { flag } }
}
