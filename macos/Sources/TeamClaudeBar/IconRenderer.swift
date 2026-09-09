import AppKit
import TeamClaudeCore

/// Draws the status-item glyph: two mini bars (5h over 7d) on a translucent
/// track. Monochrome renders as a template image so AppKit tints it for the
/// menu bar's appearance; the colour mode paints the severity.
enum IconRenderer {
    struct Rendered {
        var image: NSImage?
        var title: NSAttributedString
    }

    static func color(for state: IconState) -> NSColor {
        switch state {
        case .normal, .rotating: return .systemGreen
        case .warning: return .systemOrange
        case .critical: return .systemRed
        case .proxyDown, .stale, .noAccounts: return .secondaryLabelColor
        }
    }

    static func render(_ model: IconModel, style: Preferences.IconStyle, monochrome: Bool) -> Rendered {
        let showBars = style != .percent
        let quiet = style == .quiet && (model.state == .normal)
        var text: String? = nil
        switch style {
        case .bars: text = nil
        case .percent, .barsPercent: text = model.label
        case .barsBoth:
            if let f = model.fiveHour, let w = model.weekly { text = "\(Derived.percentInt(f))% · \(Derived.percentInt(w))%" }
            else { text = model.label }
        case .quiet: text = quiet ? nil : model.label
        }
        if case .rotating = model.state { text = model.label }
        if model.state == .proxyDown { text = style == .bars ? nil : "—" }

        let image = showBars ? barsImage(model, monochrome: monochrome) : nil
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: monochrome ? NSColor.labelColor : color(for: model.state),
            .baselineOffset: 0.5,
        ]
        let title = NSAttributedString(string: text.map { " " + $0 } ?? "", attributes: attrs)
        return Rendered(image: image, title: title)
    }

    static func barsImage(_ model: IconModel, monochrome: Bool) -> NSImage {
        let hasTag = model.tag != nil
        let size = NSSize(width: 20, height: hasTag ? 18 : 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let fg: NSColor = monochrome ? .black : color(for: model.state)
            let dim = model.state == .proxyDown || model.state == .stale
            let trackAlpha: CGFloat = dim ? 0.22 : 0.28
            let fillAlpha: CGFloat = dim ? 0.4 : 1
            let barW: CGFloat = 16, barH: CGFloat = hasTag ? 2.5 : 3, x: CGFloat = 2
            let top: CGFloat = hasTag ? 12.5 : 9.5, bottom: CGFloat = hasTag ? 8.5 : 3.5
            func bar(y: CGFloat, fill: Double?) {
                let track = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barW, height: barH), xRadius: barH / 2, yRadius: barH / 2)
                fg.withAlphaComponent(trackAlpha).setFill()
                track.fill()
                guard let fill else { return }
                let w = max(fill > 0 ? 1 : 0, barW * CGFloat(min(1, max(0, fill))))
                let f = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: barH), xRadius: barH / 2, yRadius: barH / 2)
                fg.withAlphaComponent(fillAlpha).setFill()
                f.fill()
            }
            bar(y: top, fill: model.fiveHour)
            bar(y: bottom, fill: model.weekly)
            if model.state == .critical {
                fg.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: rect.height - 4.5, width: 4, height: 4)).fill()
            }
            if model.state == .proxyDown {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: 3, y: 2)); line.line(to: NSPoint(x: 17, y: rect.height - 2))
                line.lineWidth = 1.5; line.lineCapStyle = .round
                fg.withAlphaComponent(0.9).setStroke()
                line.stroke()
            }
            if let tag = model.tag {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 6, weight: .bold), .foregroundColor: fg.withAlphaComponent(fillAlpha)]
                let s = NSAttributedString(string: tag.uppercased(), attributes: attrs)
                let w = s.size().width
                s.draw(at: NSPoint(x: (rect.width - w) / 2, y: 0.5))
            }
            return true
        }
        image.isTemplate = monochrome
        image.accessibilityDescription = model.tooltip
        return image
    }
}
