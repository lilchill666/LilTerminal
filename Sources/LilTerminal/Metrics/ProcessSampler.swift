import Foundation
import Darwin

/// Resource usage for one session, aggregated over the shell and every
/// descendant it has spawned.
struct SessionMetrics: Equatable {
    var cpuPercent: Double = 0      // 100.0 == one core saturated
    var residentBytes: UInt64 = 0
    var processCount: Int = 0
    /// Name of the busiest descendant, used as the "what is this tab doing" label.
    var foregroundCommand: String?
    /// The shell's actual working directory.
    ///
    /// Read from the process rather than waiting for the shell to report it:
    /// macOS only wires up OSC 7 when `TERM_PROGRAM` is `Apple_Terminal`, so
    /// any other terminal never hears about a `cd` at all.
    var workingDirectory: String?

    static let zero = SessionMetrics()
}

/// One process as libproc sees it.
private struct ProcSnapshot {
    var ppid: pid_t
    var rss: UInt64
    var cpuNanos: UInt64
    var command: String
}

/// Samples the whole process table on a background queue and attributes usage
/// to sessions by walking each session's descendant tree.
///
/// Design note: one full `proc_listallpids` sweep per tick serves *all* tabs.
/// Per-tab `proc_listchildpids` recursion would re-walk overlapping subtrees
/// and cost O(tabs x depth) syscalls; this is O(total processes), once.
final class ProcessSampler {
    /// CPU is a rate, so it needs the previous sample to differentiate against.
    private var previousCPU: [pid_t: UInt64] = [:]
    private var previousSampleTime: DispatchTime?

    private let queue = DispatchQueue(label: "app.lilterminal.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Called on the main queue with metrics keyed by the pid that was requested.
    var onSample: (([pid_t: SessionMetrics]) -> Void)?

    /// Supplies the set of session root pids to measure. Read on the sampler queue.
    var rootProvider: (() -> [pid_t])?

    func start(interval: TimeInterval = 1.0) {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard let roots = rootProvider?(), !roots.isEmpty else { return }

        let now = DispatchTime.now()
        let elapsedNanos: Double
        if let prev = previousSampleTime {
            elapsedNanos = Double(now.uptimeNanoseconds - prev.uptimeNanoseconds)
        } else {
            elapsedNanos = 0   // first tick has no baseline; CPU reads as 0
        }
        previousSampleTime = now

        let table = snapshotProcessTable()

        // Invert to a child index so descendant walks are O(subtree), not O(n) each.
        var childrenOf: [pid_t: [pid_t]] = [:]
        childrenOf.reserveCapacity(table.count)
        for (pid, info) in table {
            childrenOf[info.ppid, default: []].append(pid)
        }

        var results: [pid_t: SessionMetrics] = [:]
        var currentCPU: [pid_t: UInt64] = [:]
        currentCPU.reserveCapacity(table.count)

        for root in roots {
            guard table[root] != nil else {
                results[root] = .zero      // shell already exited
                continue
            }

            var metrics = SessionMetrics()
            var busiestDelta: UInt64 = 0

            // Iterative DFS: a deeply nested pipeline should not risk the stack.
            var stack: [pid_t] = [root]
            var visited = Set<pid_t>()

            while let pid = stack.popLast() {
                guard visited.insert(pid).inserted, let info = table[pid] else { continue }
                stack.append(contentsOf: childrenOf[pid] ?? [])

                metrics.processCount += 1
                metrics.residentBytes += info.rss
                currentCPU[pid] = info.cpuNanos

                // A pid that vanished and was recycled could report a negative
                // delta; clamping to zero is correct and keeps the rate sane.
                let delta = info.cpuNanos &- (previousCPU[pid] ?? info.cpuNanos)
                let safeDelta = info.cpuNanos >= (previousCPU[pid] ?? info.cpuNanos) ? delta : 0

                if elapsedNanos > 0 {
                    metrics.cpuPercent += Double(safeDelta) / elapsedNanos * 100.0
                }

                // The shell itself is never the interesting label; a child is.
                if pid != root, safeDelta >= busiestDelta {
                    busiestDelta = safeDelta
                    metrics.foregroundCommand = info.command
                }
            }

            // With no busy child, fall back to naming any direct child at all —
            // a blocked `ssh` burns no CPU but is still what the tab is doing.
            if metrics.foregroundCommand == nil,
               let anyChild = childrenOf[root]?.first, let info = table[anyChild] {
                metrics.foregroundCommand = info.command
            }

            metrics.workingDirectory = Self.workingDirectory(of: root)
            results[root] = metrics
        }

        previousCPU = currentCPU

        DispatchQueue.main.async { [onSample] in
            onSample?(results)
        }
    }

    /// The current directory of a process, or nil if it cannot be read.
    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    /// Reads every visible process once. Processes we lack permission to
    /// inspect are skipped rather than treated as an error.
    private func snapshotProcessTable() -> [pid_t: ProcSnapshot] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [:] }

        // Pad: the table can grow between the sizing call and the read.
        var pids = [pid_t](repeating: 0, count: Int(count) + 128)
        let byteSize = Int32(pids.count * MemoryLayout<pid_t>.size)
        let returned = proc_listallpids(&pids, byteSize)
        guard returned > 0 else { return [:] }

        var table: [pid_t: ProcSnapshot] = [:]
        table.reserveCapacity(Int(returned))

        let infoSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        for index in 0..<Int(returned) {
            let pid = pids[index]
            guard pid > 0 else { continue }

            var info = proc_taskallinfo()
            let ok = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &info, infoSize)
            guard ok == infoSize else { continue }   // exited or not permitted

            let command = withUnsafeBytes(of: info.pbsd.pbi_comm) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }

            table[pid] = ProcSnapshot(
                ppid: pid_t(info.pbsd.pbi_ppid),
                rss: info.ptinfo.pti_resident_size,
                cpuNanos: info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system,
                command: command
            )
        }
        return table
    }
}

enum Format {
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        // Sub-10 values get a decimal so a tab's number does not visibly jump
        // between 1 GB and 2 GB with nothing in between.
        return size < 10 && unit > 1
            ? String(format: "%.1f %@", size, units[unit])
            : String(format: "%.0f %@", size, units[unit])
    }

    static func cpu(_ percent: Double) -> String {
        percent < 1 ? "0%" : String(format: "%.0f%%", percent)
    }
}
