import AppKit

/// How big the tiles are and how many fit on the screen.
struct SwitcherLayout {
    static let baseTile = NSSize(width: 220, height: 168)
    static let spacing: CGFloat = 12
    static let padding: CGFloat = 20

    let scale: CGFloat
    let columns: Int
    let rows: Int
    let capacity: Int
    var tile: NSSize { NSSize(width: Self.baseTile.width * scale, height: Self.baseTile.height * scale) }

    static func plan(count: Int, screen: NSScreen) -> SwitcherLayout {
        plan(count: count, bounds: screen.visibleFrame.size, widthFraction: 0.9, heightFraction: 0.85)
    }

    /// Layout that fits inside `bounds` (a screen, or just the empty half for Snap Assist).
    static func plan(count: Int, bounds: CGSize, widthFraction: CGFloat, heightFraction: CGFloat) -> SwitcherLayout {
        let maxW = bounds.width * widthFraction - 2 * padding
        let maxH = bounds.height * heightFraction - 2 * padding - 30   // 30 = caption line
        var best = SwitcherLayout(scale: 0.5, columns: 1, rows: 1, capacity: 1)
        for scale in [1.0, 0.85, 0.7, 0.55, 0.45] as [CGFloat] {
            let tw = baseTile.width * scale, th = baseTile.height * scale
            let cols = max(1, Int((maxW + spacing) / (tw + spacing)))
            let maxRows = max(1, Int((maxH + spacing) / (th + spacing)))
            let usedCols = min(count, cols)
            let rows = max(1, Int((Double(count) / Double(usedCols)).rounded(.up)))
            best = SwitcherLayout(scale: scale, columns: usedCols, rows: min(rows, maxRows), capacity: usedCols * maxRows)
            if rows <= maxRows { return SwitcherLayout(scale: scale, columns: usedCols, rows: rows, capacity: count) }
        }
        return best   // doesn't fit even at the smallest size: the caller shows only `capacity` windows
    }
}

/// One window in the overlay: thumbnail (or app icon), app icon badge, title.
final class WindowTileView: NSView {
    let index: Int
    let windowID: CGWindowID
    private let thumb = NSImageView()
    private let badge = NSImageView()
    private let label: NSTextField
    private let pill = NSTextField(labelWithString: "")     // "Desktop 2" / "Full screen"
    private let icon: NSImage?
    private var hasThumbnail = false
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    var isSelected = false { didSet { refreshAppearance() } }

    init(frame: NSRect, index: Int, info: WindowInfo, thumbnail: NSImage?) {
        self.index = index; self.windowID = info.id; self.icon = info.icon
        label = NSTextField(labelWithString: info.title)
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0

        thumb.imageAlignment = .alignCenter
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        badge.image = info.icon
        badge.imageScaling = .scaleProportionallyUpOrDown
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.toolTip = "\(info.appName) — \(info.title)"
        addSubview(thumb); addSubview(badge); addSubview(label)
        if let space = info.spaceLabel {
            pill.stringValue = " \(space) "
            pill.font = .systemFont(ofSize: 10, weight: .semibold)
            pill.textColor = .white
            pill.drawsBackground = true
            pill.backgroundColor = NSColor.black.withAlphaComponent(0.65)
            pill.wantsLayer = true
            pill.layer?.cornerRadius = 4
            pill.layer?.masksToBounds = true
            pill.sizeToFit()
            addSubview(pill)
            label.toolTip = "\(info.appName) — \(info.title) (\(space))"
        }
        if let thumbnail { setThumbnail(thumbnail) } else { thumb.image = icon; thumb.alphaValue = 0.85 }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 10
        let iconSize = max(16, bounds.height * 0.14)
        let footer = iconSize + 6
        thumb.frame = NSRect(x: pad, y: footer + pad, width: bounds.width - 2 * pad, height: bounds.height - footer - 2 * pad)
        badge.frame = NSRect(x: pad, y: pad - 2, width: iconSize, height: iconSize)
        if !pill.stringValue.isEmpty {
            pill.frame.origin = NSPoint(x: bounds.maxX - pad - pill.frame.width - 4, y: bounds.maxY - pad - pill.frame.height - 4)
        }
        label.frame = NSRect(x: pad + iconSize + 6, y: pad - 2 + (iconSize - 16) / 2, width: bounds.width - 2 * pad - iconSize - 6, height: 16)
    }

