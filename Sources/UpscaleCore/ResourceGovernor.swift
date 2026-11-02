import Foundation
import Darwin

/// Pure policy, independently testable. Grows at row boundaries, never adds concurrency.
public struct ResourceGovernor: Sendable {
    public private(set) var tier = 0
    private var stable = 0
    private var baseline: Double?
    public var coreSide: Int { [64, 128, 192][tier] }

    public init() {}
    public mutating func observe(secondsPerPixel: Double, constrained: Bool) {
        if constrained {
            tier = max(0, tier - 1)
            stable = 0
            baseline = nil
            return
        }
        if let baseline, secondsPerPixel > baseline * 1.5 {
            tier = max(0, tier - 1)
            stable = -6 // Cooldown before probing a larger block again.
            self.baseline = nil
            return
        }
        baseline = baseline.map { $0 * 0.8 + secondsPerPixel * 0.2 } ?? secondsPerPixel
        stable += 1
        if stable >= 6, tier < 2 {
            tier += 1
            stable = 0
        }
    }
}

public enum MemorySnapshot {
    /// Conservative system estimate. Pressure notifications remain the authority.
    public static func availableBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * UInt64(vm_kernel_page_size)
    }
}

public enum ImageMode: String, CaseIterable, Sendable {
    case illustration, photo
    public var title: String { self == .illustration ? "Ilustración / anime" : "Fotografía" }
    public var modelName: String { self == .illustration ? "Anime4x" : "Photo4x" }
}
