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
    /// - With several rows, Down / Up move one row, staying in the same column; past the last (first) row they wrap to the
    ///   first (last) row. An incomplete last row is handled: you land on its last window.
    public mutating func move(_ key: ArrowKey, columns: Int) {
        guard count > 0 else { return }
        let cols = max(1, columns)
        let rows = (count + cols - 1) / cols
        switch key {
        case .left: previous()
        case .right: next()
        case .down:
            if rows == 1 { next(); return }
            let row = index / cols
            if row == rows - 1 { index = index % cols }                    // from the last row: wrap to the top, same column
            else { index = min(index + cols, count - 1) }                  // otherwise one row down (clamped on a short last row)
        case .up:
            if rows == 1 { previous(); return }
            if index - cols >= 0 { index -= cols }
            else {                                                         // from the top row: wrap to the bottom, same column
                var bottom = index + (rows - 1) * cols
                while bottom >= count { bottom -= cols }
                index = bottom
            }
        }
    }
}
