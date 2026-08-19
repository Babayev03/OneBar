import Foundation
import IOKit

/// The switch behind "does closing the lid put this Mac to sleep".
///
/// macOS refuses closed-lid operation on battery, and no public API asks it to
/// stop. The power manager's user client takes a numbered command that does —
/// `kPMSetClamshellSleepState`, defined as 12 in the SDK's own
/// `IOKit.framework/Headers/pwr_mgt/IOPMLibDefs.h`, which reaches C but not
/// Swift, hence the literal below. No entitlement, no helper tool and no
/// password: Amphetamine, sandboxed and App Store signed, drives the lid the
/// same way.
@MainActor
enum Clamshell {
    private static let setClamshellSleepState: UInt32 = 12

    /// Kept open for as long as the lid is being held awake. Nothing documents
    /// whether the kernel restores lid sleep when its client goes away, so the
    /// state is both held and put back explicitly rather than trusted to one.
    private static var connection: io_connect_t = IO_OBJECT_NULL

    private(set) static var isSleepDisabled = false

    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        // Restoring always writes, even with no connection of our own open: a
        // force quit or a crash leaves the switch set with nobody left to
        // clear it, so the next launch has to be able to clear it blind.
        guard let connection = openConnection() else { return false }

        var input: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(connection, setClamshellSleepState, &input, 1, nil, nil)
        guard result == kIOReturnSuccess else {
            closeConnection()
            return false
        }

        isSleepDisabled = disabled
        if !disabled { closeConnection() }
        return true
    }

    private static func openConnection() -> io_connect_t? {
        if connection != IO_OBJECT_NULL { return connection }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var port: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &port) == kIOReturnSuccess else { return nil }
        connection = port
        return port
    }

    private static func closeConnection() {
        guard connection != IO_OBJECT_NULL else { return }
        IOServiceClose(connection)
        connection = IO_OBJECT_NULL
    }

    /// Diagnostic only — never branch on it. On Apple silicon this property
    /// reads `No` at rest even while lid close is demonstrably still sleeping
    /// the Mac, so it says nothing about the switch above.
    static var registryCausesSleep: Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0
        )
        return property?.takeRetainedValue() as? Bool
    }
}
