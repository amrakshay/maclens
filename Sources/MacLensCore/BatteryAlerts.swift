import Foundation

/// Decides when to fire battery-level alerts: once per crossing, never repeatedly while the level stays past the threshold.
///  - Low alert: fires when the battery *drops to* `low` or below while discharging. Re-arms after charging back above `low + 2`.
///  - High alert: fires when the battery *charges up to* `high` or above. Re-arms after it falls below `high - 2`.
/// A level that's already past a threshold when observation starts doesn't fire (nothing was "hit"); it only re-arms.
public struct BatteryAlertState: Sendable {
    public enum Alert: Equatable, Sendable { case low(Int), high(Int) }

    private var lowArmed = false
    private var highArmed = false
    private var started = false
    static let hysteresis = 2

    public init() {}

    public mutating func update(percent: Int, charging: Bool, onAC: Bool, low: Int, high: Int) -> Alert? {
        defer { started = true }
        if !started {
            lowArmed = percent > low
            highArmed = percent < high
            return nil
        }
        var alert: Alert?
        if lowArmed && percent <= low && !charging && !onAC {
            alert = .low(percent); lowArmed = false
        } else if !lowArmed && percent > low + Self.hysteresis {
            lowArmed = true
        }
        if highArmed && percent >= high && (charging || onAC) {
            alert = alert ?? .high(percent); highArmed = false
        } else if !highArmed && percent < high - Self.hysteresis {
            highArmed = true
        }
        return alert
    }
}
