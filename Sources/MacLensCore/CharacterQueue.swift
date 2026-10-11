import Foundation

/// What the desktop character can deliver (#39). Declaration order is priority: earlier kinds are shown first.
public enum CharacterAlertKind: String, CaseIterable, Comparable, Sendable {
    case batteryLow, hot, runaway, water, batteryHigh, update

    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
    private var rank: Int { Self.allCases.firstIndex(of: self)! }
}

public struct CharacterAlert: Equatable, Sendable {
    public var kind: CharacterAlertKind
    public var title: String
    public var message: String
    /// Shown on a prop, e.g. the process name on the runaway sign.
    public var subject: String?
    /// "Show a test character": always valid, so it isn't dropped because the real condition isn't true.
    public var isTest: Bool

    public init(kind: CharacterAlertKind, title: String, message: String, subject: String? = nil, isTest: Bool = false) {
        self.kind = kind; self.title = title; self.message = message; self.subject = subject; self.isTest = isTest
    }
}

/// Which alert the desktop character shows, and when. Pure state machine; the app calls `tick` when something changes.
/// Rules: one alert on screen at a time; the rest wait, at most one per kind, in priority order (a newer one replaces the queued one);
/// nothing appears while the screen is shared, while paused, or while the user is away; if sharing starts or a pause is set
/// while one is on screen, it is hidden at once and goes back in the queue if it's still valid. Alerts that stop being valid
/// (battery no longer low, Mac cooled down…) are dropped from the queue. A visible alert stays until the user dismisses it.
public struct CharacterQueue: Sendable {
    public private(set) var showing: CharacterAlert?
    /// Highest priority first.
    public private(set) var pending: [CharacterAlert] = []

    public init() {}

    public enum Why: Equatable, Sendable { case empty, visible, sharing, paused, away }
    public enum Decision: Equatable, Sendable { case show(CharacterAlert), hide, wait(Why) }

    public var isIdle: Bool { showing == nil && pending.isEmpty }
    public func contains(_ kind: CharacterAlertKind) -> Bool { showing?.kind == kind || pending.contains { $0.kind == kind } }

    /// Queues an alert. Returns true if it replaced the alert on screen (same kind), which the app should redraw in place.
    @discardableResult
    public mutating func add(_ a: CharacterAlert) -> Bool {
        if showing?.kind == a.kind { showing = a; return true }
        pending.removeAll { $0.kind == a.kind }
        pending.append(a)
        pending.sort { $0.kind < $1.kind } // stable: equal kinds can't coexist
        return false
    }

    public mutating func tick(sharing: Bool, paused: Bool, away: Bool, isValid: (CharacterAlert) -> Bool) -> Decision {
        pending.removeAll { !isValid($0) }
        if let s = showing {
            guard sharing || paused else { return .wait(.visible) }
            showing = nil
            if isValid(s) { add(s) }
            return .hide
        }
        guard let next = pending.first else { return .wait(.empty) }
        if sharing { return .wait(.sharing) }
        if paused { return .wait(.paused) }
        if away { return .wait(.away) }
        pending.removeFirst()
        showing = next
        return .show(next)
    }

    /// The user clicked one of the alert's buttons.
    @discardableResult
    public mutating func dismiss() -> CharacterAlert? {
        defer { showing = nil }
        return showing
    }
}
