import Foundation

/// Drag observation is needed by shake activation, notch activation, or both.
/// Keeping the state explicit prevents disabling shake from disabling notch.
enum ShelfActivationMode: Equatable {
    case inactive
    case shakeOnly
    case notchOnly
    case shakeAndNotch

    init(shelfEnabled: Bool, shakeEnabled: Bool, notchEnabled: Bool) {
        guard shelfEnabled else {
            self = .inactive
            return
        }
        switch (shakeEnabled, notchEnabled) {
        case (false, false): self = .inactive
        case (true, false): self = .shakeOnly
        case (false, true): self = .notchOnly
        case (true, true): self = .shakeAndNotch
        }
    }

    var observesDrags: Bool { self != .inactive }
    var recognizesShake: Bool { self == .shakeOnly || self == .shakeAndNotch }
    var showsNotch: Bool { self == .notchOnly || self == .shakeAndNotch }
}
