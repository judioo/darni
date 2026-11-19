import AppKit
import ImageIO
import SidebarModel
import SwiftUI

/// Darni › About Darni: Arc's small About window (close only, no title),
/// with the sunrise sting where Arc shows its icon. The sting plays once each
/// time the window opens and rests on its last frame, the sunrise mark, with
/// the wordmark under it; with Reduce Motion it shows only that. Under the
/// version, the latest version in the update feed (`AboutUpdateLine`).
final class AboutWindowController: NSWindowController {
    static let width: CGFloat = 360

    /// The WebKit shell's; the Chromium host keeps its own, whose links open tabs there.
    @MainActor static let shared = AboutWindowController(center: .shared) { NSWorkspace.shared.open($0) }

    private let sting = AboutStingView()
    private let center: UpdateNoticeCenter?

    /// `center`: where the latest version comes from; nil shows none.
    @MainActor init(center: UpdateNoticeCenter?, openLink: @escaping (URL) -> Void) {
        self.center = center
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "About Darni"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        super.init(window: window)
        let hosting = NSHostingView(rootView: AboutView(sting: sting, center: center, openLink: openLink))
        // The sting runs under the transparent title bar, behind the close
        // button, and the window is exactly as tall as the view.
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func present() {
        if window?.isVisible != true { sting.play() }
        window?.makeKeyAndOrderFront(nil)
        center?.checkUpdateInformation()
    }
}

/// The versions the release script stamps into Info.plist (RELEASE.md, "Versioning").
enum AboutInfo {
    static var version: String { version(Bundle.main.infoDictionary ?? [:]) }

    /// "Version 2026.1112.726"; a version without its build, as before
    /// 2026.1112, keeps it after: "Version 0.1.0 (726)".
    static func version(_ info: [String: Any]) -> String {
        let display = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = (info["CFBundleVersion"] as? String).flatMap(UpdateBuild.init)
        if let shown = ReArcVersion.display(display, build: build) { return "Version \(shown)" }
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return "Version \(display)" }
        return "Version \(display) (\(build))"
    }

    static var engine: String? {
        (Bundle.main.infoDictionary?["ReArcEngineVersion"] as? String).map { "Chromium Engine Version \($0)" }
    }

    static var copyright: String {
        "Copyright © \(Calendar.current.component(.year, from: Date())) Imara Ani LLC. All rights reserved."
    }
}

struct AboutView: View {
    let sting: AboutStingView
    var center: UpdateNoticeCenter?
    let openLink: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AboutStingRepresentable(view: sting)
                .frame(width: AboutWindowController.width,
                       height: (AboutWindowController.width * AboutStingView.aspect).rounded())
            VStack(spacing: 4) {
                Text(AboutInfo.version)
                if let engine = AboutInfo.engine { Text(engine) }
                if let center, center.driver != nil {
                    AboutUpdateView(center: center)
                        .padding(.top, 6)
                }
                Text(AboutInfo.copyright)
                    .padding(.top, 10)
                Text(attribution)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
                    .environment(\.openURL, OpenURLAction { url in
                        openLink(url)
                        return .handled
                    })
            }
            .font(.system(size: 11))
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .frame(width: AboutWindowController.width)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var attribution: AttributedString {
        var text = (try? AttributedString(markdown:
            "Darni is made possible by the [Chromium](https://www.chromium.org) open source project, "
            + "Chromium's [open source software](chrome://credits), as well as other [open source software](https://github.com/judioo/rearc).")) ?? AttributedString()
        for run in text.runs where run.link != nil {
            text[run.range].underlineStyle = .single
        }
        return text
    }
}

/// The latest version in the feed, under the engine line. Its height never
/// changes, so the window keeps its size as the state does; nothing animates.
struct AboutUpdateView: View {
    var center: UpdateNoticeCenter
    static let rowHeight: CGFloat = 22

    var body: some View {
        let line = center.aboutLine
        VStack(spacing: 2) {
            Text(line?.text ?? " ")
                .lineLimit(1)
                .accessibilityHidden(line == nil)
            HStack(spacing: 8) {
                if let detail = line?.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(detail)
                }
                if let action = line?.action {
                    Button(action.title) { perform(action) }
                        .controlSize(.small)
                        .accessibilityHint(action == .checkAgain ? "Checks for updates again" : "Quits Darni, installs the update and opens it again")
                }
            }
            .frame(height: Self.rowHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Updates")
    }

    private func perform(_ action: AboutUpdateLine.Action) {
        switch action {
        case .install, .retryInstall: center.installFromAbout()
        case .checkAgain: center.checkUpdateInformation(force: true)
        }
    }
}

private struct AboutStingRepresentable: NSViewRepresentable {
    let view: AboutStingView
    func makeNSView(context: Context) -> AboutStingView { view }
    func updateNSView(_ nsView: AboutStingView, context: Context) {}
    /// Exactly the frame AboutView gives it, whatever the GIF's own size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AboutStingView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: AboutWindowController.width,
                                                           height: AboutWindowController.width * AboutStingView.aspect))
    }
}

