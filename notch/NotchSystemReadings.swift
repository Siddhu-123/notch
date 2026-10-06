// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
// Modified for Notch, 2026-10-05: public CPU/RAM readings only; on-demand lifecycle.
// Adapted from vorssaint/vorssaint-utils @ 3c10e1bd30101499135fa5d7591f2d3c5af4cd17:
// Sources/Vorssaint/Services/SystemMonitor/SystemMonitor.swift (CPU delta sampling)
// Sources/Vorssaint/Services/Metrics/MetricFormat.swift (app/wired/compressed memory).

import Combine
import Darwin
import Foundation

struct NotchCPUTicks: Sendable {
    let busy: UInt64
    let total: UInt64
    let uptime: TimeInterval
}

enum NotchSystemReadingMath {
    /// A launch, reset, or sleep gap supplies a new baseline, not a load average.
    static func cpuPercent(previous: NotchCPUTicks?, current: NotchCPUTicks) -> Double? {
        guard let previous,
              current.uptime > previous.uptime,
              current.uptime - previous.uptime <= 12.5,
              current.total > previous.total,
              current.busy >= previous.busy else { return nil }
        let elapsed = current.total - previous.total
        let busy = current.busy - previous.busy
        guard busy <= elapsed else { return nil }
        return Double(busy) / Double(elapsed) * 100
    }

    /// Estimated used RAM: nonpurgeable internal, wired, and compressor pages.
    /// Reserved tagged-storage memory on newer kernels is not included.
    static func usedMemory(totalBytes: UInt64, pageSize: UInt64,
                           internalPages: UInt64, purgeablePages: UInt64,
                           wiredPages: UInt64, compressedPages: UInt64) -> UInt64? {
        guard totalBytes > 0, pageSize > 0 else { return nil }
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        let appAndWired = appPages.addingReportingOverflow(wiredPages)
        guard !appAndWired.overflow else { return nil }
        let pages = appAndWired.partialValue.addingReportingOverflow(compressedPages)
        guard !pages.overflow else { return nil }
        let bytes = pages.partialValue.multipliedReportingOverflow(by: pageSize)
        guard !bytes.overflow else { return nil }
        return min(bytes.partialValue, totalBytes)
    }
}

@MainActor
final class NotchSystemReadings: ObservableObject {
    @Published private(set) var cpuPercent: Double?
    @Published private(set) var usedMemoryBytes: UInt64?
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var lastError: String?
    let totalMemoryBytes = ProcessInfo.processInfo.physicalMemory

    private var timer: Timer?
    private var previousTicks: NotchCPUTicks?
    private var generation = 0
    private var sampleInFlight = false

    func start() {
        guard timer == nil else { return }
        generation &+= 1
        let next = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sample() }
        }
        next.tolerance = 0.3
        RunLoop.main.add(next, forMode: .common)
        timer = next
        sample()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation &+= 1
        sampleInFlight = false
        previousTicks = nil
        cpuPercent = nil
        usedMemoryBytes = nil
        lastError = nil
    }

    deinit { timer?.invalidate() }

    private func sample() {
        guard timer != nil, !sampleInFlight else { return }
        sampleInFlight = true
        let sampledGeneration = generation
        let total = totalMemoryBytes
        Task.detached(priority: .utility) { [weak self] in
            let reading = Self.readSnapshot(totalBytes: total)
            await self?.apply(reading, generation: sampledGeneration)
        }
    }

    private func apply(_ reading: Snapshot, generation: Int) {
        guard timer != nil, generation == self.generation else { return }
        sampleInFlight = false
        if let ticks = reading.cpu {
            cpuPercent = NotchSystemReadingMath.cpuPercent(previous: previousTicks, current: ticks)
            previousTicks = ticks
            if let cpuPercent {
                cpuHistory.append(cpuPercent)
                if cpuHistory.count > 30 { cpuHistory.removeFirst(cpuHistory.count - 30) }
            }
        } else {
            previousTicks = nil
            cpuPercent = nil
        }
        usedMemoryBytes = reading.memory
        lastError = reading.cpu == nil || reading.memory == nil ? "Some system readings are unavailable." : nil
    }

    private struct Snapshot: Sendable {
        var cpu: NotchCPUTicks?
        var memory: UInt64?
    }

    nonisolated private static func readSnapshot(totalBytes: UInt64) -> Snapshot {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var snapshot = Snapshot()
        var cpu = host_cpu_load_info_data_t()
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let cpuResult = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount)
            }
        }
        if cpuResult == KERN_SUCCESS {
            let busy = UInt64(cpu.cpu_ticks.0) + UInt64(cpu.cpu_ticks.1) + UInt64(cpu.cpu_ticks.3)
            snapshot.cpu = NotchCPUTicks(busy: busy, total: busy + UInt64(cpu.cpu_ticks.2),
                                         uptime: ProcessInfo.processInfo.systemUptime)
        }

        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &vmCount)
            }
        }
        var pageSize: vm_size_t = 0
        // Darwin's sizeof/offsetof count macros are not imported into Swift.
        // Anchor the required prefix to the final rev1 field in the imported C layout.
        guard let rev1End = MemoryLayout<vm_statistics64_data_t>.offset(of: \.total_uncompressed_pages_in_compressor) else {
            return snapshot
        }
        let requiredCount = mach_msg_type_number_t((rev1End + MemoryLayout<UInt64>.size) / MemoryLayout<integer_t>.stride)
        if vmResult == KERN_SUCCESS, vmCount >= requiredCount,
           host_page_size(host, &pageSize) == KERN_SUCCESS {
            snapshot.memory = NotchSystemReadingMath.usedMemory(
                totalBytes: totalBytes, pageSize: UInt64(pageSize),
                internalPages: UInt64(vm.internal_page_count), purgeablePages: UInt64(vm.purgeable_count),
                wiredPages: UInt64(vm.wire_count), compressedPages: UInt64(vm.compressor_page_count))
        }
        return snapshot
    }
}
