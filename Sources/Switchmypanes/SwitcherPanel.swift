import AppKit
import SwitchmypanesCore

/// How big the tiles are and how many fit on the screen. In list mode each window is a compact row (no picture).
struct SwitcherLayout {
    static let baseTile = NSSize(width: 236, height: 194)
    static let rowSize = NSSize(width: 300, height: 50)
    static let spacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let padding: CGFloat = 24

    let scale: CGFloat
    let columns: Int
    let rows: Int
    let capacity: Int
    var compact = false
    var tile: NSSize { compact ? Self.rowSize : NSSize(width: Self.baseTile.width * scale, height: Self.baseTile.height * scale) }
    var spacing: CGFloat { compact ? Self.rowSpacing : Self.spacing }

    static func plan(count: Int, screen: NSScreen, sizeScale: CGFloat = 1, compact: Bool = false) -> SwitcherLayout {
        plan(count: count, bounds: screen.visibleFrame.size, widthFraction: 0.9, heightFraction: 0.85, sizeScale: sizeScale, compact: compact)
    }

    /// Layout that fits inside `bounds` (a screen, or just the empty half for Snap Assist). `sizeScale` makes tiles bigger or
    /// smaller (Preferences); it is the size tried FIRST, and tiles shrink from there until everything fits.
    static func plan(count: Int, bounds: CGSize, widthFraction: CGFloat, heightFraction: CGFloat,
                     sizeScale: CGFloat = 1, compact: Bool = false) -> SwitcherLayout {
        let maxW = bounds.width * widthFraction - 2 * padding
        // room for the caption line as well
        let maxH = bounds.height * heightFraction - 2 * padding - OverlayTheme.captionHeight
        if compact { return planList(count: count, maxW: maxW, maxH: maxH) }
        var best = SwitcherLayout(scale: 0.5, columns: 1, rows: 1, capacity: 1)
        for factor in [1.0, 0.85, 0.7, 0.55, 0.45] as [CGFloat] {
            let scale = max(0.4, sizeScale * factor)
            let tw = baseTile.width * scale, th = baseTile.height * scale
            let cols = max(1, Int((maxW + spacing) / (tw + spacing)))
            let maxRows = max(1, Int((maxH + spacing) / (th + spacing)))
            let usedCols = max(1, min(count, cols))
            let rows = max(1, Int((Double(count) / Double(usedCols)).rounded(.up)))
            best = SwitcherLayout(scale: scale, columns: usedCols, rows: min(rows, maxRows), capacity: usedCols * maxRows)
            if rows <= maxRows { return SwitcherLayout(scale: scale, columns: usedCols, rows: rows, capacity: count) }
        }
        return best   // doesn't fit even at the smallest size: the caller shows only `capacity` windows
    }

    /// The compact list: as few columns as will do, so a long list reads top to bottom.
    private static func planList(count: Int, maxW: CGFloat, maxH: CGFloat) -> SwitcherLayout {
        let maxCols = max(1, min(6, Int((maxW + rowSpacing) / (rowSize.width + rowSpacing))))
        let maxRows = max(1, Int((maxH + rowSpacing) / (rowSize.height + rowSpacing)))
        for cols in 1...maxCols {
            let rows = max(1, Int((Double(max(count, 1)) / Double(cols)).rounded(.up)))
            if rows <= maxRows { return SwitcherLayout(scale: 1, columns: max(1, min(cols, count)), rows: rows, capacity: count, compact: true) }
        }
        return SwitcherLayout(scale: 1, columns: maxCols, rows: maxRows, capacity: maxCols * maxRows, compact: true)
    }
}

/// A button that works on the first click even though the overlay never becomes the active window.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One window in the overlay: a framed thumbnail (or the app icon), a tag for other desktops / minimized windows,
/// and the app icon with the window title and app name underneath.
final class WindowTileView: NSView {
    let index: Int
    let windowID: CGWindowID
    private let thumbFrame = NSView()                 // rounded, bordered picture frame
    private let thumb = NSImageView()
    private let badge = NSImageView()
    private let titleLabel: NSTextField
    private let appLabel: NSTextField
    private let closeButton = CloseButton()
    private let tagView: TagView?
    private let icon: NSImage?
    private let hasDistinctTitle: Bool
    private let compact: Bool
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onContextMenu: ((Int, NSEvent) -> Void)?

