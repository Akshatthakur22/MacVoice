import AppKit

/// The MacVoice microphone for the menu bar, drawn as vectors from the brand
/// mark (Brand/Assets/macvoice-symbol-mono-black.svg) so it is crisp at every
/// scale and always has a transparent background.
enum MenuBarIcon {
    enum State: Equatable {
        /// Ready: adapts to light and dark menu bars like system icons.
        case idle
        /// Starting or finishing: dimmed.
        case busy
        /// Recording: red, with `dimmed` used for a gentle pulse.
        case listening(dimmed: Bool)
        /// Needs the user's attention (failure, missing permission): orange.
        case attention
    }

    static let size = NSSize(width: 18, height: 18)

    static func image(for state: State) -> NSImage {
        let color: NSColor
        let alpha: CGFloat
        let isTemplate: Bool
        switch state {
        case .idle: (color, alpha, isTemplate) = (.black, 1, true)
        case .busy: (color, alpha, isTemplate) = (.black, 0.45, true)
        case .listening(let dimmed): (color, alpha, isTemplate) = (.systemRed, dimmed ? 0.55 : 1, false)
        case .attention: (color, alpha, isTemplate) = (.systemOrange, 1, false)
        }
        let image = NSImage(size: size, flipped: false) { rect in
            drawMicrophone(in: rect, color: color.withAlphaComponent(alpha))
            return true
        }
        image.isTemplate = isTemplate
        image.accessibilityDescription = "MacVoice"
        return image
    }

    /// Geometry in the SVG's 1024-unit space, with y pointing up.
    private static func drawMicrophone(in rect: NSRect, color: NSColor) {
        // Ink bounds including stroke width: x 228…796, y 110…834.
        let inkCenter = NSPoint(x: 512, y: 472)
        let scale = rect.height * 0.92 / 724
        var transform = AffineTransform(translationByX: rect.midX, byY: rect.midY)
        transform.scale(scale)
        transform.translate(x: -inkCenter.x, y: -inkCenter.y)

        let body = NSBezierPath(roundedRect: NSRect(x: 382, y: 394, width: 260, height: 440), xRadius: 130, yRadius: 130)
        body.transform(using: transform)

        let strokes = NSBezierPath()
        strokes.move(to: NSPoint(x: 260, y: 544))
        strokes.line(to: NSPoint(x: 260, y: 499))
        strokes.appendArc(withCenter: NSPoint(x: 512, y: 499), radius: 252, startAngle: 180, endAngle: 360, clockwise: false)
        strokes.line(to: NSPoint(x: 764, y: 544))
        strokes.move(to: NSPoint(x: 512, y: 247))
        strokes.line(to: NSPoint(x: 512, y: 142))
        strokes.move(to: NSPoint(x: 382, y: 142))
        strokes.line(to: NSPoint(x: 642, y: 142))
        strokes.transform(using: transform)
        strokes.lineWidth = 64 * scale
        strokes.lineCapStyle = .round
        strokes.lineJoinStyle = .round

        color.set()
        body.fill()
        strokes.stroke()
    }
}