    func setThumbnail(_ image: NSImage) {
        hasThumbnail = true
        thumb.image = image
        thumb.alphaValue = 1
    }

    private func refreshAppearance() {
        layer?.backgroundColor = isSelected ? NSColor.white.withAlphaComponent(0.20).cgColor : NSColor.clear.cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = isSelected ? 3 : 0
    }

    override func mouseDown(with event: NSEvent) { onClick?(index) }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The overlay window. A non-activating panel: it can be clicked, but never takes keyboard focus
/// from the app you were using, so nothing changes until you commit.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let background = NSVisualEffectView()
    private var tiles: [WindowTileView] = []
    private var captionLabel: NSTextField?
    private var initialMouse = NSPoint.zero
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .none
        // Visible on every Space and above full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 20
        background.layer?.masksToBounds = true
        contentView = background
    }

    func present(windows: [WindowInfo], layout: SwitcherLayout, selected: Int, on screen: NSScreen,
                 caption: String? = nil, center: NSPoint? = nil, thumbnail: (CGWindowID) -> NSImage?) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        captionLabel?.removeFromSuperview(); captionLabel = nil
        initialMouse = NSEvent.mouseLocation

        let tile = layout.tile, sp = SwitcherLayout.spacing, pad = SwitcherLayout.padding
        let header: CGFloat = caption == nil ? 0 : 30
        let size = NSSize(width: max(CGFloat(layout.columns) * tile.width + CGFloat(layout.columns - 1) * sp + 2 * pad, caption == nil ? 0 : 560),
                          height: CGFloat(layout.rows) * tile.height + CGFloat(layout.rows - 1) * sp + 2 * pad + header)
        let gridWidth = CGFloat(layout.columns) * tile.width + CGFloat(layout.columns - 1) * sp
        let leftInset = (size.width - gridWidth) / 2
        for (i, w) in windows.enumerated() {
            let row = i / layout.columns, col = i % layout.columns
            // Row 0 is at the top, but AppKit's origin is bottom-left.
            let origin = NSPoint(x: leftInset + CGFloat(col) * (tile.width + sp),
                                 y: size.height - pad - header - tile.height - CGFloat(row) * (tile.height + sp))
            let v = WindowTileView(frame: NSRect(origin: origin, size: tile), index: i, info: w, thumbnail: thumbnail(w.id))
            v.onClick = { [weak self] in self?.onClick?($0) }
            v.onHover = { [weak self] idx in self?.hoverIfMouseMoved(idx) }
            v.isSelected = (i == selected)
            background.addSubview(v)
            tiles.append(v)
        }
        if let caption {
            let l = NSTextField(labelWithString: caption)
            l.font = .systemFont(ofSize: 13, weight: .medium)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            l.frame = NSRect(x: pad, y: size.height - pad - 18, width: size.width - 2 * pad, height: 18)
            background.addSubview(l)
            captionLabel = l
        }
        let vf = screen.visibleFrame
        let c = center ?? NSPoint(x: vf.midX, y: vf.midY)
        setFrame(NSRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height), display: true)
        orderFrontRegardless()
    }

    /// Ignore "hover" caused by the overlay appearing under a mouse that is not moving.
    private func hoverIfMouseMoved(_ index: Int) {
        let p = NSEvent.mouseLocation
        guard abs(p.x - initialMouse.x) > 4 || abs(p.y - initialMouse.y) > 4 else { return }
        onHover?(index)
    }

    func setSelected(_ index: Int) { for t in tiles { t.isSelected = (t.index == index) } }

    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        tiles.first { $0.windowID == id }?.setThumbnail(image)
    }

    func dismiss() {
        orderOut(nil)
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
    }
}