    var isSelected = false { didSet { refreshAppearance() } }

    init(frame: NSRect, index: Int, info: WindowInfo, thumbnail: NSImage?, compact: Bool = false) {
        self.compact = compact
        self.index = index; self.windowID = info.id; self.icon = info.icon
        hasDistinctTitle = info.title != info.appName
        titleLabel = NSTextField(labelWithString: hasDistinctTitle ? info.title : info.appName)
        appLabel = NSTextField(labelWithString: info.appName)
        tagView = info.spaceLabel.map { TagView($0) }
        super.init(frame: frame)
        wantsLayer = true

        thumbFrame.wantsLayer = true
        thumbFrame.layer?.cornerRadius = 12
        thumbFrame.layer?.masksToBounds = true
        thumbFrame.layer?.backgroundColor = NSColor.black.withAlphaComponent(OverlayTheme.thumbnailBackdropAlpha).cgColor
        thumbFrame.layer?.borderWidth = 1
        thumb.imageAlignment = .alignCenter
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumbFrame.addSubview(thumb)

        badge.image = info.icon
        badge.imageScaling = .scaleProportionallyUpOrDown
        badge.wantsLayer = true
        badge.shadow = {
            let s = NSShadow(); s.shadowBlurRadius = 4; s.shadowOffset = NSSize(width: 0, height: -1)
            s.shadowColor = NSColor.black.withAlphaComponent(0.35); return s
        }()

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        appLabel.lineBreakMode = .byTruncatingTail
        appLabel.font = .systemFont(ofSize: 10.5, weight: .regular)
        appLabel.isHidden = !hasDistinctTitle
        let tip = "\(info.appName) — \(info.title)" + (info.spaceLabel.map { " (\($0))" } ?? "")
        titleLabel.toolTip = tip

        for l in [titleLabel, appLabel] { l.wantsLayer = true; l.shadow = OverlayTheme.softTextShadow() }     // readable on clear glass
        if !compact { addSubview(thumbFrame) }
        addSubview(badge); addSubview(titleLabel); addSubview(appLabel)
        if let tagView { addSubview(tagView) }

        // Close button: appears while the mouse is over the tile (for a window on another desktop it first switches there).
        closeButton.toolTip = info.isOnAnotherSpace ? "Close this window (switches to its desktop first)" : "Close this window"
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.alphaValue = 0                       // fades in while the mouse is over the tile
        addSubview(closeButton)

        if compact {
            wantsLayer = true
            layer?.cornerRadius = 16
            layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor        // a row, so the list reads as items
        } else if let thumbnail { setThumbnail(thumbnail) } else { showIconPlaceholder() }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        refreshAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if compact { layoutRow(); return }
        let pad: CGFloat = 12
        let footerH = max(34, bounds.height * 0.2)
        let thumbRect = NSRect(x: pad, y: footerH + 6, width: bounds.width - 2 * pad, height: bounds.height - footerH - 6 - pad + 2)
        thumbFrame.frame = thumbRect
        thumb.frame = thumbFrame.bounds.insetBy(dx: 1, dy: 1)
        if thumb.image === icon { thumb.frame = thumbFrame.bounds.insetBy(dx: thumbRect.width * 0.28, dy: thumbRect.height * 0.12) }

        let iconSize = min(30, footerH - 6)
        badge.frame = NSRect(x: pad, y: (footerH - iconSize) / 2 + 1, width: iconSize, height: iconSize)
        let textX = pad + iconSize + 8, textW = bounds.width - textX - pad
        if hasDistinctTitle {
            titleLabel.frame = NSRect(x: textX, y: footerH / 2 + 0, width: textW, height: 16)
            appLabel.frame = NSRect(x: textX, y: footerH / 2 - 15, width: textW, height: 14)
        } else {
            titleLabel.frame = NSRect(x: textX, y: (footerH - 16) / 2 + 1, width: textW, height: 16)
        }
        closeButton.frame = NSRect(x: thumbRect.minX + 8, y: thumbRect.maxY - 32, width: 24, height: 24)
        if let tagView { tagView.frame.origin = NSPoint(x: thumbRect.maxX - tagView.frame.width - 8, y: thumbRect.maxY - tagView.frame.height - 8) }
    }

