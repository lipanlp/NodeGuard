import Foundation
import NodeGuardCore

private func v42Snapshot(host: String?, chain: [String] = ["DIRECT"], path: String = "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper") throws -> CoreSnapshot {
    let base = try fixture(); var metadata: [String: Any] = ["processPath": path, "process": "Claude Helper", "destinationIP": "198.51.100.10", "sourcePort": "43210"]
    if let host = host { metadata["host"] = host }
    let json: [String: Any] = ["connections": [["id": "regression-embedded-browser", "metadata": metadata, "chains": chain, "upload": 0, "download": 0]]]
    let connection = try JSONDecoder().decode(ConnectionsEnvelope.self, from: JSONSerialization.data(withJSONObject: json))
    return CoreSnapshot(proxies: base.proxies, connections: connection.connections, config: base.config)
}
func runV42Cases() {
    var options = GuardSettings(); options.allowedClaudeIPs = ["203.0.113.8"]; options.strictProtection = true
    let monitored = ProcessGuard.monitoredPathPrefixes()
    test("v0.4.2 embedded browser third-party website DIRECT does not trigger Claude protection") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: "preview.example.org"), settings: options, claudePaths: monitored) == nil
    }
    test("third-party browser websites may follow other proxy groups") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: "preview.example.org", chain: ["普通节点", "网站策略"]), settings: options, claudePaths: monitored) == nil
    }
    test("the reported third-party browsing scenario sends no signals to any of six Claude processes") {
        let snapshot = try v42Snapshot(host: "preview.example.org")
        let identities = (0..<6).map { ProcessIdentity(pid: Int32(50100 + $0), path: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: []) }
        var sent: [Int32] = []
        if ProtectionPolicy.topologyViolation(snapshot: snapshot, settings: options, claudePaths: monitored) != nil {
            _ = ProcessGuard.terminateVerified(identities, readIdentity: { pid in identities.first { $0.pid == pid } }, sendSignal: { sent.append($0); return 0 })
        }
        return sent.isEmpty
    }
    test("Claude website DIRECT bypass still triggers protection") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: "claude.ai"), settings: options, claudePaths: monitored) != nil
    }
    test("Anthropic API DIRECT bypass still triggers protection") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: "api.anthropic.com"), settings: options, claudePaths: monitored) != nil
    }
    test("Claude platform and bridge endpoints stay in protected scope") {
        ClaudeServiceScope.contains("platform.claude.com") && ClaudeServiceScope.contains("bridge.claudeusercontent.com")
    }
    test("service domains normalize DNS case whitespace and a terminal dot") {
        ClaudeServiceScope.contains(" API.Anthropic.COM. ") && ClaudeServiceScope.contains("CLAUDE.AI.")
    }
    test("service-like third-party names cannot expand strict service scope") {
        ["claude.ai.evil.example", "notanthropic.com", "claude.com@evil.example", "https://claude.ai", "evilclaudeusercontent.com"].allSatisfy { !ClaudeServiceScope.contains($0) }
    }
    test("empty host and literal public IP are not attributed to a Claude service by process ownership alone") {
        !ClaudeServiceScope.contains(nil) && !ClaudeServiceScope.contains("") && !ClaudeServiceScope.contains("198.51.100.10")
    }
    test("unattributed public requests do not become a confirmed Claude route violation") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: nil), settings: options, claudePaths: monitored) == nil
    }
    test("ordinary developer websites remain outside protected service scope") {
        ["preview.example.org", "github.com", "registry.npmjs.org", "chatgpt.com"].allSatisfy { !ClaudeServiceScope.contains($0) }
    }
    test("valid Claude service proxy route remains accepted") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: "api.anthropic.com", chain: ["Comcast住宅", "Claude专线"]), settings: options, claudePaths: monitored) == nil
    }
    test("third-party browsing cannot mask a simultaneous real Claude API bypass") {
        let web = try v42Snapshot(host: "preview.example.org"); let api = try v42Snapshot(host: "api.anthropic.com")
        let mixed = CoreSnapshot(proxies: web.proxies, connections: web.connections + api.connections, config: web.config)
        return ProtectionPolicy.topologyViolation(snapshot: mixed, settings: options, claudePaths: monitored) != nil
    }
    test("real service bypass still reaches the injected actuator and never sends a real signal") {
        let s = try v42Snapshot(host: "api.anthropic.com"); let p = ProcessIdentity(pid: 50200, path: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: [])
        var sent: [Int32] = []
        if ProtectionPolicy.topologyViolation(snapshot: s, settings: options, claudePaths: monitored) != nil { _ = ProcessGuard.terminateVerified([p], readIdentity: { _ in p }, sendSignal: { sent.append($0); return 0 }) }
        return sent == [50200]
    }
    test("requests from other applications do not enter Claude process protection") {
        try ProtectionPolicy.topologyViolation(snapshot: v42Snapshot(host: "claude.ai", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"), settings: options, claudePaths: monitored) == nil
    }
    test("IP deviation and mainland exit checks are preserved") {
        ProtectionPolicy.exitViolation(ExitObservation(ip: "203.0.113.9", country: "US", seconds: 1), allowedIPs: options.allowedClaudeIPs) != nil && ProtectionPolicy.exitViolation(ExitObservation(ip: "203.0.113.8", country: "CN", seconds: 1), allowedIPs: options.allowedClaudeIPs) != nil
    }
    test("unverified strict deadline remains twelve seconds rather than being weakened to hide probe alerts") {
        let now = Date(); var machine = StrictProtectionMachine(); machine.verified(at: now); machine.failed(.timeout, now: now)
        _ = machine.evaluate(grace: 12, now: now.addingTimeInterval(11)); let early = machine.needsNetworkRecovery
        _ = machine.evaluate(grace: 12, now: now.addingTimeInterval(12))
        return !early && machine.needsNetworkRecovery && machine.phase == .holding
    }
    if let i = CommandLine.arguments.firstIndex(of: "--cancel-proxy-port"), CommandLine.arguments.count > i + 1, let port = Int(CommandLine.arguments[i + 1]) {
        test("connection deadline is forwarded to real curl instead of being capped at the old fixed budget") {
            let started = Date()
            do { _ = try Probe.curl(url: "https://example.invalid/", port: port, timeout: 2, connectionTimeout: 0.7); return false }
            catch let e as ProbeFailure { let elapsed = Date().timeIntervalSince(started); return e.code == 28 && elapsed >= 0.6 && elapsed < 1.6 }
        }
        test("a connection budget cannot extend the total transfer deadline") {
            let started = Date()
            do { _ = try Probe.curl(url: "https://example.invalid/", port: port, timeout: 0.3, connectionTimeout: 2); return false }
            catch let e as ProbeFailure { return e.code == 28 && Date().timeIntervalSince(started) < 1.2 }
        }
    }
}
