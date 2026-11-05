import CoreGraphics

/// Most-recently-used ordering of window IDs.
public struct MRUList<ID: Hashable> {
    public private(set) var order: [ID] = []
    private let cap: Int
    public init(cap: Int = 500) { self.cap = cap }

    /// Mark a window as just used: it moves to the front.
    public mutating func touch(_ id: ID) {
        order.removeAll { $0 == id }
        order.insert(id, at: 0)
    }

    /// The live windows in MRU order. `live` must be front-to-back (z-order). Windows we have
    /// never seen are most likely new, so they go in front, keeping their z-order among themselves.
    public func ordered(live: [ID]) -> [ID] {
        let liveSet = Set(live)
        let known = Set(order)
        let unknown = live.filter { !known.contains($0) }
        return unknown + order.filter { liveSet.contains($0) }
    }

    /// Remember windows we have not seen before (in front, in z-order) WITHOUT disturbing the relative order
    /// of everything else. Windows that are not "live" right now (for example on another Space) keep their
    /// place, so recency still means something across Spaces. Only when the list grows past `cap`
    /// are the oldest non-live entries dropped.
    public mutating func reconcile(live: [ID]) {
        let known = Set(order)
        order = live.filter { !known.contains($0) } + order
        guard order.count > cap else { return }
        let liveSet = Set(live)
        var excess = order.count - cap
        order = order.reversed().filter { id in
            if excess > 0 && !liveSet.contains(id) { excess -= 1; return false }
            return true
        }.reversed()
    }
}

/// How the overlay lays its tiles out in a grid: full rows, and an incomplete LAST row centred under them. Both the
/// drawing code and the arrow-key navigation use this one definition, so they can never disagree about what is "below".
public enum OverlayGrid {
    public static func rows(count: Int, columns: Int) -> Int { count <= 0 ? 0 : (count + max(1, columns) - 1) / max(1, columns) }

    public static func itemsInRow(_ row: Int, count: Int, columns: Int) -> Int {
        max(0, min(max(1, columns), count - row * max(1, columns)))
    }

    /// How far the row is shifted right of the left edge, in tile widths (a full row is 0; a short last row is centred).
    public static func rowOffset(_ row: Int, count: Int, columns: Int) -> Double {
        Double(max(1, columns) - itemsInRow(row, count: count, columns: columns)) / 2
    }

    /// Horizontal position of a tile, in tile widths from the left edge of the grid.
    public static func x(of index: Int, count: Int, columns: Int) -> Double {
        let cols = max(1, columns)
        return rowOffset(index / cols, count: count, columns: cols) + Double(index % cols)
    }
}

/// Selection state of the Alt-Tab overlay.
public struct SwitcherSelection: Equatable {
    public private(set) var count: Int
    public private(set) var index: Int

    /// Forward: the SECOND window (index 1) is selected first, so a quick tap toggles between the
    /// two most recent windows. Reverse (Shift+Tab to open): starts on the last window.
    public init(count: Int, reverse: Bool = false) {
        self.count = count
        if count <= 1 { index = 0 } else { index = reverse ? count - 1 : 1 }
    }

    public mutating func next()     { if count > 0 { index = (index + 1) % count } }
    public mutating func previous() { if count > 0 { index = (index - 1 + count) % count } }
    /// A window was closed while the overlay is open. Keep the highlight on the same window where possible.
    public mutating func didRemove(at removed: Int, newCount: Int) {
        count = max(0, newCount)
        if count == 0 { index = 0; return }
        if removed < index { index -= 1 }
        index = min(max(index, 0), count - 1)       // if the selected window itself was closed, the next one is selected
    }

    public mutating func select(_ i: Int) { if i >= 0 && i < count { index = i } }

    /// Arrow keys on a grid with `columns` columns. Every arrow always does something sensible:
    /// - Left / Right step through the windows and wrap around, like Tab.
    /// - With a single row, Down means "next" and Up means "previous" (there is no row to move to).
    /// - With several rows, Down / Up go to the tile that is visually directly below / above (the same horizontal position,
    ///   which matters because a short last row is centred). When nothing is exactly there, the nearest tile in that row is
    ///   used. Past the last (first) row they wrap to the first (last) row.
    public mutating func move(_ key: ArrowKey, columns: Int) {
        guard count > 0 else { return }
        let cols = max(1, columns)
        let rows = OverlayGrid.rows(count: count, columns: cols)
        switch key {
        case .left: previous()
        case .right: next()
        case .down, .up:
            if rows == 1 { if key == .down { next() } else { previous() }; return }
            let row = index / cols
            let target = key == .down ? (row + 1) % rows : (row - 1 + rows) % rows
            let here = OverlayGrid.x(of: index, count: count, columns: cols)
            let offset = OverlayGrid.rowOffset(target, count: count, columns: cols)
            var best = 0, bestDistance = Double.greatestFiniteMagnitude
            for c in 0..<OverlayGrid.itemsInRow(target, count: count, columns: cols) {
                let d = abs(offset + Double(c) - here)
                if d < bestDistance - 0.0001 { best = c; bestDistance = d }          // ties go to the left
            }
            index = target * cols + best
        }
    }
}
