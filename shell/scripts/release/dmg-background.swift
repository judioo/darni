// Draws the DMG window background for scripts/make-dmg.sh: brand canvas, the Darni lockup
// (the mark and the two-tone wordmark) at the top, a cobalt arrow from the app icon to the
// Applications link, and the link's label (the link itself is
// named " ", as Chromium's DMG layout in chrome/installer/mac/generate_dsstore.py expects).
// Geometry matches the layout make-dmg.sh passes that script: a 633 x 380 window (its
// bounds include the 32 pt title bar, so 348 pt of content), icons centered at (163, 136)
// and (470, 136), 128 pt icons. Everything sits in the top 276 pt, so the labels and the
// hint stay clear of Finder's path bar and status bar (about 28 pt each) when they are on.
// The lockup is centred in the 72 pt above the icons. Finder labels the app icon "Darni"
// itself, from the file name Darni.app.
// make-dmg.sh combines the 1x and @2x PNGs into one multi-resolution TIFF
// (tiffutil -cathidpicheck), the form Finder uses on Retina displays.
// Usage: swift dmg-background.swift OUT_DIR   (writes background.png and background@2x.png)
import AppKit

let width: CGFloat = 633, height: CGFloat = 348
let appCenter = CGPoint(x: 163, y: 136), linkCenter = CGPoint(x: 470, y: 136)
/// Top of the hint line, below the icons' labels.
let hintTop: CGFloat = 250
let canvas = NSColor(srgbRed: 0xF8 / 255, green: 0xFA / 255, blue: 0xFC / 255, alpha: 1)
let cobalt = NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1)
let muted = NSColor(srgbRed: 0x64 / 255, green: 0x74 / 255, blue: 0x8B / 255, alpha: 1)
let primary = NSColor(srgbRed: 0x0F / 255, green: 0x17 / 255, blue: 0x2A / 255, alpha: 1)
func hex(_ value: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
}
// The lockup on a light background: "Dar" in ink, "ni" in the arc colour, beside the mark.
// The small lockup of the brand board: a 28 pt word, a 46 x 30 mark, 12 pt between them.
let ink = hex(0x1D2160), arcBlue = hex(0x2740FF), navy = hex(0x190C99), overlap = hex(0x1627C8), sun = hex(0xFF5B3A)
let wordSize: CGFloat = 28, markSize = CGSize(width: 46, height: 30), lockupGap: CGFloat = 12
/// The lockup's vertical centre, from the top of the content.
let lockupCenterY: CGFloat = 38

/// The brand typeface when this Mac has it, else the system font at the same weight (700).
func wordFont(_ size: CGFloat) -> NSFont {
    NSFont(name: "Inter-Bold", size: size) ?? NSFont(name: "Inter Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
}

/// "Dar" + "ni", letter spacing -0.02 em.
func wordmark(_ size: CGFloat) -> NSAttributedString {
    let font = wordFont(size)
    let text = NSMutableAttributedString(string: "Dar", attributes: [.font: font, .foregroundColor: ink, .kern: -0.02 * size])
    text.append(NSAttributedString(string: "ni", attributes: [.font: font, .foregroundColor: arcBlue, .kern: -0.02 * size]))
    return text
}

/// The mark (the sun over two arcs), unchanged by the rename: brand/logo.svg's geometry in its
/// viewBox 140 250 744 490, drawn into `rect` (AppKit coordinates, y up).
func drawMark(in rect: CGRect, context: CGContext) {
    let horizon = CGPoint(x: 512, y: 900)
    func arc(from start: CGPoint, to end: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: horizon, radius: 380, startAngle: atan2(start.y - horizon.y, start.x - horizon.x),
                    endAngle: atan2(end.y - horizon.y, end.x - horizon.x), clockwise: false)
        return path.copy(strokingWithWidth: 130, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
    let navyArc = arc(from: CGPoint(x: 212.6, y: 666), to: CGPoint(x: 485.5, y: 520.9))
    let blueArc = arc(from: CGPoint(x: 420.1, y: 531.3), to: CGPoint(x: 811.4, y: 666))
    let sunDisc = CGPath(ellipseIn: CGRect(x: 512 - 225, y: 480 - 225, width: 450, height: 450), transform: nil)
    let horizonDisc = CGPath(ellipseIn: CGRect(x: 512 - 380, y: 900 - 380, width: 760, height: 760), transform: nil)
    let scale = min(rect.width / 744, rect.height / 490)
    context.saveGState()
    // The SVG's y runs down: flip it about the rect's top edge.
    context.translateBy(x: rect.midX - 744 * scale / 2, y: rect.midY + 490 * scale / 2)
    context.scaleBy(x: scale, y: -scale)
    context.translateBy(x: -140, y: -250)
    for (path, color) in [(sunDisc.subtracting(horizonDisc), sun), (navyArc, navy), (blueArc, arcBlue),
                          (blueArc.intersection(navyArc), overlap)] {
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
    context.restoreGState()
}

func render(scale: CGFloat, to url: URL) throws {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    canvas.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // The lockup, centred above the icons.
    let word = wordmark(wordSize)
    let wordWidth = word.size().width
    let lockupLeft = (width - (markSize.width + lockupGap + wordWidth)) / 2
    let lockupY = height - lockupCenterY
    if let context = NSGraphicsContext.current?.cgContext {
        drawMark(in: CGRect(x: lockupLeft, y: lockupY - markSize.height / 2, width: markSize.width, height: markSize.height),
                 context: context)
    }
    // The word's cap height is centred on the mark (line height 1, as on the board).
    let font = wordFont(wordSize)
    word.draw(at: CGPoint(x: lockupLeft + markSize.width + lockupGap,
                          y: lockupY - font.capHeight / 2 + font.descender))

    // Finder positions are top-left based; AppKit draws bottom-left.
    let y = height - appCenter.y
    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: appCenter.x + 84, y: y))
    arrow.line(to: CGPoint(x: linkCenter.x - 96, y: y))
    arrow.lineWidth = 6
    arrow.lineCapStyle = .round
    cobalt.setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: linkCenter.x - 84, y: y))
    head.line(to: CGPoint(x: linkCenter.x - 104, y: y + 14))
    head.line(to: CGPoint(x: linkCenter.x - 104, y: y - 14))
    head.close()
    cobalt.setFill()
    head.fill()

    func draw(_ text: String, size: CGFloat, color: NSColor, weight: NSFont.Weight, centerX: CGFloat, baseline: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        string.draw(at: CGPoint(x: centerX - string.size().width / 2, y: baseline))
    }
    // Under the link icon, where Finder would put a label (128 pt icon, 12 pt text).
    draw("Applications", size: 12, color: primary, weight: .regular, centerX: linkCenter.x, baseline: y - 64 - 18)
    draw("Drag Darni to Applications to install", size: 13, color: muted, weight: .medium,
         centerX: width / 2, baseline: height - hintTop - 16)
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try render(scale: 1, to: out.appendingPathComponent("background.png"))
try render(scale: 2, to: out.appendingPathComponent("background@2x.png"))
