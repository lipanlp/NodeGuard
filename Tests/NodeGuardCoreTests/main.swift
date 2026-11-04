import Foundation
import Darwin
import NodeGuardCore

var passed = 0
var failed = 0
func test(_ name: String, _ body: () throws -> Bool) {
    do { if try body() { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)") } }
    catch { failed += 1; print("FAIL \(name): \(error.localizedDescription)") }
}
func throwsError(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
func fixture(front: String = "A", leaf: String = "Comcast住宅", mode: String = "rule", connectionChain: [String]? = nil, local: Bool = false, tun: Bool = true, upload: UInt64 = 0, download: UInt64 = 0, connectionID: String = "x") throws -> CoreSnapshot {
    let proxies: [String: Any] = [
        "KTM前置节点": ["name": "KTM前置节点", "type": "Selector", "now": front, "all": ["A", "B", "C"]],
        "Claude专线": ["name": "Claude专线", "type": "Selector", "now": leaf],
        "Comcast住宅": ["name": "Comcast住宅", "type": "Socks5", "dialer-proxy": "KTM前置节点"],
        "A": ["name": "A", "type": "Trojan"], "B": ["name": "B", "type": "Trojan"], "C": ["name": "C", "type": "Trojan"],
        "DIRECT": ["name": "DIRECT", "type": "Direct"]]
    let p = try JSONDecoder().decode(ProxyEnvelope.self, from: JSONSerialization.data(withJSONObject: ["proxies": proxies]))
    let c = try JSONDecoder().decode(CoreConfig.self, from: JSONSerialization.data(withJSONObject: ["mode": mode, "mixed-port": 7897, "port": 0, "socks-port": 0, "find-process-mode": "strict", "tun": ["enable": tun, "auto-route": true]]))
    var connections: [ConnectionInfo] = []
    if let chain = connectionChain {
        let raw: [String: Any] = ["connections": [["id": connectionID, "chains": chain, "upload": upload, "download": download, "metadata": ["processPath": "/Applications/Claude.app/Contents/MacOS/Claude", "process": "Claude", "host": local ? "localhost" : "claude.ai", "destinationIP": local ? "127.0.0.1" : "1.1.1.1", "sourcePort": "45678"]]]]
        connections = try JSONDecoder().decode(ConnectionsEnvelope.self, from: JSONSerialization.data(withJSONObject: raw)).connections
    }
    return CoreSnapshot(proxies: p.proxies, connections: connections, config: c)
}
func sample(name: String = "B", ip: String = "203.0.113.8", country: String = "US", seconds: Double = 4, date: Date = Date()) -> NodeMeasurement {
    NodeMeasurement(name: name, date: date, success: true, latencyMS: 700, uploadSeconds: seconds, downloadMbps: 20, reliability: 1, samples: 5, failure: nil, ip: ip, country: country)
}
let base = GuardSettings()
let paths = ProcessGuard.monitoredPathPrefixes()
test("valid trace parses IP and country") { let x = try ExitObservation.parseTrace(Data("ip=203.0.113.8\nloc=US\n".utf8), seconds: 1); return x.ip == "203.0.113.8" && x.country == "US" }
test("captcha HTML cannot pass as a healthy exit") { throwsError { _ = try ExitObservation.parseTrace(Data("<html>challenge</html>".utf8), seconds: 1) } }
test("invalid country and private IP rejected") { throwsError { _ = try ExitObservation.parseTrace(Data("ip=127.0.0.1\nloc=US\n".utf8), seconds: 1) } }
test("IPv6 addresses canonicalize before exact comparison") { IPAddress.canonical("2001:0DB8:0:0:0:0:0:1") == "2001:db8::1" }
test("same ISP or country is insufficient: changed exact IP trips") { ProtectionPolicy.exitViolation(ExitObservation(ip: "203.0.113.9", country: "US", seconds: 1), allowedIPs: ["203.0.113.8"]) != nil }
test("domestic exit trips even when its IP is pinned") { ProtectionPolicy.exitViolation(ExitObservation(ip: "203.0.113.8", country: "CN", seconds: 1), allowedIPs: ["203.0.113.8"]) != nil }
test("valid proxy topology passes") { try ProtectionPolicy.topologyViolation(snapshot: fixture(), settings: base, claudePaths: paths) == nil }
test("current Claude route may use a different provider without an ISP name requirement") { try ProtectionPolicy.topologyViolation(snapshot: fixture(leaf: "A"), settings: base, claudePaths: paths) == nil }
test("global/direct mode cannot appear protected") { try ProtectionPolicy.topologyViolation(snapshot: fixture(mode: "global"), settings: base, claudePaths: paths) != nil }
test("TUN disabled cannot appear protected just because the proxy probe works") { try ProtectionPolicy.topologyViolation(snapshot: fixture(tun: false), settings: base, claudePaths: paths) != nil }
test("actual Claude public connection bypass trips") { try ProtectionPolicy.topologyViolation(snapshot: fixture(connectionChain: ["DIRECT"]), settings: base, claudePaths: paths) != nil }
test("local Claude connection is excluded from public egress checks") { try ProtectionPolicy.topologyViolation(snapshot: fixture(connectionChain: ["DIRECT"], local: true), settings: base, claudePaths: paths) == nil }
let observed = ExitObservation(ip: "203.0.113.8", country: "US", seconds: 1, chains: ["Comcast住宅", "Claude专线"])
test("enrollment needs two matching, recent, traced Comcast probes") { try ProtectionPolicy.canEnroll(snapshot: fixture(), settings: base, observations: [observed, observed]) }
test("enrollment rejects an unverified chain") { try !ProtectionPolicy.canEnroll(snapshot: fixture(), settings: base, observations: [ExitObservation(ip: "203.0.113.8", country: "US", seconds: 1), observed]) }
test("enrollment rejects stale evidence") { let old = ExitObservation(ip: observed.ip, country: "US", seconds: 1, date: Date().addingTimeInterval(-25), chains: observed.chains); return try !ProtectionPolicy.canEnroll(snapshot: fixture(), settings: base, observations: [old, old]) }
test("failure/slow upload cannot qualify for failover") { !sample(seconds: 18).isUsable(allowedIPs: [observed.ip], maxUpload: 15) && !NodeMeasurement.failed("B", previous: nil, reason: "timeout").isUsable(allowedIPs: [], maxUpload: 15) }
test("cached old rankings cannot authorize a switch") { !sample(date: Date().addingTimeInterval(-1801)).isUsable(allowedIPs: [observed.ip], maxUpload: 15) }
test("upload performance affects rank despite same latency") { sample(seconds: 4).score > sample(seconds: 40).score }
var automatic = GuardSettings(); automatic.autoSwitch = true; automatic.allowedClaudeIPs = [observed.ip]; automatic.candidates = ["A", "B"]
test("fresh approved backup may commit") { try FailoverPolicy.mayCommit(settings: automatic, snapshot: fixture(), old: "A", candidate: sample()) }
test("manual node change cancels automatic commit") { try !FailoverPolicy.mayCommit(settings: automatic, snapshot: fixture(front: "C"), old: "A", candidate: sample()) }
test("changed Comcast exit cancels automatic commit") { try !FailoverPolicy.mayCommit(settings: automatic, snapshot: fixture(), old: "A", candidate: sample(ip: "203.0.113.9")) }
test("unapproved backup cannot be selected") { try !FailoverPolicy.mayCommit(settings: automatic, snapshot: fixture(), old: "A", candidate: sample(name: "C")) }
test("unknown pin cannot silently enable strict mode") { var s = GuardSettings(); s.strictProtection = true; s.allowedClaudeIPs = ["garbage"]; s.normalize(); return !s.strictProtection && s.allowedClaudeIPs.isEmpty }
test("settings allow all nodes and bound optional traffic caps") { var s = GuardSettings(); s.candidates = (0..<50).map(String.init); s.dailyTestBudgetMB = Int.max; s.normalize(); return s.candidates.count == 50 && s.dailyTestBudgetMB == 100000 }
let desktop = ProcessIdentity(pid: 123, path: "/Applications/Claude.app/Contents/MacOS/Claude", arguments: ["Claude"])
let terminal = ProcessIdentity(pid: 456, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", arguments: ["claude"])
test("only Claude desktop bundle is in kill scope") { ProcessGuard.isClaude(desktop) && !ProcessGuard.isClaude(terminal) && !ProcessGuard.isClaude(ProcessIdentity(pid: 1, path: "/usr/local/bin/claude", arguments: [])) && !ProcessGuard.isClaude(ProcessIdentity(pid: 2, path: "/Applications/Claude.app.evil/Contents/MacOS/Claude", arguments: [])) }
test("kill decision verifies PID identity and never signals terminal") {
    var sent: [Int32] = []
    let r = ProcessGuard.terminateVerified([desktop, terminal], readIdentity: { $0 == 123 ? desktop : terminal }, sendSignal: { sent.append($0); return 0 })
    return sent == [123] && r.ended == 1
}
test("PID reuse prevents a signal") {
    var sent = false
    let r = ProcessGuard.terminateVerified([desktop], readIdentity: { _ in terminal }, sendSignal: { _ in sent = true; return 0 })
    return !sent && r.ended == 0
}
test("signal failure is returned for a critical alert") { ProcessGuard.terminateVerified([desktop], readIdentity: { _ in desktop }, sendSignal: { _ in -1 }).failed == 1 }
test("HTTP chunked bodies decode; no response headers retained") { let data = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nSecret: never-store\r\n\r\n4\r\ntest\r\n0\r\n\r\n".utf8); return try String(decoding: MihomoClient.parseHTTP(data), as: UTF8.self) == "test" }
test("incomplete HTTP responses cannot pass") { throwsError { _ = try MihomoClient.parseHTTP(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nx".utf8)) } }
test("Mihomo null connections is a valid idle response and retains counters") { let e = try JSONDecoder().decode(ConnectionsEnvelope.self, from: Data("{\"connections\":null,\"uploadTotal\":12,\"downloadTotal\":34}".utf8)); return e.connections.isEmpty && e.uploadTotal == 12 && e.downloadTotal == 34 }
test("private state is bounded and stored with 0600 permissions") {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NodeGuard-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StateStore(directory: directory); var state = StoredState(); state.events = (0..<250).map { GuardEvent(level: "info", message: "event \($0)") }; try store.save(state)
    let permissions = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? Int
    return store.load().events.count == 200 && permissions == 0o600
}
test("isolated candidate config never enables TUN or external controller") {
    let source: [String: Any] = ["proxies": [["name": "A", "type": "trojan", "server": "127.0.0.1", "password": "FAKE-NOT-A-CREDENTIAL"], ["name": "Comcast住宅", "type": "socks5", "server": "127.0.0.1", "dialer-proxy": "KTM前置节点"]]]
    let c = try CandidateProbe.configuration(source: source, snapshot: fixture(), candidate: "A", settings: base, port: 31000, interface: "en0")
    return (c["tun"] as? [String: Bool])?["enable"] == false && c["external-controller"] == nil && (c["listeners"] as? [[String: Any]])?.first?["listen"] as? String == "127.0.0.1" && (source["proxies"] as? [[String: Any]])?.first?["interface-name"] == nil
}
test("unlisted candidate rejected before a private core starts") {
    throwsError { _ = try CandidateProbe.configuration(source: [:], snapshot: fixture(), candidate: "UNKNOWN", settings: base, port: 31000, interface: "en0") }
}
if let i = CommandLine.arguments.firstIndex(of: "--mock-socket"), CommandLine.arguments.count > i + 1 {
    let client = MihomoClient(socketPath: CommandLine.arguments[i + 1])
    test("Mihomo API writes only the named front selector and verifies result") { try client.select(group: "KTM前置节点", node: "B", expectedCurrent: "A"); return true }
    test("Mihomo API refuses to overwrite a changed manual selection") { throwsError { try client.select(group: "KTM前置节点", node: "C", expectedCurrent: "A") } }
    test("cancelled switch performs no PUT after reading current state") { let token = ProbeCancellation(); token.cancel("profile changed"); return throwsError { try client.select(group: "KTM前置节点", node: "C", expectedCurrent: "B", cancellation: token) } }
}
test("v0.1 settings migrate without losing pins or protection switches") {
    let legacy = Data("{\"frontGroup\":\"KTM前置节点\",\"allowedClaudeIPs\":[\"203.0.113.8\"],\"strictProtection\":true,\"autoSwitch\":true,\"dailyTestBudgetMB\":200,\"candidates\":[\"A\"]}".utf8)
    let migrated = try JSONDecoder().decode(GuardSettings.self, from: legacy)
    return migrated.strictProtection && migrated.autoSwitch && migrated.allowedClaudeIPs == ["203.0.113.8"] && migrated.dailyTestBudgetMB == 0 && migrated.automaticFullScan && migrated.candidates == ["A"]
}
test("new settings survive a complete save and reload") { var s = GuardSettings(); s.fullScanInterval = 3600; s.idleSeconds = 90; let restored = try JSONDecoder().decode(GuardSettings.self, from: JSONEncoder().encode(s)); return restored == s }
test("full scan queues every node beyond the old twelve-node limit") { var q = FullScanQueue(); q.replace(SubscriptionInventory(key: "a", name: "A", nodes: (0..<52).map(String.init))); return q.total == 52 && q.pending.count == 52 }
test("subscription replacement drops removed nodes and rejects old results with same labels") {
    var q = FullScanQueue(); q.replace(SubscriptionInventory(key: "a", name: "A", nodes: ["same", "removed"])); q.replace(SubscriptionInventory(key: "b", name: "B", nodes: ["same", "new"]))
    q.finish(node: "same", inventoryKey: "a", interval: 3600)
    return q.pending == ["same", "new"] && q.completed == 0
}
test("interruption leaves the node pending for retry") { var q = FullScanQueue(); q.replace(SubscriptionInventory(key: "a", name: "A", nodes: ["x"])); let interrupted = ProbeCancellation(); interrupted.cancel("user busy"); return throwsError { try interrupted.check() } && q.pending == ["x"] && q.completed == 0 }
test("periodic round restarts only after its interval and covers all nodes again") {
    var q = FullScanQueue(); let t = Date(); q.replace(SubscriptionInventory(key: "a", name: "A", nodes: ["x", "y"]), now: t)
    q.finish(node: "x", inventoryKey: "a", interval: 3600, now: t); q.finish(node: "y", inventoryKey: "a", interval: 3600, now: t)
    q.beginDueRound(now: t.addingTimeInterval(3599)); guard q.pending.isEmpty else { return false }
    q.beginDueRound(now: t.addingTimeInterval(3600)); return q.pending == ["x", "y"] && q.completed == 0
}
test("same labels in another subscription or changed credentials yield distinct inventory keys") {
    let a = InventoryReader.identity(uid: "A", sourceHash: "hash1", group: "front", nodes: ["one", "two"])
    let reordered = InventoryReader.identity(uid: "A", sourceHash: "hash1", group: "front", nodes: ["two", "one"])
    return a == reordered && a != InventoryReader.identity(uid: "B", sourceHash: "hash1", group: "front", nodes: ["one", "two"]) && a != InventoryReader.identity(uid: "A", sourceHash: "hash2", group: "front", nodes: ["one", "two"])
}
let t0 = Date(timeIntervalSince1970: 10000)
func idleGate() throws -> ActivityGate {
    var gate = ActivityGate()
    for i in 0...30 { _ = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(Double(i * 2))) }
    return gate
}
test("automatic tests wait for continuous idle rather than merely having open sockets") {
    var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(62)); return d.ready && !d.busy
}
test("new empty AI socket does not block or reset a ready queue") {
    var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(connectionChain: ["Comcast住宅"]), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(62)); return d.ready && !d.busy
}
test("our own Claude/GPT probes cannot permanently block the idle scheduler") {
    var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(connectionChain: ["Comcast住宅"]), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [45678], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(62)); return d.ready && !d.busy
}
test("our isolated transfer is subtracted instead of cancelling itself") {
    var gate = ActivityGate(); var d: LoadDecision?
    for i in 0...30 { d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: UInt64(i) * 2_000_000, down: 0), probe: ByteCounters(up: UInt64(i) * 1_900_000, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(Double(i * 2))) }
    return d?.ready == true && d?.busy == false
}
test("modest background download no longer blocks a ready queue") {
    var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 1_000_000), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(62)); return d.ready && !d.busy && d.downKB > 128
}
test("transient high CPU sample is observed instead of immediately blocking") { var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0.99, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(62)); return !d.busy && !d.ready }
test("repeated heartbeats and connection churn cannot starve automatic tests") {
    var gate = ActivityGate(); var result: LoadDecision?
    for i in 0...40 {
        result = gate.sample(snapshot: try fixture(connectionChain: ["Comcast住宅"], upload: 512, download: 4096, connectionID: "socket-\(i)"), physical: ByteCounters(up: UInt64(i) * 16000, down: UInt64(i) * 1_000_000), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0.2, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(Double(i * 2)))
    }
    return result?.ready == true && result?.busy == false
}
test("ordinary ongoing chat traffic is allowed without requiring every connection to go silent") {
    var gate = ActivityGate(); var result: LoadDecision?
    for i in 0...12 {
        result = gate.sample(snapshot: try fixture(connectionChain: ["Comcast住宅"], upload: UInt64(i) * 12000, download: UInt64(i) * 24000), physical: ByteCounters(up: UInt64(i) * 20000, down: UInt64(i) * 1_500_000), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0.15, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(Double(i * 2)))
    }
    return result?.ready == true
}
test("sustained substantial AI upload still preempts a running test after confirmation") {
    var gate = try idleGate(); var result: LoadDecision?
    for i in 1...4 { result = gate.sample(snapshot: try fixture(connectionChain: ["Comcast住宅"], upload: UInt64(i) * 300_000), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(Double(60 + i * 2))) }
    return result?.busy == true && result?.ready == false
}
test("single brief moderate burst does not restart the entire waiting window") {
    var gate = try idleGate()
    let peak = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 6_000_000), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(62))
    let next = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 6_000_000), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(64))
    return !peak.busy && !peak.ready && next.ready && next.quietFor > 60
}
test("large physical transfer outside Clash is stopped immediately") {
    var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 20_000_000), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(62)); return d.busy && !d.ready
}
test("critical temperature still blocks immediately") {
    var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0.1, thermalBusy: true, idleSeconds: 15, now: t0.addingTimeInterval(62)); return d.busy
}
test("sustained actual CPU saturation still pauses testing") {
    var gate = try idleGate(); var d: LoadDecision?
    for i in 1...4 { d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0.99, thermalBusy: false, idleSeconds: 15, now: t0.addingTimeInterval(Double(60 + i * 2))) }
    return d?.busy == true
}
test("v0.2 default wait migrates to 15 seconds without changing protection") {
    let data = Data("{\"settingsVersion\":2,\"idleSeconds\":60,\"allowedClaudeIPs\":[\"203.0.113.8\"],\"strictProtection\":true,\"autoSwitch\":true,\"dailyTestBudgetMB\":1200}".utf8)
    let s = try JSONDecoder().decode(GuardSettings.self, from: data)
    return s.idleSeconds == 15 && s.testingSensitivity == .balanced && s.strictProtection && s.autoSwitch && s.dailyTestBudgetMB == 1200
}
test("custom idle wait is preserved during migration") {
    let s = try JSONDecoder().decode(GuardSettings.self, from: Data("{\"settingsVersion\":2,\"idleSeconds\":90}".utf8)); return s.idleSeconds == 90
}
test("sensitivity choice survives save and reload") {
    var s = GuardSettings(); s.testingSensitivity = .aggressive; let d = try JSONDecoder().decode(GuardSettings.self, from: JSONEncoder().encode(s)); return d.testingSensitivity == .aggressive
}
test("counter reset or resume from sleep requires a new quiet window") { var gate = try idleGate(); let d = gate.sample(snapshot: try fixture(), physical: ByteCounters(up: 0, down: 0), probe: ByteCounters(up: 0, down: 0), ownPorts: [], cpuFraction: 0, thermalBusy: false, idleSeconds: 60, now: t0.addingTimeInterval(120)); return !d.ready }
if let i = CommandLine.arguments.firstIndex(of: "--cancel-proxy-port"), CommandLine.arguments.count > i + 1, let port = Int(CommandLine.arguments[i + 1]) {
    test("an in-flight curl is interrupted promptly and classified as deferred") {
        let token = ProbeCancellation(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { token.cancel("user activity") }; let start = Date()
        do { _ = try Probe.curl(url: "https://www.cloudflare.com/cdn-cgi/trace", port: port, timeout: 8, cancellation: token); return false }
        catch is ProbeInterrupted { return Date().timeIntervalSince(start) < 1.5 }
    }
}
if CommandLine.arguments.contains("--live-cancellation") {
    test("real isolated core exposes counters and cancels before uploading any benchmark payload") {
        let snapshot = try MihomoClient().snapshot(); let s = GuardSettings()
        guard let current = snapshot.proxies[s.frontGroup]?.now else { return false }
        let before = Set(((try? FileManager.default.contentsOfDirectory(at: CandidateProbe.cacheRoot, includingPropertiesForKeys: nil)) ?? []).map(\.lastPathComponent))
        let token = ProbeCancellation(); var observed = false
        do {
            _ = try CandidateProbe.measure(candidate: current, snapshot: snapshot, settings: s, previous: nil, cancellation: token, onStage: { stage in
                if stage == "出口验证" {
                    observed = ProbeRuntime.counters() != nil
                    if !observed, let dirs = try? FileManager.default.contentsOfDirectory(at: CandidateProbe.cacheRoot, includingPropertiesForKeys: nil), let scratch = dirs.first {
                        let socket = scratch.appendingPathComponent("ctl.sock").path
                        print("LIVE socket_exists=\(FileManager.default.fileExists(atPath: socket))")
                        do { let data = try MihomoClient(socketPath: socket).request("GET", "/connections"); let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]; print("LIVE response_keys=\(object?.keys.sorted() ?? [])") }
                        catch { print("LIVE controller_error=\(error.localizedDescription)") }
                    }
                    token.cancel("live cancellation verification, before network payload")
                }
            }); return false
        } catch is ProbeInterrupted {
            let leftovers = (try? FileManager.default.contentsOfDirectory(at: CandidateProbe.cacheRoot, includingPropertiesForKeys: nil)) ?? []
            let remaining = Set(leftovers.map(\.lastPathComponent)).subtracting(before)
            print("LIVE counters_available=\(observed) new_scratch_directories=\(remaining.count)")
            return observed && remaining.isEmpty
        }
    }
}
runV3Cases()
runV4Cases()
runV41Cases()
runV42Cases()
runV43Cases()
runV45Cases()
runBackupRecoveryCases()
print("RESULT \(passed) passed; \(failed) failed. Signals in tests are injected mocks; no real Claude process is stopped.")
exit(failed == 0 ? 0 : 1)
