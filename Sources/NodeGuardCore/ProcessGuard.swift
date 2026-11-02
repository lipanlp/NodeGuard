import Foundation
import Darwin
import CProcess

public struct ProcessIdentity: Equatable {
    public let pid: Int32
    public let path: String
    public let arguments: [String]
    public init(pid: Int32, path: String, arguments: [String]) { self.pid = pid; self.path = path; self.arguments = arguments }
}

public enum ProcessGuard {
    public static let claudeAppPath = "/Applications/Claude.app"
    public static func identity(_ pid: Int32) -> ProcessIdentity? {
        guard pid > 1, ng_owned_process(pid) == 1 else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard ng_process_path(pid, &path, Int32(path.count)) > 0 else { return nil }
        var args = [CChar](repeating: 0, count: 65536)
        let count = ng_process_arguments(pid, &args, Int32(args.count))
        let argv = count > 0 ? args.prefix(Int(count)).split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) } : []
        return ProcessIdentity(pid: pid, path: String(cString: path), arguments: argv)
    }
    public static func isClaude(_ process: ProcessIdentity) -> Bool { process.path.hasPrefix(claudeAppPath + "/Contents/") }
    public static func processes() -> [ProcessIdentity] {
        var ids = [Int32](repeating: 0, count: 32768)
        let count = ng_process_ids(&ids, Int32(ids.count))
        guard count > 0 else { return [] }
        return ids.prefix(min(Int(count), ids.count)).compactMap { pid in
            var path = [CChar](repeating: 0, count: 4096)
            guard ng_process_path(pid, &path, Int32(path.count)) > 0, String(cString: path).hasPrefix(claudeAppPath + "/Contents/") else { return nil }
            return identity(pid)
        }
    }
    public static func monitoredPathPrefixes() -> [String] { [claudeAppPath] }
    @discardableResult public static func terminateClaude() -> (ended: Int, failed: Int) {
        terminateVerified(processes(), readIdentity: identity, sendSignal: { Darwin.kill($0, SIGKILL) })
    }
    public static func terminateVerified(_ targets: [ProcessIdentity], readIdentity: (Int32) -> ProcessIdentity?, sendSignal: (Int32) -> Int32) -> (ended: Int, failed: Int) {
        var ended = 0; var failed = 0
        for target in targets {
            // Re-read PID identity immediately before signalling to avoid PID reuse and broad pkill.
            guard isClaude(target), let fresh = readIdentity(target.pid), fresh == target else { continue }
            if sendSignal(target.pid) == 0 { ended += 1 } else { failed += 1 }
        }
        return (ended, failed)
    }
}
