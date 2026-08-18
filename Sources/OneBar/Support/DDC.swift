import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over I²C — the protocol a monitor's own scaler speaks, and the only
/// way to move an external panel's backlight from software. macOS ships no
/// public API for it, so on Apple Silicon the transport is the private
/// `IOAVService` inside IOKit, reached by `dlsym` rather than a header.
///
/// The wire format and the IORegistry pairing below are derived from
/// MonitorControl (https://github.com/MonitorControl/MonitorControl), MIT.
///
/// Every call sleeps for tens of milliseconds waiting on the monitor, so none
/// of this may run on the main actor — `BrightnessService` owns a serial queue
/// for it.
enum DDC {
    /// VCP feature code for luminance. Contrast is 0x12 and audio volume 0x62,
    /// should either ever be wanted.
    static let brightnessVCP: UInt8 = 0x10

    /// A monitor's I²C channel. Holds the `IOAVService` the writes go through
    /// plus the identity of the framebuffer it hangs off, which is what pairs
    /// it back to a `CGDirectDisplayID`.
    struct Channel {
        let service: CFTypeRef
        let edidUUID: String
        let serialNumber: Int64
        let registryPath: String
        /// Discovery order, used as the last-resort tiebreaker when nothing
        /// identifying matches.
        let index: Int
    }

    // MARK: - Private IOKit entry points

    private typealias CreateWithServiceFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias InfoDictionaryFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    /// Looked up once, and optional throughout: if Apple ever drops one of
    /// these, brightness degrades to software dimming instead of the app
    /// failing to launch.
    private static let symbols: (
        create: CreateWithServiceFn?,
        read: I2CFn?,
        write: I2CFn?,
        displayInfo: InfoDictionaryFn?
    ) = {
        let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        let coreDisplay = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

        func load<T>(_ handle: UnsafeMutableRawPointer?, _ name: String, as type: T.Type) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else { return nil }
            return unsafeBitCast(symbol, to: type)
        }

        return (
            load(ioKit, "IOAVServiceCreateWithService", as: CreateWithServiceFn.self),
            load(ioKit, "IOAVServiceReadI2C", as: I2CFn.self),
            load(ioKit, "IOAVServiceWriteI2C", as: I2CFn.self),
            load(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary", as: InfoDictionaryFn.self)
        )
    }()

    static var isAvailable: Bool { symbols.create != nil && symbols.write != nil }

    // MARK: - Reading and writing a feature

    private static let i2cAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    /// Current and maximum value of a feature, or nil if the monitor didn't
    /// answer. Plenty of panels accept writes while never replying to reads,
    /// so a nil here is not proof that DDC is unsupported — only that we can't
    /// learn the current value.
    static func read(_ channel: Channel, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        var request: [UInt8] = [vcp]
        var reply = [UInt8](repeating: 0, count: 11)
        guard transact(channel, send: &request, reply: &reply) else { return nil }
        return (
            current: UInt16(reply[8]) << 8 | UInt16(reply[9]),
            max: UInt16(reply[6]) << 8 | UInt16(reply[7])
        )
    }

