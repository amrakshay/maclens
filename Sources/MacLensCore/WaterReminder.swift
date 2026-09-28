import Foundation
import CoreGraphics
import IOKit

/// Work hours for reminders, in a fixed time zone (default IST) so they don't move if the Mac's time zone changes.
public struct WorkSchedule: Equatable, Sendable {
    /// Minutes after midnight.
    public var start: Int
    public var end: Int
    /// Calendar weekdays: 1 = Sunday … 7 = Saturday.
    public var weekdays: Set<Int>
    public var timeZone: TimeZone

    public init(start: Int = 10 * 60, end: Int = 19 * 60, weekdays: Set<Int> = [2, 3, 4, 5, 6],
                timeZone: TimeZone = TimeZone(identifier: "Asia/Kolkata")!) {
        self.start = start; self.end = end; self.weekdays = weekdays; self.timeZone = timeZone
    }

    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }

    public func contains(_ date: Date) -> Bool {
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let wd = c.weekday, weekdays.contains(wd) else { return false }
        let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return m >= start && m < end
    }

    /// End of the shift that contains `date` (nil outside work hours).
    public func shiftEnd(containing date: Date) -> Date? {
        guard contains(date) else { return nil }
        return calendar.date(bySettingHour: end / 60, minute: end % 60, second: 0, of: date)
    }
}

/// When to show a water reminder. Pure state machine, driven by `tick` about once a minute.
/// Rules: at most one reminder is ever owed or visible (no pile-up); one owed while sharing or paused is shown once that ends;
/// one owed at the end of the shift is dropped; when the user is away, the reminder is skipped, not owed.
public struct WaterReminderEngine: Sendable {
    public var interval: TimeInterval
    public var schedule: WorkSchedule
    public private(set) var nextDue: Date?
    /// A reminder came due while sharing or paused and will be shown when that ends.
    public private(set) var owed = false
    public var pausedUntil: Date?

    public init(interval: TimeInterval = 30 * 60, schedule: WorkSchedule = WorkSchedule(), pausedUntil: Date? = nil) {
        self.interval = interval; self.schedule = schedule; self.pausedUntil = pausedUntil
    }

    public enum Why: Equatable, Sendable { case offHours, paused, sharing, away, alertVisible, notDue }
    public enum Decision: Equatable, Sendable { case show, wait(Why) }

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { now < $0 } ?? false }

    public mutating func tick(now: Date, sharing: Bool, away: Bool, alertVisible: Bool) -> Decision {
        if let p = pausedUntil, now >= p { pausedUntil = nil }
        guard schedule.contains(now) else { nextDue = nil; owed = false; return .wait(.offHours) }
        guard let due = nextDue else { nextDue = now.addingTimeInterval(interval); return .wait(.notDue) } // shift start / enable
        guard owed || now >= due else { return .wait(.notDue) }
        if isPaused(at: now) { owed = true; return .wait(.paused) }
        if away { owed = false; nextDue = now.addingTimeInterval(interval); return .wait(.away) }
        if sharing { owed = true; return .wait(.sharing) }
        if alertVisible { owed = false; nextDue = now.addingTimeInterval(interval); return .wait(.alertVisible) }
        owed = false
        nextDue = now.addingTimeInterval(interval)
        return .show
    }

    /// The user acknowledged the reminder: count the next interval from now.
    public mutating func done(now: Date) { owed = false; nextDue = now.addingTimeInterval(interval) }
    public mutating func snooze(_ seconds: TimeInterval, now: Date) { owed = false; nextDue = now.addingTimeInterval(seconds) }
    /// Interval or schedule changed: start counting again.
    public mutating func reset() { nextDue = nil; owed = false }
}

/// Signals used to skip reminders. None of them needs a permission prompt.
public enum PresenceSignals {
    private typealias WatcherFn = @convention(c) () -> Bool
    private static let watcher: WatcherFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let f = dlsym(h, "SLSIsScreenWatcherPresent") else { return nil }
        return unsafeBitCast(f, to: WatcherFn.self)
    }()

    /// True while another process captures the screen: Zoom sharing (verified on macOS 26), and very likely recording and
    /// mirroring (#29). Private SkyLight call resolved at run time; nil if a future macOS removes it.
    public static func screenIsShared() -> Bool? { watcher?() }

    /// Seconds since the last keyboard/mouse input (IOHIDSystem's HIDIdleTime, nanoseconds).
    public static func idleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return v.doubleValue / 1e9
    }

    public static func screenIsLocked() -> Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (d["CGSSessionScreenIsLocked"] as? Bool) == true
    }
}