/// Resources/AboutSting.gif, played once by NSImageView and then swapped for
/// its last frame, since NSImageView loops whatever the GIF says.
///
/// The GIF is the sky and the mark only: its last 31 frames, which faded in the
/// old "ReArc" wordmark, were cut off when the app was renamed (the 82 frames
/// kept are byte for byte the original's). The wordmark is drawn here instead,
/// as text, where the GIF had it, and fades in as the GIF's did.
final class AboutStingView: NSImageView {
    static let aspect: CGFloat = 406.0 / 720.0
    /// The wordmark's centre, down from the top, as a share of the height (270 of the GIF's 406 px).
    static let wordmarkCenter: CGFloat = 270.0 / 406.0
    /// The GIF's wordmark took 16 frames of 40 ms to arrive.
    static let wordmarkFade: TimeInterval = 0.64

    /// "Dar" in the ink colour and "ni" in the arc colour, 13 pt bold, letter spacing -0.02 em
    /// (brand board, About window). The sting's sky is light in both appearances, so these are
    /// the colours for a light background. Inter is the brand typeface; it is not bundled, so
    /// this is the system font at the same weight unless the Mac has Inter.
    static let wordmark: NSAttributedString = {
        let size: CGFloat = 13
        let font = NSFont(name: "Inter-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let text = NSMutableAttributedString(string: Brand.wordmarkLead, attributes: [
            .font: font, .foregroundColor: color(Brand.inkOnLight), .kern: -0.02 * size,
        ])
        text.append(NSAttributedString(string: Brand.wordmarkTail, attributes: [
            .font: font, .foregroundColor: color(Brand.arcOnLight), .kern: -0.02 * size,
        ]))
        return text
    }()

    private let wordmarkLabel = NSTextField(labelWithAttributedString: AboutStingView.wordmark)

    private static let url = Bundle.main.url(forResource: "AboutSting", withExtension: "gif")
    private var restTask: DispatchWorkItem?

    private static let frames: (animated: NSImage, last: NSImage, duration: TimeInterval)? = {
        guard let url, let animated = NSImage(contentsOf: url),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let lastFrame = CGImageSourceCreateImageAtIndex(source, count - 1, nil) else { return nil }
        var duration: TimeInterval = 0
        for index in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.04
            duration += delay > 0 ? delay : 0.04
        }
        return (animated, NSImage(cgImage: lastFrame, size: .zero), duration)
    }()

    init() {
        super.init(frame: .zero)
        imageScaling = .scaleProportionallyUpOrDown
        // The GIF's 720×406 would otherwise outgrow the band above the
        // text and run under the credits (QA-483 B11).
        clipsToBounds = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        animates = true
        setAccessibilityLabel(Brand.name)
        wordmarkLabel.setAccessibilityElement(false)
        addSubview(wordmarkLabel)
        rest()
    }

    override func layout() {
        super.layout()
        // Centred where the GIF drew its wordmark; NSImageView's y runs up.
        let size = wordmarkLabel.fittingSize
        wordmarkLabel.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                                     y: (bounds.height * (1 - Self.wordmarkCenter) - size.height / 2).rounded(),
                                     width: size.width, height: size.height)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func play() {
        guard let frames = Self.frames else { return rest() }
        restTask?.cancel()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return rest() }
        // A fresh image restarts the animation from the first frame.
        image = nil
        image = frames.animated
        wordmarkLabel.alphaValue = 0
        let task = DispatchWorkItem { [weak self] in self?.rest(fadingIn: true) }
        restTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + frames.duration, execute: task)
    }

    /// The last frame with the wordmark. Without the GIF it is the app icon, which carries
    /// the mark alone, so the wordmark stays hidden rather than sit across it.
    private func rest(fadingIn: Bool = false) {
        guard let last = Self.frames?.last else {
            image = NSApp.applicationIconImage
            wordmarkLabel.isHidden = true
            return
        }
        image = last
        wordmarkLabel.isHidden = false
        guard fadingIn else {
            wordmarkLabel.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.wordmarkFade
            wordmarkLabel.animator().alphaValue = 1
        }
    }
}
