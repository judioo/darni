#if REARC_CHROMIUM
import Foundation
import ReArcEngine
import SidebarModel

/// Owned copy of `ReArcPageTimingEvent` (ABI 1.44): a main-frame milestone
/// of one navigation, on the engine's clock (microseconds of mach time, the
/// clock of `CACurrentMediaTime` and `NSEvent.timestamp`).
struct ChromiumPageTiming: Equatable {
    enum Kind: UInt32 {
        case responseStart = 0, firstPaint, firstContentfulPaint, domContentLoaded, loadEventStart, largestContentfulPaint
    }
    var profileID, tabID, contentGeneration, navigationID: UInt64
    var kind: Kind
    var navigationStartMicros, valueMicros: Int64
    var size: UInt64
    var url: String

    var milliseconds: Double { Double(valueMicros - navigationStartMicros) / 1000 }
}

/// Owned copy of `ReArcViewPresentationEvent`: the frame Chromium presented
/// after a lease turned visible (`shown`) or was resized (`resized`).
struct ChromiumViewPresentation: Equatable {
    enum Kind: UInt32 { case shown = 0, resized = 1 }
    enum Status: UInt32 { case presented = 0, incomplete = 1, superseded = 2, timedOut = 3 }
    var profileID, tabID, attachmentID, requestID: UInt64
    var kind: Kind
    var status: Status
    var startMicros, activatedMicros, presentedMicros: Int64
    var width, height: Int32
}

struct ChromiumHistogram: Equatable {
    struct Bucket: Equatable { var min, max, count: Int64 }
    var name: String
    var count, sum: Int64
    var buckets: [Bucket]
}

struct ChromiumProcessInfo: Equatable {
    enum Kind: UInt32 { case browser = 0, renderer, gpu, utility, other }
    var pid: Int32
    var kind: Kind
    var name: String
    var profileID: UInt64
    var isExtension: Bool
    var tabIDs: [UInt64]
    var physFootprint, residentSize: UInt64
    var cpuMicros: Int64
    /// What `task_manager` (ABI 1.65) adds for the Task Manager; nil from an engine without it.
    var details: TaskManagerProcess.Details?
}

/// The bench's engine measurement channels. `install` registers both
/// callbacks once, before any tab exists (page timing attaches at tab
/// creation); the normal app never installs them.
@MainActor
final class ChromiumPerfMetrics {
    static let shared = ChromiumPerfMetrics()

    var onPageTiming: ((ChromiumPageTiming) -> Void)?
    var onViewPresentation: ((ChromiumViewPresentation) -> Void)?
    private(set) var isInstalled = false

    func install(capabilities: ChromiumCapabilities) -> Bool {
        guard capabilities.perfMetrics else { return false }
        guard !isInstalled else { return true }
        ReArcEngineSetPageTimingCallback(pageTimingCallback, nil)
        ReArcEngineSetViewPresentationCallback(viewPresentationCallback, nil)
        isInstalled = true
        return true
    }

    func histogram(_ name: String) async -> ChromiumHistogram? {
        await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
            let status = name.withCString { ReArcMetricsGetHistogram($0, histogramCallback, box) }
            if status != .rearcOK {
                Unmanaged<Box<ChromiumHistogram?>>.fromOpaque(box).release()
                continuation.resume(returning: nil)
            }
        }
    }

    /// `ReArcEngineGetProcessDetails` (ABI 1.65): the same list with a JSON
    /// object of what the Task Manager shows besides. Looked up by name, so
    /// the shell builds and runs against an engine without it.
    private typealias ProcessDetailsCallback = @convention(c) (
        UnsafeMutableRawPointer?, ReArcStatus, UnsafePointer<ReArcProcessInfo>?, Int, UnsafePointer<CChar>?
    ) -> Void
    private typealias GetProcessDetails = @convention(c) (ProcessDetailsCallback?, UnsafeMutableRawPointer?) -> ReArcStatus

    /// True when the engine's list carries `ChromiumProcessInfo.details`.
    var hasProcessDetails: Bool { getProcessDetails != nil }

    private var getProcessDetails: GetProcessDetails? {
        guard ReArcEngineHasFeature("task_manager"),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ReArcEngineGetProcessDetails") else { return nil }
        return unsafeBitCast(symbol, to: GetProcessDetails.self)
    }

    func processes() async -> [ChromiumProcessInfo] {
        let getProcessDetails = getProcessDetails
        return await withCheckedContinuation { continuation in
            let box = Unmanaged.passRetained(Box(continuation)).toOpaque()
            let status = getProcessDetails.map { $0(processDetailsCallback, box) } ?? ReArcEngineGetProcesses(processesCallback, box)
            if status != .rearcOK {
                Unmanaged<Box<[ChromiumProcessInfo]>>.fromOpaque(box).release()
                continuation.resume(returning: [])
            }
        }
    }

    fileprivate final class Box<Value> {
        let continuation: CheckedContinuation<Value, Never>
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    }
}

