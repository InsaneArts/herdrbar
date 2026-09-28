import AppKit
import Darwin

/// A herdr TUI client attached to this Mac's default session, and the terminal app that hosts it.
struct HerdrClient: Equatable, Sendable {
    var pid: pid_t
    var tty: String?
    var environment: [String: String]
    var hostPID: pid_t?
    var hostBundleID: String?
}

enum ClientLocator {
    struct ProcessEntry: Equatable, Sendable {
        var pid: pid_t
        var ppid: pid_t
        var command: String
        var tty: String?
    }

    /// Local herdr clients of `session`, newest first.
    @MainActor static func localClients(session: String = "default") -> [HerdrClient] {
        let table = processTable()
        return table.values
            .filter { $0.command == "herdr" }
            .compactMap { process -> HerdrClient? in
                guard let args = arguments(of: process.pid), isLocalClient(argv: args.argv, session: session) else { return nil }
                let host = hostApp(of: process.pid, in: table)
                return HerdrClient(pid: process.pid, tty: process.tty, environment: args.environment,
                                   hostPID: host?.processIdentifier, hostBundleID: host?.bundleIdentifier)
            }
            .sorted { $0.pid > $1.pid }
    }

    /// A client is `herdr`, `herdr --session <name>`, or `herdr session attach <name>` for this session.
    /// Everything else (`herdr server`, `herdr agent list`, `--remote`, `--machine`) is not. Matching what a
    /// client looks like, instead of excluding subcommands, keeps working when herdr adds commands.
    static func isLocalClient(argv: [String], session: String = "default") -> Bool {
        var words: [String] = []
        var name = "default"
        var rest = argv.dropFirst()[...]
        while let argument = rest.popFirst() {
            switch argument {
            case "--remote", "--machine": return false
            case "--session": name = rest.popFirst() ?? ""
            case "--remote-keybindings": _ = rest.popFirst()
            case _ where argument.hasPrefix("--session="): name = String(argument.dropFirst("--session=".count))
            case _ where argument.hasPrefix("-"): continue
            default: words.append(argument)
            }
        }
        if words.count == 3, words[0] == "session", words[1] == "attach" {
            name = words[2]
            words = []
        }
        return words.isEmpty && name == session
    }

    /// Walks up from the client to the first regular app. `/usr/bin/login` sits between the terminal and the
    /// shell and belongs to root, so the walk uses the kernel's process table rather than per-process calls.
    @MainActor static func hostApp(of pid: pid_t, in table: [pid_t: ProcessEntry]) -> NSRunningApplication? {
        var current = table[pid]?.ppid
        for _ in 0..<16 {
            guard let parent = current, parent > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular { return app }
            current = table[parent]?.ppid
        }
        return nil
    }

    static func processTable() -> [pid_t: ProcessEntry] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [:] }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { return [:] }

        var table: [pid_t: ProcessEntry] = [:]
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let command = withUnsafeBytes(of: process.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let device = process.kp_eproc.e_tdev
            let tty = device == -1 ? nil : devname(device, S_IFCHR).map { "/dev/" + String(cString: $0) }
            table[process.kp_proc.p_pid] = ProcessEntry(pid: process.kp_proc.p_pid, ppid: process.kp_eproc.e_ppid,
                                                        command: command, tty: tty)
        }
        return table
    }

    /// argv and the launch environment, from KERN_PROCARGS2: argc, the executable path, padding, then
    /// NUL-separated argv and environment strings.
    static func arguments(of pid: pid_t) -> (argv: [String], environment: [String: String])? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    static func parseProcArgs(_ buffer: [UInt8]) -> (argv: [String], environment: [String: String])? {
        guard buffer.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < buffer.count, buffer[index] != 0 { index += 1 }  // executable path
        while index < buffer.count, buffer[index] == 0 { index += 1 }  // padding
        var strings: [String] = []
        var start = index
        while index < buffer.count {
            if buffer[index] == 0 {
                if index == start { break }  // an empty string ends the environment
                strings.append(String(decoding: buffer[start..<index], as: UTF8.self))
                start = index + 1
            }
            index += 1
        }
        guard strings.count >= argc else { return nil }
        var environment: [String: String] = [:]
        for entry in strings.dropFirst(argc) {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (Array(strings.prefix(argc)), environment)
    }
}
