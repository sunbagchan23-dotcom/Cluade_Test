import Darwin
import os

/// 확장 프로세스의 메모리 사용량. iOS가 한도 판정에 쓰는 값은 phys_footprint다.
enum MemoryInfo {
    struct Snapshot {
        let footprintMB: Double
        let peakMB: Double
        let availableMB: Double
    }

    static func snapshot() -> Snapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = 1_048_576.0
        let avail = Double(os_proc_available_memory()) / mb
        guard kr == KERN_SUCCESS else { return Snapshot(footprintMB: -1, peakMB: -1, availableMB: avail) }
        return Snapshot(
            footprintMB: (Double(info.phys_footprint) / mb).rounded(to: 1),
            peakMB: (Double(info.ledger_phys_footprint_peak) / mb).rounded(to: 1),
            availableMB: avail.rounded(to: 1)
        )
    }
}

extension Double {
    func rounded(to places: Int) -> Double {
        let p = pow(10.0, Double(places))
        return (self * p).rounded() / p
    }
}
