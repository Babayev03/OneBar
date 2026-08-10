import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class SystemStatsService {
    static let shared = SystemStatsService()

    private(set) var cpuUsage: Double = 0     // 0...1
    private(set) var memUsage: Double = 0     // 0...1
    private(set) var diskUsage: Double = 0    // 0...1
    private(set) var memUsedGB: Double = 0
    private(set) var memTotalGB: Double = 0
    private(set) var diskFreeGB: Double = 0
    private(set) var diskTotalGB: Double = 0

    private var timer: Timer?
    private var prevTicks: [UInt64] = []      // per-cpu: used, total pairs flattened

    private init() {}

    func start() {
        guard timer == nil else { return }
        sample() // baseline for the CPU delta; first visible value lands on the next tick
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            Task { @MainActor in self?.sample() }
        }
        let timer = Timer(timeInterval: AppState.shared.statsInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-applies the configured interval if currently sampling.
    func restart() {
        guard timer != nil else { return }
        stop()
        start()
    }

    private func sample() {
        sampleCPU()
        sampleMemory()
        sampleDisk()
    }

    private func sampleCPU() {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.size))
        }

        let stride = Int(CPU_STATE_MAX)
        let ticks = UnsafeBufferPointer(start: info, count: Int(infoCount))
        var newTicks: [UInt64] = []
        newTicks.reserveCapacity(Int(cpuCount) * 2)

        var usedDelta: Double = 0
        var totalDelta: Double = 0

        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            let user = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: ticks[base + Int(CPU_STATE_IDLE)]))
            let used = user &+ system &+ nice
            let total = used &+ idle
            newTicks.append(used)
            newTicks.append(total)

            let prevIndex = cpu * 2
            if prevIndex + 1 < prevTicks.count {
                let du = Double(used &- prevTicks[prevIndex])
                let dt = Double(total &- prevTicks[prevIndex + 1])
                if dt > 0 && du >= 0 && du <= dt {
                    usedDelta += du
                    totalDelta += dt
                }
            }
        }

        prevTicks = newTicks
        if totalDelta > 0 {
            cpuUsage = min(max(usedDelta / totalDelta, 0), 1)
        }
    }

    private func sampleMemory() {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let pageSize = UInt64(vm_kernel_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        let total = ProcessInfo.processInfo.physicalMemory
        guard total > 0 else { return }

        memUsage = min(max(Double(used) / Double(total), 0), 1)
        memUsedGB = Double(used) / 1_073_741_824
        memTotalGB = Double(total) / 1_073_741_824
    }

    private func sampleDisk() {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacityForImportantUsage,
              let total = values.volumeTotalCapacity, total > 0
        else { return }

        diskUsage = min(max(1 - Double(free) / Double(total), 0), 1)
        diskFreeGB = Double(free) / 1_000_000_000
        diskTotalGB = Double(total) / 1_000_000_000
    }
}
