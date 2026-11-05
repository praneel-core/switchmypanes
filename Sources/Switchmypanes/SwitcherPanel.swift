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
        let maxW = screen.visibleFrame.width * 0.9 - 2 * padding
        let maxH = screen.visibleFrame.height * 0.85 - 2 * padding
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
                 thumbnail: (CGWindowID) -> NSImage?) {
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        initialMouse = NSEvent.mouseLocation

        let tile = layout.tile, sp = SwitcherLayout.spacing, pad = SwitcherLayout.padding
        let size = NSSize(width: CGFloat(layout.columns) * tile.width + CGFloat(layout.columns - 1) * sp + 2 * pad,
                          height: CGFloat(layout.rows) * tile.height + CGFloat(layout.rows - 1) * sp + 2 * pad)
        for (i, w) in windows.enumerated() {
            let row = i / layout.columns, col = i % layout.columns
            // Row 0 is at the top, but AppKit's origin is bottom-left.
            let origin = NSPoint(x: pad + CGFloat(col) * (tile.width + sp),
                                 y: size.height - pad - tile.height - CGFloat(row) * (tile.height + sp))
            let v = WindowTileView(frame: NSRect(origin: origin, size: tile), index: i, info: w, thumbnail: thumbnail(w.id))
            v.onClick = { [weak self] in self?.onClick?($0) }
            v.onHover = { [weak self] idx in self?.hoverIfMouseMoved(idx) }
            v.isSelected = (i == selected)
            background.addSubview(v)
            tiles.append(v)
        }
        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
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
