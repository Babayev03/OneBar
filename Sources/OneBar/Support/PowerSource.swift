import Foundation
import IOKit.ps

/// Battery charge and whether the Mac is plugged in — just enough for the
/// low-battery cutoff. `SystemStatsService` covers CPU, memory and disk and
/// has no reason to poll power.
enum PowerSource {
    /// An unlimited estimate is how power management says "on AC".
    static var isOnAC: Bool {
        IOPSGetTimeRemainingEstimate() == kIOPSTimeRemainingUnlimited
    }

    /// Charge as a percentage, or nil on a Mac with no battery at all.
    static var percentage: Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any],
                let current = info[kIOPSCurrentCapacityKey as String] as? Int,
                let maximum = info[kIOPSMaxCapacityKey as String] as? Int,
                maximum > 0
            else { continue }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return nil
    }
}
