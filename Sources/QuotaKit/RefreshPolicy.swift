import Foundation
import IOKit.ps

/// What the Mac is running on, which decides how often the background refreshes run.
struct PowerConditions: Equatable {
    var onBattery = false
    var lowPower = false
    /// Thermal state serious or critical.
    var thermalPressure = false

    static func current() -> PowerConditions {
        let info = ProcessInfo.processInfo
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let source = snapshot.flatMap { IOPSGetProvidingPowerSourceType($0)?.takeUnretainedValue() } as String?
        return PowerConditions(onBattery: source == kIOPSBatteryPowerValue, lowPower: info.isLowPowerModeEnabled,
                               thermalPressure: info.thermalState == .serious || info.thermalState == .critical)
    }
}

/// When providers refresh. Opening the panel, copying the image and waking the Mac refresh right
/// away; background refreshes only keep the cache warm, because nothing shows the values until the
/// panel opens. Local providers read files and are polled more often than tools, which start
/// processes; both back off on battery, and tools stop in Low Power Mode or under thermal pressure.
/// While the panel stays open everything refreshes every 5 minutes, so no row goes stale in view.
enum RefreshPolicy {
    /// A provider refreshed less than this long ago is not refreshed again, except by 刷新.
    static let throttle: TimeInterval = 60
    /// After one or two failed queries in a row the provider retries sooner, so a passing failure
    /// does not grey out a row until the next background refresh; after that it waits as usual.
    static let retries: [TimeInterval] = [300, 900]

    /// The background interval, or nil for none.
    static func interval(local: Bool, _ conditions: PowerConditions, panelOpen: Bool = false) -> TimeInterval? {
        if panelOpen { return 300 }
        if conditions.lowPower || conditions.thermalPressure { return local ? 3600 : nil }
        if conditions.onBattery { return local ? 1200 : 3 * 3600 }
        return local ? 600 : 3600
    }

    static func isDue(local: Bool, lastRun: Date?, failures: Int, conditions: PowerConditions, panelOpen: Bool = false, at date: Date) -> Bool {
        guard let interval = interval(local: local, conditions, panelOpen: panelOpen) else { return false }
        guard let lastRun else { return true }
        let wait = retries.indices.contains(failures - 1) ? min(retries[failures - 1], interval) : interval
        return date.timeIntervalSince(lastRun) >= wait
    }
}