    /// The compact form: icon, title and app name, the tag and the close button on one row.
    private func layoutRow() {
        let pad: CGFloat = 14, iconSize: CGFloat = 30
        badge.frame = NSRect(x: pad, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
        let closeW: CGFloat = 24
        closeButton.frame = NSRect(x: bounds.maxX - pad - closeW + 4, y: (bounds.height - closeW) / 2, width: closeW, height: closeW)
        let tagW = tagView?.frame.width ?? 0
        let rightEdge = bounds.maxX - pad - closeW - 2 - (tagView == nil ? 0 : tagW + 8)
        if let tagView { tagView.frame.origin = NSPoint(x: bounds.maxX - pad - closeW - tagW - 2, y: (bounds.height - tagView.frame.height) / 2) }
        let textX = pad + iconSize + 10, textW = max(20, rightEdge - textX)
        if hasDistinctTitle {
            titleLabel.frame = NSRect(x: textX, y: bounds.height / 2, width: textW, height: 16)
            appLabel.frame = NSRect(x: textX, y: bounds.height / 2 - 15, width: textW, height: 14)
        } else {
            titleLabel.frame = NSRect(x: textX, y: (bounds.height - 16) / 2, width: textW, height: 16)
        }
    }

    func setThumbnail(_ image: NSImage) {
        thumb.image = image
        thumb.alphaValue = 1
        needsLayout = true
    }

    /// No picture yet (a window that was never visible, or no Screen Recording permission): a big, soft app icon.
    private func showIconPlaceholder() {
        thumb.image = icon
        thumb.alphaValue = 0.9
        needsLayout = true
    }

    private func refreshAppearance() {
        thumbFrame.layer?.borderColor = (isSelected ? NSColor.white.withAlphaComponent(0.38) : NSColor.white.withAlphaComponent(0.14)).cgColor
        titleLabel.textColor = isSelected ? .white : NSColor.white.withAlphaComponent(0.86)
        appLabel.textColor = NSColor.white.withAlphaComponent(isSelected ? 0.66 : 0.48)
    }

    override func mouseDown(with event: NSEvent) { onClick?(index) }
    override func rightMouseDown(with event: NSEvent) { onContextMenu?(index, event) }
    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseEntered(with event: NSEvent) { onHover?(index); setCloseVisible(true) }
    override func mouseExited(with event: NSEvent) { setCloseVisible(false) }

    /// Fades the close button in / out (instant when Reduce motion is on).
    private func setCloseVisible(_ visible: Bool) {
        guard OverlayTheme.motionEnabled else { closeButton.alphaValue = visible ? 1 : 0; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            closeButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Previews / tests: show the close button without a mouse (`pointedAt` draws its red state).
    func debugShowCloseButton(pointedAt: Bool) { closeButton.alphaValue = 1; closeButton.forceHover = pointedAt }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func closeTapped() { onClose?(index) }
}

/// The overlay window. A non-activating panel: it can be clicked, but never takes keyboard focus
/// from the app you were using, so nothing changes until you commit.
final class SwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var glass = OverlayTheme.makeGlass()
    private let ring = NSView()                          // the highlight that slides to the selected tile
    private var tiles: [WindowTileView] = []
    private var captionLabel: NSTextField?
    private var searchPill: SearchPillView?
    private var messageLabel: NSTextField?
    private var initialMouse = NSPoint.zero
    private var ringPlaced = false
    var onClick: ((Int) -> Void)?
    var onHover: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onContextMenu: ((Int, NSEvent) -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        let base = OverlayTheme.makePanel()
        isFloatingPanel = base.isFloatingPanel; level = base.level; hasShadow = true; isOpaque = false
        backgroundColor = .clear; hidesOnDeactivate = false; animationBehavior = .none
        collectionBehavior = base.collectionBehavior
        ring.wantsLayer = true
        ring.layer?.cornerRadius = 18
        ring.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.16).cgColor
        ring.layer?.borderColor = NSColor.controlAccentColor.cgColor
        ring.layer?.borderWidth = 2.5
        contentView = glass.root
    }

    /// - Parameters:
    ///   - show: false = lay everything out but do not put the panel on screen (used to render pictures of it)
    func present(windows: [WindowInfo], layout: SwitcherLayout, selected: Int, on screen: NSScreen,
                 caption: String? = nil, query: String? = nil, center: NSPoint? = nil, show: Bool = true,
                 thumbnail: (CGWindowID) -> NSImage?) {
        let wasVisible = isVisible
        // (the look and transparency are re-read each time: Preferences, or macOS's "Reduce transparency", may have changed)
        let appearance = OverlayTheme.effective
        if glass.style != appearance.style { glass = OverlayTheme.makeGlass(); contentView = glass.root }
        glass.applyOpacity(appearance.opacity)
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
        captionLabel?.removeFromSuperview(); captionLabel = nil
        searchPill?.removeFromSuperview(); searchPill = nil
        messageLabel?.removeFromSuperview(); messageLabel = nil
        ring.removeFromSuperview()
        initialMouse = NSEvent.mouseLocation
        ringPlaced = false

        let tile = layout.tile, sp = layout.spacing, pad = SwitcherLayout.padding
        let hasQuery = !(query ?? "").isEmpty
        let header: CGFloat = (caption == nil && !hasQuery) ? 0 : OverlayTheme.captionHeight
        let gridWidth = CGFloat(layout.columns) * tile.width + CGFloat(layout.columns - 1) * sp
        let width = max(gridWidth + 2 * pad, caption == nil ? 0 : 520, hasQuery ? 300 : 0)
        let height = CGFloat(layout.rows) * tile.height + CGFloat(layout.rows - 1) * sp + 2 * pad + header
        let leftInset = (width - gridWidth) / 2
        glass.root.setFrameSize(NSSize(width: width, height: height))
        glass.backdrop.frame = glass.root.bounds
        glass.content.frame = glass.root.bounds

        glass.content.addSubview(ring)
        for (i, w) in windows.enumerated() {
            let row = i / layout.columns, col = i % layout.columns
            // An incomplete last row is centred. The rule lives in Core (`OverlayGrid`), shared with the arrow keys, so
            // "directly below" on screen is exactly what Down selects.
            let rowInset = CGFloat(OverlayGrid.rowOffset(row, count: windows.count, columns: layout.columns)) * (tile.width + sp)
            // Row 0 is at the top, but AppKit's origin is bottom-left.
            let origin = NSPoint(x: leftInset + rowInset + CGFloat(col) * (tile.width + sp),
                                 y: height - pad - header - tile.height - CGFloat(row) * (tile.height + sp))
            let v = WindowTileView(frame: NSRect(origin: origin, size: tile), index: i, info: w, thumbnail: layout.compact ? nil : thumbnail(w.id), compact: layout.compact)
            v.onClick = { [weak self] in self?.onClick?($0) }
            v.onClose = { [weak self] in self?.onClose?($0) }
            v.onContextMenu = { [weak self] idx, event in self?.onContextMenu?(idx, event) }
            v.onHover = { [weak self] idx in self?.hoverIfMouseMoved(idx) }
            glass.content.addSubview(v)
            tiles.append(v)
        }
        if let caption {
            let l = NSTextField(labelWithString: caption)
            l.font = .systemFont(ofSize: 13, weight: .semibold)
            l.textColor = NSColor.white.withAlphaComponent(0.78)
            l.alignment = .center
            l.frame = NSRect(x: pad, y: height - pad - 20, width: width - 2 * pad, height: 18)
            l.wantsLayer = true; l.shadow = OverlayTheme.softTextShadow()
            glass.content.addSubview(l)
            captionLabel = l
        }
        if hasQuery, let q = query {
            let pill = SearchPillView(query: q)
            pill.frame.origin = NSPoint(x: (width - pill.frame.width) / 2, y: height - pad - pill.frame.height + 2)
            glass.content.addSubview(pill)
            searchPill = pill
        }
        setSelected(selected, animated: false)

        let vf = screen.visibleFrame
        let c = center ?? NSPoint(x: vf.midX, y: vf.midY)
        setFrame(NSRect(x: c.x - width / 2, y: c.y - height / 2, width: width, height: height), display: true)
        guard show else { return }
        if wasVisible { orderFrontRegardless() } else { OverlayTheme.fadeIn(self) }
    }

    /// The overlay with no tiles: a search that matches nothing.
    func presentMessage(_ text: String, query: String, on screen: NSScreen, show: Bool = true) {
        let wasVisible = isVisible
        let appearance = OverlayTheme.effective
        if glass.style != appearance.style { glass = OverlayTheme.makeGlass(); contentView = glass.root }
        glass.applyOpacity(appearance.opacity)
        tiles.forEach { $0.removeFromSuperview() }; tiles.removeAll()
        captionLabel?.removeFromSuperview(); captionLabel = nil
        searchPill?.removeFromSuperview(); searchPill = nil
        messageLabel?.removeFromSuperview(); messageLabel = nil
        ring.removeFromSuperview(); ringPlaced = false

        let pad = SwitcherLayout.padding
        let pill = SearchPillView(query: query)
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.7)
        label.alignment = .center
        label.wantsLayer = true; label.shadow = OverlayTheme.softTextShadow()
        label.sizeToFit()
        let width = max(420, label.frame.width + 2 * pad, pill.frame.width + 2 * pad)
        let height = 2 * pad + OverlayTheme.captionHeight + 64
        glass.root.setFrameSize(NSSize(width: width, height: height))
        glass.backdrop.frame = glass.root.bounds
        glass.content.frame = glass.root.bounds
        pill.frame.origin = NSPoint(x: (width - pill.frame.width) / 2, y: height - pad - pill.frame.height + 2)
        label.frame = NSRect(x: pad, y: pad + 14, width: width - 2 * pad, height: 20)
        glass.content.addSubview(pill); glass.content.addSubview(label)
        searchPill = pill; messageLabel = label

        let vf = screen.visibleFrame
        setFrame(NSRect(x: vf.midX - width / 2, y: vf.midY - height / 2, width: width, height: height), display: true)
        guard show else { return }
        if wasVisible { orderFrontRegardless() } else { OverlayTheme.fadeIn(self) }
    }

