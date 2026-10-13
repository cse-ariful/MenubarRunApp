import AppKit

/// Menu bar icon: a hammer with a small status badge in the corner (▶ ready, ⌛ busy, ! failed).
/// Rendered as a template image so macOS tints it for light/dark menu bars.
enum MenuBarIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for phase: RunPhase) -> NSImage {
        // (`phase` is BuildRunner.aggregatePhase: busy while any project runs.)
        let badge: String
        switch phase {
        case .idle, .succeeded, .cancelled, .attached: badge = "play.fill"
        case .failed: badge = "exclamationmark"
        default: badge = "hourglass"
        }
        if let cached = cache[badge] { return cached }
        let image = render(badge: badge)
        cache[badge] = image
        return image
    }

    private static func render(badge: String) -> NSImage {
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