private let pageTimingCallback: ReArcPageTimingCallback = { _, event in
    guard let e = event?.pointee, let kind = ChromiumPageTiming.Kind(rawValue: e.kind) else { return }
    let timing = ChromiumPageTiming(
        profileID: e.profile_id, tabID: e.tab_id, contentGeneration: e.content_generation, navigationID: e.navigation_id,
        kind: kind, navigationStartMicros: e.navigation_start_us, valueMicros: e.value_us, size: e.size,
        url: e.url.map { String(cString: $0) } ?? ""
    )
    MainActor.assumeIsolated { ChromiumPerfMetrics.shared.onPageTiming?(timing) }
}

private let viewPresentationCallback: ReArcViewPresentationCallback = { _, event in
    guard let e = event?.pointee, let kind = ChromiumViewPresentation.Kind(rawValue: e.kind),
          let status = ChromiumViewPresentation.Status(rawValue: e.status) else { return }
    let presentation = ChromiumViewPresentation(
        profileID: e.profile_id, tabID: e.tab_id, attachmentID: e.attachment_id, requestID: e.request_id,
        kind: kind, status: status, startMicros: e.start_us, activatedMicros: e.activated_us,
        presentedMicros: e.presented_us, width: e.width, height: e.height
    )
    MainActor.assumeIsolated { ChromiumPerfMetrics.shared.onViewPresentation?(presentation) }
}

private let histogramCallback: ReArcHistogramCallback = { context, status, histogram in
    let box = Unmanaged<ChromiumPerfMetrics.Box<ChromiumHistogram?>>.fromOpaque(context!).takeRetainedValue()
    guard status == .rearcOK, let h = histogram?.pointee else { return box.continuation.resume(returning: nil) }
    let buckets = UnsafeBufferPointer(start: h.buckets, count: h.bucket_count).map {
        ChromiumHistogram.Bucket(min: $0.min, max: $0.max, count: $0.count)
    }
    box.continuation.resume(returning: ChromiumHistogram(name: String(cString: h.name), count: h.count, sum: h.sum, buckets: buckets))
}

private let processesCallback: ReArcProcessListCallback = { context, status, processes, count in
    resumeProcesses(context, status, processes, count, detailsJSON: nil)
}

private let processDetailsCallback: @convention(c) (
    UnsafeMutableRawPointer?, ReArcStatus, UnsafePointer<ReArcProcessInfo>?, Int, UnsafePointer<CChar>?
) -> Void = { context, status, processes, count, json in
    resumeProcesses(context, status, processes, count, detailsJSON: json.map { String(cString: $0) } ?? "{}")
}

/// Both lists' completion. `detailsJSON` nil: the engine has no details;
/// otherwise every process gets them, empty where the JSON names none.
private func resumeProcesses(
    _ context: UnsafeMutableRawPointer?, _ status: ReArcStatus, _ processes: UnsafePointer<ReArcProcessInfo>?, _ count: Int,
    detailsJSON: String?
) {
    let box = Unmanaged<ChromiumPerfMetrics.Box<[ChromiumProcessInfo]>>.fromOpaque(context!).takeRetainedValue()
    guard status == .rearcOK else { return box.continuation.resume(returning: []) }
    let details = detailsJSON.map(TaskManagerProcess.Details.byProcess(json:))
    let rows = UnsafeBufferPointer(start: processes, count: count).map { p in
        ChromiumProcessInfo(
            pid: p.pid, kind: ChromiumProcessInfo.Kind(rawValue: p.type) ?? .other,
            name: p.name.map { String(cString: $0) } ?? "", profileID: p.profile_id, isExtension: p.is_extension,
            tabIDs: Array(UnsafeBufferPointer(start: p.tab_ids, count: p.tab_count)),
            physFootprint: p.phys_footprint, residentSize: p.resident_size, cpuMicros: p.cpu_time_us,
            details: details.map { $0[p.pid] ?? TaskManagerProcess.Details() }
        )
    }
    box.continuation.resume(returning: rows)
}
#endif