    /// Ignore "hover" caused by the overlay appearing under a mouse that is not moving.
    private func hoverIfMouseMoved(_ index: Int) {
        let p = NSEvent.mouseLocation
        guard abs(p.x - initialMouse.x) > 4 || abs(p.y - initialMouse.y) > 4 else { return }
        onHover?(index)
    }

    /// Moves the highlight to a tile. It slides (a short ease-out) unless Reduce motion is on.
    func setSelected(_ index: Int, animated: Bool = true) {
        for t in tiles { t.isSelected = (t.index == index) }
        guard let target = tiles.first(where: { $0.index == index }) else { return }
        let frame = target.frame.insetBy(dx: -3, dy: -3)
        if animated && ringPlaced && OverlayTheme.motionEnabled {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)     // fast start, long soft landing
                ring.animator().frame = frame
            }
        } else {
            ring.frame = frame
        }
        ringPlaced = true
    }

    func setThumbnail(_ image: NSImage, for id: CGWindowID) {
        tiles.first { $0.windowID == id }?.setThumbnail(image)
    }

    /// The panel's picture, for tests and previews (`--render-overlay`).
    var contentSnapshotView: NSView { glass.root }
    /// Previews: show the close button on a tile (optionally in its pointed-at state).
    func debugShowCloseButton(on index: Int, pointedAt: Bool) { tiles.first { $0.index == index }?.debugShowCloseButton(pointedAt: pointedAt) }
    /// Where each tile is drawn (tests: do the arrow keys agree with what is on screen?).
    var debugTileFrames: [CGRect] { tiles.map(\.frame) }

    func dismiss() {
        orderOut(nil)
        tiles.forEach { $0.removeFromSuperview() }
        tiles.removeAll()
    }
}
