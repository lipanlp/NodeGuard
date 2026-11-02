import Foundation
import NodeGuardCore

func v3Record(_ name: String = "香港A", success: Bool = true, kind: MeasurementKind = .full, date: Date = Date(), ip: String = "203.0.113.8", key: String = "v3") -> NodeMeasurement {
    var m = NodeMeasurement(name: name, date: date, success: success, latencyMS: 500, uploadSeconds: 3, downloadMbps: 20, reliability: 1, samples: 1, failure: nil, ip: ip, country: "US")
    m.kind = kind; m.inventoryKey = key
    m.diagnostics = [StageResult(stage: .front, status: .passed, endpoint: .cloudflareTrace), StageResult(stage: .residential, status: .passed, endpoint: .cloudflareTrace), StageResult(stage: .claude, status: .passed, endpoint: .claudeTrace)]
    return m
}
func v3Transport(_ request: DiagnosticRequest) -> CurlResult {
    var downloaded = 0; var body = Data(); var seconds = 1.0
    if request.endpoint.isTrace { body = Data("ip=\(request.frontOnly ? "198.51.100.20" : "203.0.113.8")\nloc=US\n".utf8); downloaded = body.count }
    if request.endpoint == .cloudflareDownload { downloaded = 2_000_000 }
    if request.endpoint == .bingoDownload { downloaded = 262_144 }
    if request.endpoint == .bingoStream { downloaded = 60; seconds = 30 }
    let metrics = TransferMetrics(httpStatus: 200, totalSeconds: seconds, uploadedBytes: request.uploadBytes, downloadedBytes: downloaded)
    return CurlResult(body: body, seconds: seconds, httpStatus: 200, transferred: metrics.transferred, chains: [], metrics: metrics)
}
func runV3Cases() {
    var options = GuardSettings(); options.allowedClaudeIPs = ["203.0.113.8"]
    let now = Date(); let fixed = Date(timeIntervalSince1970: 100_000)
    test("v3 transfer timing parser rejects nonfinite and malformed values") {
        let m = TransferMetrics.parse("200 0.01 0.02 0.1 0.4 1.2 1000000 12")
        return m?.uploadedBytes == 1_000_000 && m?.tlsSeconds == 0.1 && TransferMetrics.parse("200 nan 0 0 0 0 0 0") == nil && TransferMetrics.parse("200 1 2") == nil
    }
    test("local bind errors retain a safe category but discard raw sensitive stderr") {
        let e = ProbeFailure.curl(code: 45, metrics: nil, stderr: "bind failed PRIVATE-TEST-CREDENTIAL https://fake.invalid/?token=PRIVATE-TEST-CREDENTIAL")
        return e.kind == .local && e.code == 45 && !e.localizedDescription.contains("PRIVATE-TEST") && !e.localizedDescription.contains("https")
    }
    test("timeout stages distinguish handshake from waiting for response") {
        var m = TransferMetrics(totalSeconds: 20, uploadedBytes: 1_000_000); m.proxyConnectSeconds = 0.01
        let a = m.stoppedAt; m.tlsSeconds = 1
        return a.contains("TLS") && m.stoppedAt.contains("等待服务响应")
    }
    test("full diagnostic can use a second independent upload endpoint") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.endpoint == .cloudflareUpload && request.uploadBytes == 1_000_000 { throw ProbeFailure(kind: .timeout, code: 28, metrics: TransferMetrics(totalSeconds: 30, uploadedBytes: 1_000_000), detail: "等待响应") }
            return v3Transport(request)
        }
        return r.measurement.success && r.measurement.stages.contains { $0.endpoint == .bingoUpload && $0.status == .passed } && r.measurement.passed(.download)
    }
    test("failed upload preserves successful front, exit, target and download evidence") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.uploadBytes >= DiagnosticEndpoint.fallbackUploadBytes { throw ProbeFailure(kind: .timeout, code: 28, detail: "等待响应") }; return v3Transport(request)
        }.measurement
        return !r.success && r.ip == options.allowedClaudeIPs.first && r.passed(.front) && r.passed(.residential) && r.passed(.claude) && r.downloadMbps > 0 && r.score > 0 && !r.isUsable(allowedIPs: options.allowedClaudeIPs, maxUpload: 15)
    }
    test("HTTP errors do not erase the phase timing already received") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.endpoint == .cloudflareUpload { throw ProbeFailure(kind: .endpoint, metrics: TransferMetrics(httpStatus: 503, totalSeconds: 2), detail: "服务响应") }; return v3Transport(request)
        }
        return r.measurement.stages.contains { $0.failureKind == .endpoint && $0.metrics?.httpStatus == 503 } && r.measurement.success
    }
    test("an unavailable front trace alone cannot disqualify a verified residential path") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.frontOnly { throw ProbeFailure(kind: .endpoint, detail: "独立测试端点不可用") }; return v3Transport(request)
        }.measurement
        return r.success && !r.passed(.front) && r.passed(.residential)
    }
    test("wrong pinned exit stops all performance payloads and remains a route failure") {
        var payloads = 0
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.uploadBytes > 0 { payloads += 1 }
            if request.endpoint.isTrace && !request.frontOnly { let body = Data("ip=203.0.113.99\nloc=US\n".utf8); return CurlResult(body: body, seconds: 1, httpStatus: 200, transferred: body.count, chains: []) }
            return v3Transport(request)
        }.measurement
        return !r.success && payloads == 0 && r.stages.contains { $0.failureKind == .route }
    }
    test("no residential proof leaves target results deferred instead of blaming their services") {
        var targets = 0; var uploads = 0
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.uploadBytes > 0 { uploads += 1 }
            if !request.frontOnly { if request.endpoint == .gptTrace { targets += 1 }; throw ProbeFailure(kind: .timeout, code: 28, detail: "无响应") }; return v3Transport(request)
        }.measurement
        return !r.success && r.passed(.front) && targets == 0 && uploads == 0 && r.stages.contains { $0.stage == .gpt && $0.status == .deferred }
    }
    test("GPT target outage does not falsely disqualify a working Claude backup") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in if request.endpoint == .gptTrace { throw ProbeFailure(kind: .timeout, detail: "目标超时") }; return v3Transport(request) }.measurement
        return r.success && r.passed(.claude) && !r.passed(.gpt)
    }
    test("health maintenance sends no benchmark upload or download payload") {
        var performanceRequests = 0
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .health) { request in if !request.endpoint.isTrace { performanceRequests += 1 }; return v3Transport(request) }.measurement
        return r.success && r.kind == .health && performanceRequests == 0 && !r.isUsable(allowedIPs: options.allowedClaudeIPs, maxUpload: 15)
    }
    test("shared failure backoff still records basic connectivity and marks performance deferred") {
        var performanceRequests = 0
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full, skipPerformance: "共享依赖待复验") { request in if !request.endpoint.isTrace { performanceRequests += 1 }; return v3Transport(request) }.measurement
        return !r.success && r.performanceDeferred == true && r.passed(.residential) && performanceRequests == 0
    }
    test("a complete stream sample is separate from full speed qualification") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .stream, transport: v3Transport).measurement
        return r.success && r.passed(.stream) && r.kind == .stream && !r.hasFullPerformance
    }
    test("an instant buffered response cannot pass the thirty second stream check") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .stream) { request in
            if request.endpoint == .bingoStream { return CurlResult(body: Data(), seconds: 1, httpStatus: 200, transferred: 60, chains: [], metrics: TransferMetrics(httpStatus: 200, totalSeconds: 1, downloadedBytes: 60)) }; return v3Transport(request)
        }.measurement
        return !r.success && !r.passed(.stream)
    }
    test("one validated response is charged once even if a validator rejects its body") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .health) { request in
            let body = Data("ip=127.0.0.1\nloc=US\n".utf8)
            return CurlResult(body: body, seconds: 1, httpStatus: 200, transferred: 20, chains: [], metrics: TransferMetrics(httpStatus: 200, totalSeconds: 1, downloadedBytes: 20))
        }
        return r.chargedBytes == 60
    }
    test("real success ratio counts distinct persisted samples, not legacy estimated sample totals") {
        var a = v3Record(date: now); a.samples = 100
        let b = v3Record(success: false, date: now.addingTimeInterval(-1)); let c = v3Record(kind: .health, date: now.addingTimeInterval(-2))
        let s = HistorySummary.calculate([a, b, c], name: a.name, inventory: "v3", now: now)
        return s.total == 2 && s.successes == 1 && s.ratio == 0.5 && s.lastSuccess == now
    }
    test("deferred performance samples are not counted as measured failures") {
        var a = v3Record(success: false, date: now); a.performanceDeferred = true
        return HistorySummary.calculate([a], name: a.name, inventory: "v3", now: now).total == 0
    }
    test("history isolates subscriptions and excludes old or future records") {
        let rows = [v3Record(date: now, key: "other"), v3Record(date: now.addingTimeInterval(-90000)), v3Record(date: now.addingTimeInterval(1))]
        return HistorySummary.calculate(rows, name: "香港A", inventory: "v3", now: now).total == 0
    }
    test("P95 and jitter use measured elapsed samples") {
        var a = v3Record(date: now); var b = v3Record(date: now.addingTimeInterval(-1)); a.latencyMS = 100; b.latencyMS = 300
        let s = HistorySummary.calculate([a,b], name: a.name, inventory: "v3", now: now)
        return s.medianMS == 100 && s.p95MS == 300 && s.jitterMS == 100
    }
    test("history remains bounded while preserving full tests alongside health probes") {
        var rows: [NodeMeasurement] = []
        for i in 0..<50 { rows = MeasurementHistory.append(v3Record(kind: .health, date: now.addingTimeInterval(Double(-i))), to: rows, now: now) }
        rows = MeasurementHistory.append(v3Record(date: now), to: rows, now: now)
        return rows.filter { $0.kind == .health }.count == 36 && rows.contains { $0.kind == .full }
    }
    test("three distinct nodes with the same large upload failure produce a shared suspicion") {
        let rows = (0..<3).map { i -> NodeMeasurement in var m = v3Record("\(i)", success: false, date: now); m.diagnostics?.append(StageResult(stage: .upload, status: .failed, endpoint: .cloudflareUpload, failure: ProbeFailure(kind: .timeout, code: 28, detail: "等待响应"))); return m }
        return SharedFailureDetector.assess(rows, inventory: "v3", now: now)?.key == "payload" && SharedFailureDetector.assess(rows, inventory: "other", now: now) == nil
    }
    test("repeated failure on one node cannot establish a common path fault") {
        var m = v3Record(success: false, date: now); m.diagnostics?.append(StageResult(stage: .upload, status: .failed, endpoint: .cloudflareUpload))
        return SharedFailureDetector.assess([m,m,m], inventory: "v3", now: now) == nil
    }
    test("shared endpoint diagnosis distinguishes working fallback from dead front nodes") {
        let rows = (0..<3).map { i -> NodeMeasurement in var m = v3Record("\(i)", date: now); m.diagnostics? += [StageResult(stage: .upload, status: .failed, endpoint: .cloudflareUpload), StageResult(stage: .upload, status: .passed, endpoint: .bingoUpload)]; return m }
        return SharedFailureDetector.assess(rows, inventory: "v3", now: now)?.key == "speed-service"
    }
    test("backup recommendations diversify regions instead of taking only the fastest region") {
        let names = ["香港1", "香港2", "香港3", "日本1", "台湾1", "美国1"]
        let rows = names.map { v3Record($0, date: now) }
        var s = options; s.backupPoolSize = 3
        let pool = BackupPlanner.pool(available: names, current: "none", settings: s, history: rows, health: [], inventory: "v3", now: now)
        return pool.count == 3 && Set(pool.map(BackupPlanner.region)).count == 3
    }
    test("a ready backup needs both a successful performance baseline and recent exact pin health") {
        let full = v3Record(date: now.addingTimeInterval(-100)); let health = v3Record(kind: .health, date: now)
        let a = BackupPlanner.pool(available: [full.name], current: "none", settings: options, history: [full], health: [health], inventory: "v3", requireReady: true, now: now)
        var wrong = health; wrong.ip = "203.0.113.99"
        let b = BackupPlanner.pool(available: [full.name], current: "none", settings: options, history: [full], health: [wrong], inventory: "v3", requireReady: true, now: now)
        return a == [full.name] && b.isEmpty
    }
    test("later failed performance invalidates an older good baseline") {
        let a = v3Record(date: now.addingTimeInterval(-100)); let b = v3Record(success: false, date: now)
        return BackupPlanner.quality(name: a.name, history: [a,b], inventory: "v3", settings: options, now: now) == nil
    }
    test("manual-only pools never invent approval for an unlisted node") {
        var s = options; s.automaticBackupPool = false; s.candidates = ["台湾A"]
        let pool = BackupPlanner.pool(available: ["香港A", "台湾A"], current: "none", settings: s, history: [v3Record("香港A"),v3Record("台湾A")], health: [], inventory: "v3")
        return pool == ["台湾A"]
    }
    test("fast failover keeps performance and fresh health timestamps separate") {
        var s = options; s.autoSwitch = true; s.candidates = ["B"]
        let quality = v3Record("B", date: now.addingTimeInterval(-1000)); let health = v3Record("B", kind: .health, date: now)
        return try FailoverPolicy.mayCommit(settings: s, snapshot: fixture(), old: "A", quality: quality, health: health, now: now)
    }
    test("fresh connectivity alone cannot authorize performance-qualified failover") {
        var s = options; s.autoSwitch = true; s.candidates = ["B"]
        let health = v3Record("B", kind: .health, date: now)
        return try !FailoverPolicy.mayCommit(settings: s, snapshot: fixture(), old: "A", quality: health, health: health, now: now)
    }
    test("stale or wrong-IP health cannot authorize a selector write") {
        var s = options; s.autoSwitch = true; s.candidates = ["B"]
        let quality = v3Record("B", date: now); let health = v3Record("B", kind: .health, date: now.addingTimeInterval(-31))
        return try !FailoverPolicy.mayCommit(settings: s, snapshot: fixture(), old: "A", quality: quality, health: health, now: now)
    }
    test("strict startup verifies first but cannot wait indefinitely for evidence") {
        var m = StrictProtectionMachine(); m.beginVerification("startup", now: fixed)
        let a = m.evaluate(grace: 12, now: fixed.addingTimeInterval(11)); let b = m.evaluate(grace: 12, now: fixed.addingTimeInterval(12))
        return a == nil && b != nil && m.phase == .tripped
    }
    test("confirmed IP or route violation triggers during verification without waiting") {
        var m = StrictProtectionMachine(); m.beginVerification("startup", now: fixed); let reason = m.violation("confirmed mismatch")
        return reason == "confirmed mismatch" && m.evaluate(grace: 20, now: fixed) == reason
    }
    test("a local probe error receives only the bounded verification window") {
        var m = StrictProtectionMachine(); m.verified(at: fixed); m.failed(.local, now: fixed.addingTimeInterval(1))
        return m.evaluate(grace: 12, now: fixed.addingTimeInterval(2)) == nil && m.evaluate(grace: 12, now: fixed.addingTimeInterval(13)) != nil
    }
    test("repeated network changes cannot reset the unknown deadline forever") {
        var m = StrictProtectionMachine(); m.beginVerification("change1", now: fixed); m.beginVerification("change2", now: fixed.addingTimeInterval(8))
        return m.evaluate(grace: 12, now: fixed.addingTimeInterval(12)) != nil
    }
    test("sleep suspends stale evidence; wake obtains a new bounded window") {
        var m = StrictProtectionMachine(); m.verified(at: fixed); m.sleep(); let asleep = m.evaluate(grace: 12, now: fixed.addingTimeInterval(10000))
        m.beginVerification("wake", now: fixed.addingTimeInterval(10000)); let waking = m.evaluate(grace: 12, now: fixed.addingTimeInterval(10001)); m.verified(at: fixed.addingTimeInterval(10002))
        return asleep == nil && waking == nil && m.phase == .armed && m.unknownSince == nil
    }
    test("verified recovery clears the unknown window and rearms without relaunching any app") {
        var m = StrictProtectionMachine(); m.beginVerification("startup", now: fixed); m.failed(.timeout, now: fixed.addingTimeInterval(1)); m.verified(at: fixed.addingTimeInterval(2))
        return m.evaluate(grace: 12, now: fixed.addingTimeInterval(3)) == nil && m.phase == .armed
    }
    test("incident noise is merged by identity even if the latest error message changes") {
        var rows: [GuardIncident] = []
        let a = IncidentLedger.raise(&rows, key: "network", level: "warning", message: "curl 28", now: fixed)
        let b = IncidentLedger.raise(&rows, key: "network", level: "warning", message: "curl 45", now: fixed.addingTimeInterval(2))
        return a == .opened && b == .updated && rows.count == 1 && rows[0].count == 2
    }
    test("critical escalation alerts immediately and recovery preserves duration") {
        var rows: [GuardIncident] = []; _ = IncidentLedger.raise(&rows, key: "protection", level: "warning", message: "unknown", now: fixed)
        let change = IncidentLedger.raise(&rows, key: "protection", level: "critical", message: "mismatch", now: fixed.addingTimeInterval(1))
        let resolved = IncidentLedger.resolve(&rows, key: "protection", now: fixed.addingTimeInterval(20))
        return change == .escalated && resolved?.resolvedAt == fixed.addingTimeInterval(20) && rows[0].firstSeen == fixed && IncidentLedger.resolve(&rows, key: "protection") == nil
    }
    test("long incidents remind after cooldown without creating new incident rows") {
        var rows: [GuardIncident] = []; _ = IncidentLedger.raise(&rows, key: "network", level: "warning", message: "offline", now: fixed)
        return IncidentLedger.raise(&rows, key: "network", level: "warning", message: "offline", now: fixed.addingTimeInterval(901)) == .reminder && rows.count == 1
    }
    test("unfinished scan resumes the exact remaining nodes after a process restart") {
        let inventory = SubscriptionInventory(key: "v3", name: "subscription", nodes: ["A","B","C"])
        var q = FullScanQueue(); q.replace(inventory); q.finish(node: "A", inventoryKey: "v3", interval: 3600)
        let data = try JSONEncoder().encode(q.checkpoint!); let saved = try JSONDecoder().decode(ScanCheckpoint.self, from: data)
        var restored = FullScanQueue(); return restored.restore(saved, inventory: inventory) && restored.pending == ["B","C"] && restored.completed == 1
    }
    test("corrupt or foreign scan checkpoint cannot skip or invent nodes") {
        var q = FullScanQueue(); let inventory = SubscriptionInventory(key: "v3", name: "sub", nodes: ["A","B"])
        let corrupt = ScanCheckpoint(inventoryKey: "v3", pending: ["B","B"], completed: 0, total: 2, nextRound: nil)
        let foreign = ScanCheckpoint(inventoryKey: "other", pending: ["A","B"], completed: 0, total: 2, nextRound: nil)
        return !q.restore(corrupt, inventory: inventory) && !q.restore(foreign, inventory: inventory)
    }
    test("a finished checkpoint keeps the next scheduled round rather than restarting") {
        let inventory = SubscriptionInventory(key: "v3", name: "sub", nodes: ["A"]); var q = FullScanQueue(); q.replace(inventory, now: fixed); q.finish(node: "A", inventoryKey: "v3", interval: 3600, now: fixed)
        var r = FullScanQueue(); return r.restore(q.checkpoint!, inventory: inventory) && r.pending.isEmpty && r.nextRound == fixed.addingTimeInterval(3600)
    }
    test("settings migration preserves pins and armed flags while adding explicit verification timing") {
        let data = Data("{\"settingsVersion\":3,\"allowedClaudeIPs\":[\"203.0.113.8\"],\"strictProtection\":true,\"autoSwitch\":true,\"idleSeconds\":15}".utf8)
        let s = try JSONDecoder().decode(GuardSettings.self, from: data)
        return s.strictProtection && s.autoSwitch && s.allowedClaudeIPs == options.allowedClaudeIPs && s.unverifiedGrace == 12 && s.backupPoolSize == 5 && s.idleSeconds == 15
    }
    test("corrupt primary state can recover private pins from the last valid atomic backup") {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NodeGuard-v3-\(UUID())"); defer { try? FileManager.default.removeItem(at: dir) }
        let store = StateStore(directory: dir); var state = StoredState(); state.settings = options; state.settings.strictProtection = true
        try store.save(state); state.testBytes = 100; try store.save(state); try Data("broken".utf8).write(to: store.file)
        let restored = store.load(); let permissions = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("state.previous.json").path)[.posixPermissions] as? Int
        return restored.settings.strictProtection && restored.settings.allowedClaudeIPs == options.allowedClaudeIPs && permissions == 0o600
    }
    test("diagnostic export uses an allowlist and excludes every injected secret-bearing field") {
        var state = StoredState(); state.settings.frontGroup = "PRIVATE-PASSWORD"; state.settings.allowedClaudeIPs = ["203.0.113.8"]
        var m = v3Record("SECRET-NODE-URL?token=PRIVATE-PASSWORD"); m.failure = "SECRET-FAILURE"; m.diagnostics?.append(StageResult(stage: .upload, status: .failed, endpoint: .bingoUpload, note: "SECRET-HEADER")); state.history = [m]
        state.events = [GuardEvent(level: "warning", message: "SECRET-EVENT")]; state.incidents = [GuardIncident(key: "SECRET-KEY", level: "warning", message: "SECRET-MESSAGE", now: now)]
        let data = try DiagnosticExport.data(state: state, version: "0.3.0", connected: true, network: "SECRET-SSID", protection: .disabled); let text = String(decoding: data, as: UTF8.self)
        return !["PRIVATE-PASSWORD", "SECRET", "203.0.113.8", "https://"].contains(where: text.contains) && text.contains("bingoUpload") && text.contains("node-")
    }
    test("two isolated listeners keep front and residential tests separate without changing source") {
        let source: [String: Any] = ["proxies": [["name": "A", "type": "trojan", "server": "127.0.0.1", "password": "FAKE-NOT-A-CREDENTIAL"], ["name": "Comcast住宅", "type": "socks5", "server": "127.0.0.1", "dialer-proxy": "KTM前置节点"]]]
        let c = try CandidateProbe.configuration(source: source, snapshot: fixture(), candidate: "A", settings: options, port: 31000, interface: "en0", frontPort: 31001)
        let listeners = c["listeners"] as? [[String: Any]] ?? []
        return listeners.count == 2 && listeners[0]["proxy"] as? String == "NodeGuard-exit" && listeners[1]["proxy"] as? String == "A" && c["external-controller"] == nil
    }
    test("incident context changes do not claim the previous subscription recovered") {
        var records: [GuardIncident] = []
        _ = IncidentLedger.raise(&records, key: "claude-network", level: "warning", message: "failure", now: fixed, inventory: "first", front: "A")
        let change = IncidentLedger.raise(&records, key: "claude-network", level: "warning", message: "failure", now: fixed.addingTimeInterval(1), inventory: "second", front: "B")
        return change == .opened && records.count == 2 && records[1].resolutionReason == "contextChanged" && records[0].frontName == "B"
    }
    test("an invalid checkpoint cannot defer the next scan years into the future") {
        var q = FullScanQueue(); let inventory = SubscriptionInventory(key: "v3", name: "sub", nodes: ["A"])
        return !q.restore(ScanCheckpoint(inventoryKey: "v3", pending: [], completed: 1, total: 1, nextRound: now.addingTimeInterval(999999)), inventory: inventory, now: now)
    }

    test("partial connectivity evidence cannot displace qualified backups for regional diversity") {
        var s = options; s.backupPoolSize = 3
        let names = ["香港1", "香港2", "香港3", "美国1"]
        var partial = v3Record("美国1", success: false, date: now); partial.diagnostics?.append(StageResult(stage: .download, status: .passed, endpoint: .cloudflareDownload))
        let records = names.prefix(3).map { v3Record($0, date: now) } + [partial]
        let pool = BackupPlanner.pool(available: names, current: "none", settings: s, history: records, health: [], inventory: "v3", now: now)
        return pool.count == 3 && !pool.contains("美国1") && partial.score <= 12
    }

}
