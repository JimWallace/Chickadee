// Tests/TestSupport/WedgeWatchdog+Processes.swift
//
// The two questions the per-thread table cannot answer (docs/ci-flakiness.md,
// Family 6). A thread parked in `read(2)` on a pipe waits for EOF, and EOF
// comes only when EVERY process holding the write end has closed it — so the
// dump names those processes. And the stalls involved child processes that
// never exited, so the dump shows each child's own threads as well.
//
// Linux only, like the thread table: everything here reads `/proc`.

import Foundation

extension WedgeWatchdog {
    /// For each thread of this process blocked in `read(2)` on a pipe, every
    /// OTHER process that holds that pipe open.
    static func pipeHolderReport(threadSyscalls: [(tid: String, syscall: String)]) -> String {
        var lines: [String] = []
        for (tid, syscall) in threadSyscalls {
            let fields = syscall.split(separator: " ")
            // Syscall 0 is read on x86_64; its first argument is the descriptor.
            guard fields.count > 1, fields[0] == "0",
                let descriptor = Int(fields[1].dropFirst(2), radix: 16),
                let target = link("/proc/self/fd/\(descriptor)"), target.hasPrefix("pipe:")
            else { continue }
            let holders = processesHolding(target).filter { $0 != getpid() }
            let named = holders.map { describeProcess($0) }.joined(separator: "; ")
            lines.append(
                "  tid \(tid) reads fd \(descriptor) (\(target)); also held by: "
                    + (named.isEmpty ? "no other process" : named))
        }
        guard !lines.isEmpty else { return "" }
        return "pipes being read, and who else holds them:\n" + lines.joined(separator: "\n") + "\n"
    }

    /// Every child of this process, with each of its threads' state, kernel
    /// wait and syscall.
    static func childProcessReport() -> String {
        let me = getpid()
        var report = ""
        for pid in allProcessIDs() where parentOf(pid) == me {
            report += "child \(describeProcess(pid)):\n"
            let taskDir = "/proc/\(pid)/task"
            let tids = (try? FileManager.default.contentsOfDirectory(atPath: taskDir)) ?? []
            for tid in tids.sorted(by: { (Int($0) ?? 0) < (Int($1) ?? 0) }) {
                let wchan = procText("\(taskDir)/\(tid)/wchan") ?? "?"
                let syscall = procText("\(taskDir)/\(tid)/syscall") ?? "?"
                let comm = procText("\(taskDir)/\(tid)/comm") ?? "?"
                report += "    tid \(tid) wchan=\(wchan) syscall=\(syscall) comm=\(comm)\n"
            }
        }
        return report.isEmpty ? "" : "child processes:\n" + report
    }

    // MARK: - /proc helpers

    private static func allProcessIDs() -> [Int32] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap(Int32.init)
    }

    private static func processesHolding(_ target: String) -> [Int32] {
        allProcessIDs().filter { pid in
            let directory = "/proc/\(pid)/fd"
            let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return descriptors.contains { link("\(directory)/\($0)") == target }
        }
    }

    private static func parentOf(_ pid: Int32) -> Int32? {
        guard let stat = procText("/proc/\(pid)/stat"), let closingParen = stat.lastIndex(of: ")") else {
            return nil
        }
        let fields = stat[stat.index(after: closingParen)...].split(separator: " ")
        return fields.count > 1 ? Int32(fields[1]) : nil
    }

    /// `pid (comm) parent=… cmdline` with the command line cut to one line.
    private static func describeProcess(_ pid: Int32) -> String {
        let comm = procText("/proc/\(pid)/comm") ?? "?"
        let commandLine = (procText("/proc/\(pid)/cmdline") ?? "")
            .replacingOccurrences(of: "\0", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let parent = parentOf(pid).map(String.init) ?? "?"
        return "\(pid) (\(comm)) parent=\(parent) \(commandLine.prefix(160))"
    }

    private static func link(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    private static func procText(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
