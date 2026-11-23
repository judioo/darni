import Combine
import SidebarModel

/// Engines that report a tab's camera and microphone use (Chromium
/// `media_capture`, ABI 1.46), for the sidebar's call card.
protocol MediaCaptureProviding: AnyObject {
    var mediaCapturePublisher: AnyPublisher<MediaCaptureState, Never> { get }
    /// Asks the page to flip a device; false when it can't (no handler).
    @discardableResult
    func toggleCapture(_ device: MediaCaptureState.Device) -> Bool
}

/// Engines whose pages can share a tab, a window or the screen (Chromium
/// `display_capture`, ABI 1.70).
protocol ScreenShareProviding: AnyObject {
    /// The engine's own number for this tab while its page runs, which an
    /// answer names as the tab to share; nil when there is nothing to share
    /// (not loaded, discarded, crashed).
    var screenShareTargetID: UInt64? { get }
    /// Ends everything the page shares; false when the engine refused (it shares nothing).
    @discardableResult
    func stopScreenShare() -> Bool
}
