import AppKit
import SwitchmypanesCore

/// One layout drawn as a small picture of its zones.
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
        let card = bounds.insetBy(dx: 2, dy: 2)
        if isSelected {
            NSColor.white.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: card, xRadius: 12, yRadius: 12).fill()
            NSColor.controlAccentColor.setStroke()
            let b = NSBezierPath(roundedRect: card.insetBy(dx: 1.5, dy: 1.5), xRadius: 11, yRadius: 11)
            b.lineWidth = 3; b.stroke()
        }
        // The miniature screen
        let labelH: CGFloat = 22
        let screen = NSRect(x: card.minX + 14, y: card.minY + labelH + 8, width: card.width - 28, height: card.height - labelH - 24)
        NSColor.black.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: screen, xRadius: 5, yRadius: 5).fill()
        for z in layout.zones {
            // unit space has y down; AppKit drawing has y up
            let r = NSRect(x: screen.minX + z.minX * screen.width, y: screen.minY + (1 - z.maxY) * screen.height,
                           width: z.width * screen.width, height: z.height * screen.height).insetBy(dx: 2, dy: 2)
            (isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.45)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        }
        let text = "\(index + 1)  \(layout.name)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: card.midX - min(size.width, card.width - 8) / 2, y: card.minY + 6), withAttributes: attrs)
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
    private let background = NSVisualEffectView()
    private var cells: [LayoutCellView] = []
    private var initialMouse = NSPoint.zero
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true; level = .popUpMenu; hasShadow = true; isOpaque = false
        backgroundColor = .clear; hidesOnDeactivate = false; animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        background.material = .hudWindow; background.blendingMode = .behindWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 20; background.layer?.masksToBounds = true
        contentView = background
    }

    func present(layouts: [SnapLayout], selected: Int, on screen: NSScreen) {
        cells.forEach { $0.removeFromSuperview() }; cells.removeAll()
        initialMouse = NSEvent.mouseLocation
        let cols = Self.columns, rows = Int((Double(layouts.count) / Double(cols)).rounded(.up))
        let cell = NSSize(width: 180, height: 130), sp: CGFloat = 8, pad: CGFloat = 20, header: CGFloat = 30
        let size = NSSize(width: CGFloat(cols) * cell.width + CGFloat(cols - 1) * sp + 2 * pad,
                          height: CGFloat(rows) * cell.height + CGFloat(rows - 1) * sp + 2 * pad + header)
        let title = NSTextField(labelWithString: "Choose a layout   ·   arrows + Return, or press 1–9   ·   Esc cancels")
        title.font = .systemFont(ofSize: 13, weight: .medium); title.textColor = .secondaryLabelColor; title.alignment = .center
        title.frame = NSRect(x: pad, y: size.height - pad - 18, width: size.width - 2 * pad, height: 18)
        background.addSubview(title)
        for (i, l) in layouts.enumerated() {
            let r = i / cols, c = i % cols
            let v = LayoutCellView(frame: NSRect(x: pad + CGFloat(c) * (cell.width + sp),
                                                 y: size.height - pad - header - cell.height - CGFloat(r) * (cell.height + sp),
                                                 width: cell.width, height: cell.height), index: i, layout: l)
            v.onClick = { [weak self] in self?.onClick?($0) }
            v.onHover = { [weak self] idx in
                let p = NSEvent.mouseLocation   // ignore "hover" caused by the panel appearing under a still mouse
                guard let self, abs(p.x - self.initialMouse.x) > 4 || abs(p.y - self.initialMouse.y) > 4 else { return }
                self.onHover?(idx)
            }
            v.isSelected = (i == selected)
            background.addSubview(v); cells.append(v)
        }
        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    func setSelected(_ index: Int) { for c in cells { c.isSelected = (c.index == index) } }

    func dismiss() {
        orderOut(nil)
        contentView?.subviews.forEach { $0.removeFromSuperview() }
        cells.removeAll()
    }
}
