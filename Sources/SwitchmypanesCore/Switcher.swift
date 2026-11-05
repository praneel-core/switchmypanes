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

    /// Store the result of `ordered(live:)` and drop very old dead entries.
    public mutating func reconcile(live: [ID]) {
        let merged = ordered(live: live)
        let liveSet = Set(live)
        let dead = order.filter { !liveSet.contains($0) }
        // keep dead ones only while there is room (a window on another Space may come back)
        order = merged + dead.prefix(max(0, cap - merged.count))
    }
}

/// Selection state of the Alt-Tab overlay.
public struct SwitcherSelection: Equatable {
    public let count: Int
    public private(set) var index: Int

    /// Forward: the SECOND window (index 1) is selected first, so a quick tap toggles between the
    /// two most recent windows. Reverse (Shift+Tab to open): starts on the last window.
    public init(count: Int, reverse: Bool = false) {
        self.count = count
        if count <= 1 { index = 0 } else { index = reverse ? count - 1 : 1 }
    }

    public mutating func next()     { if count > 0 { index = (index + 1) % count } }
    public mutating func previous() { if count > 0 { index = (index - 1 + count) % count } }
    public mutating func select(_ i: Int) { if i >= 0 && i < count { index = i } }

    /// Arrow keys on a grid with `columns` columns. Left/right wrap like Tab; up/down stay put at the edges.
    public mutating func move(_ key: ArrowKey, columns: Int) {
        switch key {
        case .left: previous()
        case .right: next()
        case .up:   if index - columns >= 0 { index -= columns }
        case .down: if index + columns < count { index += columns }
        }
    }
}
