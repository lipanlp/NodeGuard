import Foundation
import NodeGuardCore

private func v43Upload(_ name: String, passed: Bool, date: Date) -> NodeMeasurement {
    var m = v3Record(name, success: passed, date: date)
    if passed { m.diagnostics? += [StageResult(stage: .upload, status: .passed, endpoint: .cloudflareUpload)] }
    else { m.diagnostics? += [StageResult(stage: .upload, status: .failed, endpoint: .cloudflareUpload, failure: ProbeFailure(kind: .timeout, code: 28, detail: "等待响应")), StageResult(stage: .upload, status: .failed, endpoint: .bingoUpload, failure: ProbeFailure(kind: .endpoint, detail: "fixture"))] }
    return m
}
func runV43Cases() {
    var options = GuardSettings(); options.allowedClaudeIPs = ["203.0.113.8"]
    let now = Date()
    test("v0.4.3 line groups ignore flags and region suffixes but keep unstructured names distinct") {
        SharedFailureDetector.lineGroup("中转线路2-台湾01") == "中转线路2" && SharedFailureDetector.lineGroup("🇷🇺 IEPL-俄罗斯-01") == "IEPL"
            && SharedFailureDetector.lineGroup("示例线路|香港01") == "示例线路" && SharedFailureDetector.lineGroup("美国aw4") == "美国aw4" && SharedFailureDetector.lineGroup("-01") == "-01"
    }
    test("large upload failures confined to one relay line are not reported as a shared exit fault") {
        let rows = [v43Upload("中转线路1-香港02", passed: true, date: now.addingTimeInterval(-200)), v43Upload("中转线路1-马来01", passed: true, date: now.addingTimeInterval(-150)),
                    v43Upload("中转线路2-台湾01", passed: false, date: now.addingTimeInterval(-100)), v43Upload("中转线路2-台湾02", passed: false, date: now.addingTimeInterval(-50)), v43Upload("中转线路2-新加坡01", passed: false, date: now)]
        guard let result = SharedFailureDetector.assess(rows, inventory: "v3", now: now) else { return false }
        return result.key == "line" && result.title.contains("中转线路2") && result.nodeCount == 3 && !result.defersPerformance
    }
    test("another node passing the same large upload after the failures began rules out the shared exit") {
        let rows = [v43Upload("甲-01", passed: false, date: now.addingTimeInterval(-200)), v43Upload("乙-01", passed: true, date: now.addingTimeInterval(-150)),
                    v43Upload("丙-01", passed: false, date: now.addingTimeInterval(-100)), v43Upload("丁-01", passed: false, date: now)]
        return SharedFailureDetector.assess(rows, inventory: "v3", now: now) == nil
    }
    test("failures across lines without counter-evidence still pause performance load") {
        let rows = [v43Upload("乙-01", passed: true, date: now.addingTimeInterval(-300)), v43Upload("甲-01", passed: false, date: now.addingTimeInterval(-200)),
                    v43Upload("丙-01", passed: false, date: now.addingTimeInterval(-100)), v43Upload("丁-01", passed: false, date: now)]
        let result = SharedFailureDetector.assess(rows, inventory: "v3", now: now)
        return result?.key == "payload" && result?.defersPerformance == true
    }
    test("a working fallback speed service does not pause performance load") {
        let rows = (0..<3).map { i -> NodeMeasurement in var m = v3Record("\(i)", date: now); m.diagnostics? += [StageResult(stage: .upload, status: .failed, endpoint: .cloudflareUpload), StageResult(stage: .upload, status: .passed, endpoint: .bingoUpload)]; return m }
        return SharedFailureDetector.assess(rows, inventory: "v3", now: now).map { !$0.defersPerformance } == true
    }
    test("fallback upload stays below the HTTPBingo body limit and reports a 1 MB equivalent") {
        var fallbackBytes = 0
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full) { request in
            if request.endpoint == .cloudflareUpload && request.uploadBytes == 1_000_000 { throw ProbeFailure(kind: .timeout, code: 28, detail: "等待响应") }
            if request.endpoint == .bingoUpload && request.uploadBytes > 65_536 {
                fallbackBytes = request.uploadBytes
                var metrics = TransferMetrics(httpStatus: 200, totalSeconds: 4, uploadedBytes: request.uploadBytes); metrics.tlsSeconds = 2
                return CurlResult(body: Data(), seconds: 4, httpStatus: 200, transferred: metrics.transferred, chains: [], metrics: metrics)
            }
            return v3Transport(request)
        }.measurement
        return r.success && fallbackBytes > 0 && fallbackBytes <= 524_288 && abs(r.uploadSeconds - 6) < 0.001
    }
    test("a single failed exit probe followed by a pass never opens an alert") {
        var gate = ExitAlertGate(); let first = gate.failed(now: now); gate.passed()
        return !first && !gate.alerting && gate.failures == 0 && gate.firstFailure == nil
    }
    test("consecutive exit probe failures alert from the first failure time with every probe counted") {
        var gate = ExitAlertGate(); _ = gate.failed(now: now.addingTimeInterval(-6)); let alert = gate.failed(now: now)
        var rows: [GuardIncident] = []
        let change = IncidentLedger.raise(&rows, key: "claude-network", level: "warning", message: "连续 2 次", now: now, since: gate.firstFailure, observations: gate.failures)
        let resolved = IncidentLedger.resolve(&rows, key: "claude-network", now: now.addingTimeInterval(5))
        return alert && change == .opened && resolved?.count == 2 && resolved.map { $0.resolvedAt!.timeIntervalSince($0.firstSeen) } == 11
    }
    test("later failures in one alert update it silently and a pass resets the debounce") {
        var gate = ExitAlertGate(); var rows: [GuardIncident] = []; var changes: [IncidentChange] = []
        for i in 0..<4 where gate.failed(now: now.addingTimeInterval(Double(i * 5))) {
            changes.append(IncidentLedger.raise(&rows, key: "gpt-network", level: "warning", message: "x", now: now.addingTimeInterval(Double(i * 5)), since: gate.firstFailure, observations: gate.failures))
        }
        gate.passed()
        return changes == [.opened, .updated, .updated] && rows.first?.count == 4 && !gate.failed(now: now.addingTimeInterval(30))
    }
    test("exit probes that only fail never terminate Claude however long they last") {
        var m = StrictProtectionMachine(); m.verified(at: now)
        var tripped = false
        for i in 1...60 { m.failed(.timeout, now: now.addingTimeInterval(Double(i * 5))); if m.evaluate(grace: 12, now: now.addingTimeInterval(Double(i * 5))) != nil { tripped = true } }
        return !tripped && m.phase == .holding && m.needsNetworkRecovery && m.reason.contains("保留 Claude")
    }
    test("immediate grace still holds rather than terminating when only the exit is down") {
        var m = StrictProtectionMachine(); m.verified(at: now); m.failed(.network, now: now.addingTimeInterval(1))
        return m.evaluate(grace: 0, now: now.addingTimeInterval(1)) == nil && m.needsNetworkRecovery
    }
    test("a confirmed violation still terminates immediately while holding for the network") {
        var m = StrictProtectionMachine(); m.beginVerification("startup", now: now); _ = m.evaluate(grace: 12, now: now.addingTimeInterval(20))
        let held = m.phase == .holding; let reason = m.violation("Claude 出口 IP 偏离已锁定的出口 IP")
        return held && m.evaluate(grace: 12, now: now.addingTimeInterval(21)) == reason && m.phase == .tripped
    }
    test("losing the Clash control interface still terminates after the bounded window") {
        var m = StrictProtectionMachine(); m.verified(at: now); m.routeUnavailable(now: now.addingTimeInterval(1))
        let early = m.evaluate(grace: 12, now: now.addingTimeInterval(12)); let late = m.evaluate(grace: 12, now: now.addingTimeInterval(13))
        return early == nil && late?.contains("无法核对 Claude 实际路由") == true && m.phase == .tripped
    }
    test("Clash returning restarts the route window and a fresh proof clears the network hold") {
        var m = StrictProtectionMachine(); m.verified(at: now); m.routeUnavailable(now: now.addingTimeInterval(1)); m.routeAvailable()
        let noTrip = m.evaluate(grace: 12, now: now.addingTimeInterval(30)) == nil && m.needsNetworkRecovery
        m.verified(at: now.addingTimeInterval(31))
        return noTrip && !m.needsNetworkRecovery && m.phase == .armed && m.routeUnknownSince == nil
    }
    test("sleep clears a pending network hold so wake starts a fresh window") {
        var m = StrictProtectionMachine(); m.beginVerification("startup", now: now); _ = m.evaluate(grace: 12, now: now.addingTimeInterval(20)); m.sleep()
        m.beginVerification("wake", now: now.addingTimeInterval(100))
        return !m.needsNetworkRecovery && m.evaluate(grace: 12, now: now.addingTimeInterval(105)) == nil && !m.needsNetworkRecovery
    }
    test("primary 1 MB upload seconds are recorded unscaled") {
        let r = try DiagnosticRunner.run(candidate: "A", settings: options, kind: .full, transport: v3Transport).measurement
        return r.success && r.uploadSeconds == 1 && !r.stages.contains { $0.endpoint == .bingoUpload }
    }
}
