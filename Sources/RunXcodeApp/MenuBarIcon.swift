import AppKit

/// Menu bar icon: a hammer with a small status badge in the corner
/// (▶ ready, spinning ring while building/running, ! failed).
/// Rendered as a template image so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    /// Number of frames in the spinner animation (one full turn).
    static let spinnerFrameCount = 12

    /// Loader frame: the hammer with a rotating ring in the badge.
    static func spinnerImage(frame: Int) -> NSImage {
        let index = ((frame % spinnerFrameCount) + spinnerFrameCount) % spinnerFrameCount
        let key = "spinner-\(index)"
        if let cached = cache[key] { return cached }
        let image = render { badgeRect in
            // 270° arc, rotated a step per frame.
            let center = NSPoint(x: badgeRect.midX, y: badgeRect.midY)
            let start = 90 - CGFloat(index) * (360 / CGFloat(spinnerFrameCount))
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: badgeRect.width / 2 - 1.2,
                          startAngle: start, endAngle: start - 270, clockwise: true)
            arc.lineWidth = 1.8
            arc.lineCapStyle = .round
            NSColor.black.setStroke()
            arc.stroke()
        }
        cache[key] = image
        return image
    }

    static func image(for phase: RunPhase) -> NSImage {
        // (`phase` is BuildRunner.aggregatePhase: busy while any project runs.)
        let badge: String
        switch phase {
        case .idle, .succeeded, .cancelled, .attached, .streaming: badge = "play.fill"
        case .failed: badge = "exclamationmark"
        default: badge = "hourglass"
        }
        if let cached = cache[badge] { return cached }
        let image = render { badgeRect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()

            // Punch the glyph out of the filled circle.
            if let glyph = symbol(badge, pointSize: 7, weight: .black) {
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                let inset = badge == "play.fill"
                    ? badgeRect.insetBy(dx: 2.6, dy: 2.6).offsetBy(dx: 0.6, dy: 0)
                    : badgeRect.insetBy(dx: 2.6, dy: 2.4)
                draw(glyph, fitting: inset)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
        }
        cache[badge] = image
        return image
    }

    /// Hammer + knocked-out badge circle; `drawBadge` draws inside the badge rect.
    private static func render(drawBadge: @escaping (NSRect) -> Void) -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            // Hammer, slightly up-left to leave room for the badge.
            if let hammer = symbol("hammer.fill", pointSize: 13, weight: .semibold) {
                draw(hammer, fitting: NSRect(x: 0, y: 3, width: 16, height: 15))
            }

            // Knock out a circle behind the badge so it stays legible.
            let badgeRect = NSRect(x: 11, y: 0, width: 11, height: 11)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            drawBadge(badgeRect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "RunXcodeApp"
        return image
    }

    private static func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: weight))
    }

    /// Draws `image` aspect-fit and centered in `rect`.
    private static func draw(_ image: NSImage, fitting rect: NSRect) {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return }
        let scale = min(rect.width / s.width, rect.height / s.height)
        let w = s.width * scale, h = s.height * scale
        let target = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
        image.draw(in: target, from: .zero, operation: NSGraphicsContext.current?.compositingOperation ?? .sourceOver, fraction: 1)
    }
}
