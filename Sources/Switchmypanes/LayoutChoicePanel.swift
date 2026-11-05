import AppKit
import SwitchmypanesCore

/// One layout drawn as a small picture of its zones, with its number and name.
final class LayoutCellView: NSView {
    let index: Int
    private let layout: SnapLayout
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var isSelected = false { didSet { needsDisplay = true } }

    init(frame: NSRect, index: Int, layout: SnapLayout) {
        self.index = index; self.layout = layout
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let card = bounds.insetBy(dx: 3, dy: 3)
        let accent = NSColor.controlAccentColor
        // card
        (isSelected ? NSColor.white.withAlphaComponent(0.15) : NSColor.white.withAlphaComponent(0.05)).setFill()
        let cardPath = NSBezierPath(roundedRect: card, xRadius: 16, yRadius: 16)
        cardPath.fill()
        if isSelected { accent.setStroke(); cardPath.lineWidth = 2.5; cardPath.stroke() }

        // the miniature screen
        let labelH: CGFloat = 30
        let screen = NSRect(x: card.minX + 16, y: card.minY + labelH + 6, width: card.width - 32, height: card.height - labelH - 24)
        NSColor.black.withAlphaComponent(0.34).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 8, yRadius: 8).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        let screenPath = NSBezierPath(roundedRect: screen.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); screenPath.lineWidth = 1; screenPath.stroke()
        for (zoneIndex, z) in layout.zones.enumerated() {
            // unit space has y down; AppKit drawing has y up
            let r = NSRect(x: screen.minX + z.minX * screen.width, y: screen.minY + (1 - z.maxY) * screen.height,
                           width: z.width * screen.width, height: z.height * screen.height).insetBy(dx: 3, dy: 3)
            (isSelected ? accent.withAlphaComponent(0.9) : NSColor.white.withAlphaComponent(0.36)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            // the order the areas are filled in
            let n = "\(zoneIndex + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(isSelected ? 0.95 : 0.7)]
            let s = n.size(withAttributes: attrs)
            if r.width > s.width + 6 && r.height > s.height + 6 { n.draw(at: NSPoint(x: r.midX - s.width / 2, y: r.midY - s.height / 2), withAttributes: attrs) }
        }

        // number + name
        let title = "\(index + 1)  " as NSString, name = layout.name as NSString
        let numAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11.5, weight: .bold), .foregroundColor: accent.withAlphaComponent(isSelected ? 1 : 0.85)]
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: NSColor.white.withAlphaComponent(isSelected ? 0.95 : 0.74)]
        let tw = title.size(withAttributes: numAttrs).width, nw = name.size(withAttributes: nameAttrs).width
        var x = card.midX - min(tw + nw, card.width - 12) / 2
        title.draw(at: NSPoint(x: x, y: card.minY + 8), withAttributes: numAttrs)
        x += tw
        name.draw(in: NSRect(x: x, y: card.minY + 8, width: max(0, card.maxX - 8 - x), height: 16), withAttributes: nameAttrs)
    }

    override func mouseDown(with event: NSEvent) { onClick?(index) }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Step 1 of Snap Layouts: a grid of layout pictures. Non-activating, like the switcher.
final class LayoutChoicePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static let columns = 3
    private let glass = OverlayTheme.makeGlass()
    private let hintBar = HintBarView()
    private var cells: [LayoutCellView] = []
    private var initialMouse = NSPoint.zero
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let base = OverlayTheme.makePanel()
        isFloatingPanel = base.isFloatingPanel; level = base.level; hasShadow = true; isOpaque = false
        backgroundColor = .clear; hidesOnDeactivate = false; animationBehavior = .none
        collectionBehavior = base.collectionBehavior
        contentView = glass
    }

    func present(layouts: [SnapLayout], selected: Int, on screen: NSScreen, show: Bool = true) {
        let wasVisible = isVisible
        cells.forEach { $0.removeFromSuperview() }; cells.removeAll()
        glass.subviews.forEach { $0.removeFromSuperview() }
        initialMouse = NSEvent.mouseLocation
        let cols = Self.columns, rows = Int((Double(layouts.count) / Double(cols)).rounded(.up))
        let cell = NSSize(width: 196, height: 146), sp: CGFloat = 10, pad: CGFloat = 24
        let header = OverlayTheme.captionHeight, footer = OverlayTheme.hintBarHeight
        let hints: [Hint] = .layoutChoice
        let gridW = CGFloat(cols) * cell.width + CGFloat(cols - 1) * sp
        let width = max(gridW + 2 * pad, HintBarView.preferredWidth(for: hints) + 2 * pad)
        let height = CGFloat(rows) * cell.height + CGFloat(rows - 1) * sp + 2 * pad + header + footer
        glass.setFrameSize(NSSize(width: width, height: height))

        let title = NSTextField(labelWithString: "Snap Layouts")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = NSColor.white.withAlphaComponent(0.78)
        title.alignment = .center
        title.frame = NSRect(x: pad, y: height - pad - 20, width: width - 2 * pad, height: 18)
        glass.addSubview(title)

        let left = (width - gridW) / 2
        for (i, l) in layouts.enumerated() {
            let r = i / cols, c = i % cols
            let v = LayoutCellView(frame: NSRect(x: left + CGFloat(c) * (cell.width + sp),
                                                 y: height - pad - header - cell.height - CGFloat(r) * (cell.height + sp),
                                                 width: cell.width, height: cell.height), index: i, layout: l)
            v.onClick = { [weak self] in self?.onClick?($0) }
            v.onHover = { [weak self] idx in
                let p = NSEvent.mouseLocation   // ignore "hover" caused by the panel appearing under a still mouse
                guard let self, abs(p.x - self.initialMouse.x) > 4 || abs(p.y - self.initialMouse.y) > 4 else { return }
                self.onHover?(idx)
            }
            v.isSelected = (i == selected)
            glass.addSubview(v); cells.append(v)
        }
        hintBar.hints = hints
        hintBar.frame = NSRect(x: 0, y: 6, width: width, height: footer - 6)
        glass.addSubview(hintBar)

        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height), display: true)
        guard show else { return }
        if wasVisible { orderFrontRegardless() } else { OverlayTheme.fadeIn(self) }
    }

    func setSelected(_ index: Int) { for c in cells { c.isSelected = (c.index == index) } }

    /// The panel's picture, for previews (`--render-overlay`).
    var contentSnapshotView: NSView { glass }

    func dismiss() {
        orderOut(nil)
        glass.subviews.forEach { $0.removeFromSuperview() }
        cells.removeAll()
    }
}
