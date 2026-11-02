import Foundation
import NodeGuardCore

private func v41Snapshot(node: String = "任意出口", front: String = "A", linked: Bool = true, frontOnly: Bool = false, chains: [String]? = nil) throws -> CoreSnapshot {
    let old = try fixture(front: front, connectionChain: chains)
    var proxies = old.proxies; proxies.removeValue(forKey: "Comcast住宅")
    func info(_ object: [String: Any]) throws -> ProxyInfo { try JSONDecoder().decode(ProxyInfo.self, from: JSONSerialization.data(withJSONObject: object)) }
    proxies["Claude专线"] = try info(["name": "Claude专线", "type": "Selector", "now": frontOnly ? "KTM前置节点" : node])
    var exit: [String: Any] = ["name": node, "type": "Socks5"]
    if linked { exit["dialer-proxy"] = "KTM前置节点" }
    proxies[node] = try info(exit)
    return CoreSnapshot(proxies: proxies, connections: old.connections, config: old.config)
}
private func v41Source(node: String = "任意出口") -> [String: Any] {
    ["proxies": [
        ["name": "A", "type": "trojan", "server": "127.0.0.1", "password": "FAKE-TEST-ONLY"],
        ["name": "B", "type": "trojan", "server": "127.0.0.1", "password": "FAKE-TEST-ONLY"],
        ["name": "C", "type": "trojan", "server": "127.0.0.1", "password": "FAKE-TEST-ONLY"],
        ["name": node, "type": "socks5", "server": "127.0.0.1", "port": 10000, "username": "FAKE-USER", "password": "FAKE-TEST-ONLY", "dialer-proxy": "KTM前置节点"]
    ]]
}
func runV41Cases() {
    var settings = GuardSettings(); settings.residentialNode = "Comcast住宅" // A legacy value must have no effect.
    settings.allowedClaudeIPs = ["203.0.113.8"]; settings.autoSwitch = true; settings.candidates = ["A", "B"]
    func observation(_ node: String = "任意出口", ip: String = "203.0.113.8", country: String = "US", age: Double = 0) -> ExitObservation {
        ExitObservation(ip: ip, country: country, seconds: 1, date: Date().addingTimeInterval(-age), chains: [node, "Claude专线"])
    }
    test("v0.4.1 enrollment pins the current exit with the legacy Comcast node entirely absent") {
        let s = try v41Snapshot(); let proof = observation()
        return s.proxies["Comcast住宅"] == nil && ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [proof, proof])
    }
    test("non-residential provider names and protocols do not participate in the pin decision") {
        let s = try v41Snapshot(node: "云服务器出口"); let proof = observation("云服务器出口")
        return ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [proof, proof]) && ProtectionPolicy.topologyViolation(snapshot: s, settings: settings, claudePaths: paths) == nil
    }
    test("changing provider names with the same exact IP does not change the pinned identity") {
        let s = try v41Snapshot(node: "新出口"); let proof = observation("新出口")
        return ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [proof, proof]) && ProtectionPolicy.exitViolation(proof, allowedIPs: settings.allowedClaudeIPs) == nil
    }
    test("IP-only pinning still rejects two inconsistent IP observations") {
        try !ProtectionPolicy.canEnroll(snapshot: v41Snapshot(), settings: settings, observations: [observation(), observation(ip: "203.0.113.9")])
    }
    test("IP-only pinning rejects mainland private invalid and stale observations") {
        let s = try v41Snapshot()
        return [observation(country: "CN"), observation(ip: "10.0.0.1"), observation(ip: "invalid"), observation(age: 21)].allSatisfy { !ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [$0, $0]) }
    }
    test("matching IP without captured current-route evidence cannot be enrolled") {
        let s = try v41Snapshot(); let wrong = observation("旧出口")
        let empty = ExitObservation(ip: "203.0.113.8", country: "US", seconds: 1)
        return !ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [wrong, wrong]) && !ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [empty, empty])
    }
    test("locking a valid exit does not require an associated front selector") {
        let s = try v41Snapshot(linked: false); let proof = observation()
        return ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [proof, proof]) && !FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", candidate: sample())
    }
    test("a direct front route can be pinned without any separate residential proxy") {
        let s = try v41Snapshot(frontOnly: true); let proof = observation("A")
        return ProtectionPolicy.canEnroll(snapshot: s, settings: settings, observations: [proof, proof]) && ExitRoute.current(snapshot: s, settings: settings)?.usesFront(settings) == true
    }
    test("new generic topology checks still reject actual Claude connections on a different route") {
        try ProtectionPolicy.topologyViolation(snapshot: v41Snapshot(chains: ["DIRECT"]), settings: settings, claudePaths: paths) != nil
    }
    test("a real Claude connection on the current generic route passes the topology check") {
        try ProtectionPolicy.topologyViolation(snapshot: v41Snapshot(chains: ["任意出口", "Claude专线"]), settings: settings, claudePaths: paths) == nil
    }
    test("existing Claude sockets may retain a renamed node label in the same policy group") {
        try ProtectionPolicy.topologyViolation(snapshot: v41Snapshot(chains: ["旧节点名", "Claude专线"]), settings: settings, claudePaths: paths) == nil
    }
    test("a direct bypass remains invalid even if the old Claude policy group is recorded") {
        try ProtectionPolicy.topologyViolation(snapshot: v41Snapshot(chains: ["DIRECT", "Claude专线"]), settings: settings, claudePaths: paths) != nil
    }
    test("a different proxy without current node or Claude policy evidence is still unverified") {
        try ProtectionPolicy.topologyViolation(snapshot: v41Snapshot(chains: ["其他出口", "其他策略"]), settings: settings, claudePaths: paths) != nil
    }
    test("a generic exit still cannot commit a candidate with a different pinned IP") {
        let s = try v41Snapshot()
        return FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", candidate: sample()) && !FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", candidate: sample(ip: "203.0.113.9"))
    }
    test("generic candidate cloning replaces only the front and preserves the current exit definition") {
        let source = v41Source(); let before = try JSONSerialization.data(withJSONObject: source, options: .sortedKeys)
        let result = try CandidateProbe.configuration(source: source, snapshot: v41Snapshot(), candidate: "B", settings: settings, port: 31000, interface: "en0", frontPort: 31001)
        let nodes = result["proxies"] as? [[String: Any]] ?? []; let exit = nodes.first { $0["name"] as? String == "NodeGuard-exit" }
        let after = try JSONSerialization.data(withJSONObject: source, options: .sortedKeys)
        return exit?["dialer-proxy"] as? String == "B" && exit?["username"] as? String == "FAKE-USER" && exit?["type"] as? String == "socks5" && before == after
    }
    test("front-only isolation uses the candidate directly without inventing a residential proxy") {
        let result = try CandidateProbe.configuration(source: v41Source(), snapshot: v41Snapshot(frontOnly: true), candidate: "B", settings: settings, port: 31000, interface: "en0")
        let listeners = result["listeners"] as? [[String: Any]] ?? []
        return listeners.first?["proxy"] as? String == "B" && (result["proxies"] as? [[String: Any]])?.count == 1
    }
    test("front tests are refused if they cannot affect the current exit") {
        throwsError { _ = try CandidateProbe.configuration(source: v41Source(), snapshot: v41Snapshot(linked: false), candidate: "B", settings: settings, port: 31000, interface: "en0") }
    }
    test("nested exit dialers are copied with the generic candidate at the same front boundary") {
        let s = try v41Snapshot(); var proxies = s.proxies
        let definitions: [[String: Any]] = [["name": "任意出口", "type": "Socks5", "dialer-proxy": "中间层"], ["name": "中间层", "type": "Socks5", "dialer-proxy": "KTM前置节点"]]
        for d in definitions { let p = try JSONDecoder().decode(ProxyInfo.self, from: JSONSerialization.data(withJSONObject: d)); proxies[p.name] = p }
        let snapshot = CoreSnapshot(proxies: proxies, connections: [], config: s.config)
        var source = v41Source(); var raw = source["proxies"] as! [[String: Any]]
        raw[3]["dialer-proxy"] = "中间层"; raw.append(["name": "中间层", "type": "socks5", "server": "127.0.0.1", "port": 10001, "dialer-proxy": "KTM前置节点"]); source["proxies"] = raw
        let config = try CandidateProbe.configuration(source: source, snapshot: snapshot, candidate: "B", settings: settings, port: 31000, interface: "en0")
        let out = config["proxies"] as! [[String: Any]]; let first = out.first { $0["name"] as? String == "NodeGuard-exit" }!
        let next = out.first { $0["name"] as? String == first["dialer-proxy"] as? String }
        return next?["dialer-proxy"] as? String == "B"
    }
    test("a candidate depending on its own front group is rejected before any API write") {
        var source = v41Source(); var nodes = source["proxies"] as! [[String: Any]]; nodes[1]["dialer-proxy"] = "KTM前置节点"; source["proxies"] = nodes
        return throwsError { _ = try CandidateProbe.configuration(source: source, snapshot: v41Snapshot(), candidate: "B", settings: settings, port: 31000, interface: "en0") }
    }
    test("inconsistent raw and observed exit chains cannot produce a misleading isolated test") {
        var source = v41Source(); var nodes = source["proxies"] as! [[String: Any]]; nodes[3]["dialer-proxy"] = "C"; source["proxies"] = nodes
        return throwsError { _ = try CandidateProbe.configuration(source: source, snapshot: v41Snapshot(), candidate: "B", settings: settings, port: 31000, interface: "en0") }
    }
    test("test context stays stable across front switches but changes when the exit path changes") {
        let a = try ExitRoute.current(snapshot: v41Snapshot(), settings: settings)!
        let b = try ExitRoute.current(snapshot: v41Snapshot(front: "B"), settings: settings)!
        let c = try ExitRoute.current(snapshot: v41Snapshot(node: "其他出口"), settings: settings)!
        return a.testingContext(settings) == b.testingContext(settings) && a.testingContext(settings) != c.testingContext(settings)
    }
    test("legacy ISP state remains readable without overriding pins or automation flags") {
        let restored = try JSONDecoder().decode(GuardSettings.self, from: JSONEncoder().encode(settings))
        let proof = observation()
        let s = try v41Snapshot()
        return restored.allowedClaudeIPs == settings.allowedClaudeIPs && restored.autoSwitch && !restored.strictProtection && GuardSettings().residentialNode.isEmpty && ProtectionPolicy.canEnroll(snapshot: s, settings: restored, observations: [proof, proof])
    }
}