    @discardableResult
    static func write(_ channel: Channel, vcp: UInt8, value: UInt16) -> Bool {
        var request: [UInt8] = [vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        var reply: [UInt8] = []
        return transact(channel, send: &request, reply: &reply)
    }

    /// One DDC exchange. The frame is `[0x80 | length+1, length, payload…,
    /// checksum]`, and the checksum seed differs between a read request and a
    /// write because it covers the I²C addresses too.
    private static func transact(_ channel: Channel, send: inout [UInt8], reply: inout [UInt8]) -> Bool {
        guard let writeI2C = symbols.write else { return false }

        var packet: [UInt8] = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send + [0]
        let seed = send.count == 1
            ? UInt8(i2cAddress << 1)
            : UInt8(i2cAddress << 1) ^ UInt8(dataAddress)
        packet[packet.count - 1] = checksum(seed: seed, data: packet, through: packet.count - 2)

        let packetSize = UInt32(packet.count)
        let replySize = UInt32(reply.count)

        // Retried, and written twice per attempt: a monitor silently dropping a
        // single I²C frame is normal, not exceptional.
        for _ in 0...4 {
            var success = false
            for _ in 0..<2 {
                usleep(10_000)
                success = packet.withUnsafeMutableBytes { buffer in
                    writeI2C(channel.service, i2cAddress, dataAddress, buffer.baseAddress!, packetSize) == 0
                }
            }

            if !reply.isEmpty, let readI2C = symbols.read {
                usleep(50_000)
                success = reply.withUnsafeMutableBytes { buffer in
                    readI2C(channel.service, i2cAddress, 0, buffer.baseAddress!, replySize) == 0
                }
                if success {
                    success = checksum(seed: 0x50, data: reply, through: reply.count - 2) == reply[reply.count - 1]
                }
            }

            if success { return true }
            usleep(20_000)
        }
        return false
    }

    private static func checksum(seed: UInt8, data: [UInt8], through end: Int) -> UInt8 {
        var value = seed
        for index in 0...end { value ^= data[index] }
        return value
    }

    // MARK: - Finding the channels

    /// Every external monitor's I²C channel, in IORegistry order.
    ///
    /// The walk is linear on purpose: a framebuffer node carries the display's
    /// identity, and the `DCPAVServiceProxy` that follows it carries the AV
    /// service. Pairing them means remembering the last framebuffer seen.
    static func channels() -> [Channel] {
        guard let create = symbols.create else { return [] }

        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(
            IORegistryGetRootEntry(kIOMainPortDefault),
            "IOService",
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var found: [Channel] = []
        var edidUUID = ""
        var serialNumber: Int64 = 0
        var registryPath = ""

        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }

            var rawName = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
            guard IORegistryEntryGetName(entry, &rawName) == KERN_SUCCESS else { continue }
            let name = String(cString: rawName)

            if name == "AppleCLCD2" || name == "IOMobileFramebufferShim" {
                edidUUID = property(entry, "EDID UUID") as? String ?? ""
                serialNumber = 0
                if let attributes = property(entry, "DisplayAttributes") as? NSDictionary,
                   let product = attributes["ProductAttributes"] as? NSDictionary {
                    serialNumber = product["SerialNumber"] as? Int64 ?? 0
                }
                var path = [CChar](repeating: 0, count: 4096)
                registryPath = IORegistryEntryGetPath(entry, "IOService", &path) == KERN_SUCCESS
                    ? String(cString: path)
                    : ""
            } else if name == "DCPAVServiceProxy" {
                // "Embedded" is the built-in panel, which has no DDC at all —
                // it is driven through DisplayServices instead.
                guard property(entry, "Location") as? String == "External",
                      let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue()
                else { continue }

                found.append(Channel(
                    service: service,
                    edidUUID: edidUUID,
                    serialNumber: serialNumber,
                    registryPath: registryPath,
                    index: found.count
                ))
            }
        }
        return found
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(
            entry,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        )?.takeRetainedValue()
    }

    // MARK: - Pairing channels with displays

    /// Assigns each display the channel most likely to be its own.
    ///
    /// Ordering alone would do for one monitor, but two identical panels are
    /// exactly the case where it silently picks the wrong one — so candidates
    /// are scored on identity first and claimed best-match-first.
    static func match(channels: [Channel], to displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: Channel] {
        var scored: [(score: Int, displayID: CGDirectDisplayID, channel: Channel)] = []
        for displayID in displayIDs {
            for channel in channels {
                scored.append((score(channel, for: displayID), displayID, channel))
            }
        }
        // Sorting isn't stable, so discovery order breaks ties explicitly —
        // otherwise two channels nothing distinguishes could swap displays
        // between one refresh and the next.
        scored.sort { ($0.score, $1.channel.index) > ($1.score, $0.channel.index) }

        var matched: [CGDirectDisplayID: Channel] = [:]
        var claimed = Set<Int>()
        for candidate in scored where matched[candidate.displayID] == nil && !claimed.contains(candidate.channel.index) {
            matched[candidate.displayID] = candidate.channel
            claimed.insert(candidate.channel.index)
        }
        return matched
    }

    private static func score(_ channel: Channel, for displayID: CGDirectDisplayID) -> Int {
        var score = 0

        // The registry path of the framebuffer is the one signal that is
        // unambiguous even between two of the same model.
        if !channel.registryPath.isEmpty,
           let info = symbols.displayInfo?(displayID)?.takeRetainedValue() as NSDictionary?,
           let location = info["IODisplayLocation"] as? String,
           location == channel.registryPath {
            score += 10
        }

        // The EDID UUID opens with the vendor id, then the product id with its
        // bytes the other way round.
        let vendor = String(format: "%04X", UInt16(truncatingIfNeeded: CGDisplayVendorNumber(displayID)))
        let model = UInt16(truncatingIfNeeded: CGDisplayModelNumber(displayID))
        let product = String(format: "%02X%02X", UInt8(model & 0xFF), UInt8(model >> 8))
        let uuid = channel.edidUUID.uppercased()
        if uuid.count >= 8 {
            let start = uuid.startIndex
            if vendor != "0000", uuid[start..<uuid.index(start, offsetBy: 4)] == vendor { score += 2 }
            let productRange = uuid.index(start, offsetBy: 4)..<uuid.index(start, offsetBy: 8)
            if product != "0000", uuid[productRange] == product { score += 2 }
        }

        if channel.serialNumber != 0, Int64(CGDisplaySerialNumber(displayID)) == channel.serialNumber {
            score += 2
        }

        return score
    }
}
