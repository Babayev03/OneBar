import CoreGraphics
import Foundation

/// The built-in panel's backlight. It speaks no DDC — the brightness keys go
/// through Apple's own private `DisplayServices`, so we use the same door, and
/// the value we set is the one System Settings reads back.
///
/// Everything is `dlsym`'d and optional: a symbol that disappears in some
/// future macOS leaves the built-in display uncontrollable, rather than taking
/// the app down with it.
enum DisplayServicesShim {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool

    private static let symbols: (get: GetFn?, set: SetFn?, canChange: CanChangeFn?) = {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

        func load<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        return (
            load("DisplayServicesGetBrightness", as: GetFn.self),
            load("DisplayServicesSetBrightness", as: SetFn.self),
            load("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
        )
    }()

    static func canChangeBrightness(_ display: CGDirectDisplayID) -> Bool {
        guard symbols.set != nil else { return false }
        // A missing capability check is not a refusal — assume yes and let the
        // set call be the judge.
        return symbols.canChange?(display) ?? true
    }

    static func brightness(_ display: CGDirectDisplayID) -> Double? {
        guard let get = symbols.get else { return nil }
        var value: Float = 0
        guard get(display, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    static func setBrightness(_ display: CGDirectDisplayID, to value: Double) -> Bool {
        guard let set = symbols.set else { return false }
        return set(display, Float(min(max(value, 0), 1))) == 0
    }
}
