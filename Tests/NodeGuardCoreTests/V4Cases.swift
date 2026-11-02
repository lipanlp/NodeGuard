import Foundation
import NodeGuardCore

private func v4Record(_ name: String, date: Date, up: Double = 3, down: Double = 20, latency: Double = 500, success: Bool = true, endpoint: DiagnosticEndpoint = .cloudflareUpload) -> NodeMeasurement {
    var m = v3Record(name, success: success, date: date, key: "v4")
    m.uploadSeconds = up; m.downloadMbps = down; m.latencyMS = latency
    m.diagnostics?.append(StageResult(stage: .upload, status: success ? .passed : .failed, endpoint: endpoint, failure: success ? nil : ProbeFailure(kind: .timeout, detail: "fixture")))
    m.diagnostics?.append(StageResult(stage: .download, status: .passed, endpoint: .cloudflareDownload))
    return m
}
private func v4Rows(_ name: String, now: Date, up: Double = 3, down: Double = 20, latency: Double = 500, endpoint: DiagnosticEndpoint = .cloudflareUpload) -> [NodeMeasurement] {
    [10.0, 90.0].map { v4Record(name, date: now.addingTimeInterval(-$0), up: up, down: down, latency: latency, endpoint: endpoint) }
}
func runV4Cases() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var settings = GuardSettings(); settings.autoSwitch = true; settings.allowedClaudeIPs = ["203.0.113.8"]
    let baseline = v4Rows("A", now: now, up: 8, down: 5, latency: 900)
    let fast = v4Rows("B", now: now)
    func collect(_ name: String, _ rows: [NodeMeasurement], candidate: Bool = true) -> StableNodePerformance? {
        StableNodePerformance.collect(name: name, history: rows, inventory: "v4", allowedIPs: settings.allowedClaudeIPs, candidate: candidate, maxUpload: 15, now: now)
    }
    func evaluate(_ tracker: inout BestNodeTracker, rows: [NodeMeasurement], date: Date, idle: Bool = true, inventory: String? = "v4", current: String = "A", journal: SwitchingJournal = SwitchingJournal(), options: GuardSettings? = nil) -> BestNodeDecision {
        tracker.evaluate(current: current, eligible: ["A", "B", "C"], history: rows, inventory: inventory, settings: options ?? settings, journal: journal, idle: idle, stableSince: now.addingTimeInterval(-300), now: date)
    }
    test("v4 two spaced matching full measurements establish stable performance") {
        collect("B", fast)?.successfulSamples == 2 && collect("B", fast)?.score == 100
    }
    test("one result or two results less than a minute apart cannot authorize optimization") {
        let close = [fast[0], v4Record("B", date: now.addingTimeInterval(-40))]
        return collect("B", [fast[0]]) == nil && collect("B", close) == nil
    }
    test("stale, deferred, health and other subscription results cannot fill the second sample") {
        var deferred = fast[1]; deferred.performanceDeferred = true
        var health = fast[1]; health.kind = .health
        var foreign = fast[1]; foreign.inventoryKey = "other"
        let stale = v4Record("B", date: now.addingTimeInterval(-1900))
        return [deferred, health, foreign, stale].allSatisfy { collect("B", [fast[0], $0]) == nil }
    }
    test("latest failed full check invalidates an older healthy optimization baseline") {
        collect("B", fast + [v4Record("B", date: now, success: false)]) == nil
    }
    test("two baselines must have the same upload and download endpoint") {
        let other = v4Record("B", date: now.addingTimeInterval(-90), endpoint: .bingoUpload)
        return collect("B", [fast[0], other]) == nil
    }
    test("exact exit pin and residential plus Claude stages are required") {
        var wrong = fast; wrong[0].ip = "203.0.113.9"
        var domestic = fast; domestic[0].country = "CN"
        var unverified = fast; unverified[0].diagnostics?.removeAll { $0.stage == .claude }
        return collect("B", wrong) == nil && collect("B", domestic) == nil && collect("B", unverified) == nil
    }
    test("median of three measurements resists one isolated slow performance result") {
        let rows = fast + [v4Record("B", date: now.addingTimeInterval(-170), up: 80, down: 1, latency: 5000)]
        return collect("B", rows)?.uploadSeconds == 3 && collect("B", rows)?.score == 100
    }
    test("similar scores keep the current node") {
        let near = v4Rows("B", now: now, up: 7.8, down: 5.1, latency: 890)
        return !(collect("B", near)?.clearlyBeats(collect("A", baseline, candidate: false)!) ?? true)
    }
    test("ten point advantage still needs twenty percent relative improvement") {
        let a = collect("A", v4Rows("A", now: now, up: 4, down: 18, latency: 600), candidate: false)!
        let b = collect("B", fast)!
        return b.score - a.score >= 10 && b.score < a.score * 1.2 && !b.clearlyBeats(a)
    }
    test("twenty percent improvement still needs ten absolute points") {
        let a = collect("A", v4Rows("A", now: now, up: 15, down: 1, latency: 6000), candidate: false)!
        let b = collect("B", v4Rows("B", now: now, up: 10, down: 4, latency: 5000))!
        return b.score >= a.score * 1.2 && b.score - a.score < 10 && !b.clearlyBeats(a)
    }
    test("different benchmark services are never compared for automatic optimization") {
        let b = collect("B", v4Rows("B", now: now, endpoint: .bingoUpload))!
        return !b.clearlyBeats(collect("A", baseline, candidate: false)!)
    }
    test("a reliability-only score gain cannot replace actual performance improvement") {
        var rows = v4Rows("A", now: now, up: 10, down: 5, latency: 1200)
        rows += [170.0, 250.0, 330.0].map { v4Record("A", date: now.addingTimeInterval(-$0), up: 10, down: 5, latency: 1200, success: false) }
        let a = collect("A", rows, candidate: false)!
        let b = collect("B", v4Rows("B", now: now, up: 10, down: 5, latency: 1200))!
        return b.score - a.score >= 10 && b.score >= a.score * 1.2 && !b.clearlyBeats(a)
    }
    test("healthy optimization requires the same leader to persist for three minutes") {
        var tracker = BestNodeTracker(); let rows = baseline + fast
        return evaluate(&tracker, rows: rows, date: now).candidate == nil && evaluate(&tracker, rows: rows, date: now.addingTimeInterval(179)).candidate == nil && evaluate(&tracker, rows: rows, date: now.addingTimeInterval(180)).candidate == "B"
    }
    test("a different leader restarts the stability observation") {
        var tracker = BestNodeTracker(); _ = evaluate(&tracker, rows: baseline + fast, date: now)
        let c = v4Rows("C", now: now)
        let d = evaluate(&tracker, rows: baseline + c, date: now.addingTimeInterval(180))
        return d.candidate == nil && tracker.leader == "C" && tracker.leaderSince == now.addingTimeInterval(180)
    }
    test("loss of advantage clears the leader observation") {
        var tracker = BestNodeTracker(); _ = evaluate(&tracker, rows: baseline + fast, date: now)
        let near = v4Rows("B", now: now, up: 8, down: 5, latency: 900)
        _ = evaluate(&tracker, rows: baseline + near, date: now.addingTimeInterval(30))
        return tracker.leader == nil && evaluate(&tracker, rows: baseline + fast, date: now.addingTimeInterval(180)).candidate == nil
    }
    test("confirmed advantage waits for an idle transfer window") {
        var tracker = BestNodeTracker(); let rows = baseline + fast
        _ = evaluate(&tracker, rows: rows, date: now)
        return evaluate(&tracker, rows: rows, date: now.addingTimeInterval(180), idle: false).candidate == nil && evaluate(&tracker, rows: rows, date: now.addingTimeInterval(182)).candidate == "B"
    }
    test("route warmup, disabled master and disabled optimization all prevent selection") {
        var tracker = BestNodeTracker(); var off = settings; off.autoSwitch = false
        var faultOnly = settings; faultOnly.preferBestNode = false
        let warm = tracker.evaluate(current: "A", eligible: ["B"], history: baseline + fast, inventory: "v4", settings: settings, journal: SwitchingJournal(), idle: true, stableSince: now.addingTimeInterval(-179), now: now)
        return warm.candidate == nil && tracker.leader == nil && evaluate(&tracker, rows: baseline + fast, date: now, options: off).candidate == nil && evaluate(&tracker, rows: baseline + fast, date: now, options: faultOnly).candidate == nil
    }
    test("inventory or current node change discards an old leader") {
        var tracker = BestNodeTracker(); _ = evaluate(&tracker, rows: baseline + fast, date: now)
        _ = evaluate(&tracker, rows: baseline + fast, date: now.addingTimeInterval(180), inventory: "new")
        return tracker.leader == nil && evaluate(&tracker, rows: baseline + fast, date: now.addingTimeInterval(182), current: "C").candidate == nil
    }
    test("successful, failed and pending automatic attempts all impose thirty minute optimization cooldown") {
        [ManagedSwitchStatus.verified, .failed, .pending].allSatisfy { status in
            var j = SwitchingJournal(); var item = ManagedSwitch(from: "A", to: "B", inventory: "v4", reason: .failure, date: now.addingTimeInterval(-1799)); item.status = status; j.append(item, now: now)
            return j.block(reason: .optimization, candidate: "C", inventory: "v4", now: now) != nil && j.block(reason: .failure, candidate: "C", inventory: "v4", now: now) == nil && j.block(reason: .optimization, candidate: "C", inventory: "v4", now: now.addingTimeInterval(1)) == nil
        }
    }
    test("two optimization attempts per rolling hour persist independently of cooldown") {
        var j = SwitchingJournal()
        for age in [3500.0, 1800.0] { j.append(ManagedSwitch(from: "A", to: "B", inventory: "v4", reason: .optimization, date: now.addingTimeInterval(-age)), now: now) }
        return j.block(reason: .optimization, candidate: "C", inventory: "v4", now: now) != nil && j.block(reason: .failure, candidate: "C", inventory: "v4", now: now) == nil
    }
    test("all automatic attempts including rollback count toward four per hour across subscriptions") {
        var j = SwitchingJournal()
        for i in 0..<4 { j.append(ManagedSwitch(from: "A", to: "B", inventory: "other", reason: i == 0 ? .rollback : .failure, date: now.addingTimeInterval(Double(-1900 - i))), now: now) }
        return j.block(reason: .failure, candidate: "C", inventory: "v4", now: now) != nil && j.block(reason: .optimization, candidate: "C", inventory: "v4", now: now) != nil
    }
    test("manual selection gets thirty minute optimization protection while failures may recover") {
        var j = SwitchingJournal(); j.manualHoldUntil = now.addingTimeInterval(1800)
        return j.block(reason: .optimization, candidate: "B", inventory: "v4", now: now) != nil && j.block(reason: .failure, candidate: "B", inventory: "v4", now: now) == nil && j.block(reason: .optimization, candidate: "B", inventory: "v4", now: now.addingTimeInterval(1800)) == nil
    }
    test("nodes deliberately left are not optimization targets again within an hour") {
        var j = SwitchingJournal(); var item = ManagedSwitch(from: "A", to: "B", inventory: "v4", reason: .optimization, date: now.addingTimeInterval(-1800)); item.status = .verified; j.append(item, now: now)
        return j.block(reason: .optimization, candidate: "A", inventory: "v4", now: now) != nil && j.block(reason: .optimization, candidate: "C", inventory: "v4", now: now) == nil && j.block(reason: .optimization, candidate: "A", inventory: "v4", now: now.addingTimeInterval(1800)) == nil
    }
    test("restarting cannot erase pending budgets or manual selection protection") {
        var state = StoredState(); var j = SwitchingJournal(); j.manualHoldUntil = now.addingTimeInterval(1800)
        j.append(ManagedSwitch(from: "A", to: "B", inventory: "v4", reason: .optimization, date: now), now: now); state.switchingJournal = j
        let loaded = try JSONDecoder().decode(StoredState.self, from: JSONEncoder().encode(state))
        return loaded.switchingJournal?.records.first?.status == .pending && loaded.switchingJournal?.block(reason: .optimization, candidate: "C", inventory: "v4", now: now) != nil
    }
    test("clock rollback cannot silently bypass automatic limits") {
        var j = SwitchingJournal(); j.records = [ManagedSwitch(from: "A", to: "B", inventory: "v4", reason: .failure, date: now.addingTimeInterval(3600))]
        return j.block(reason: .failure, candidate: "C", inventory: "v4", now: now) != nil
    }
    test("legacy successful recovery events seed the new cooldown without parsing names") {
        let liveNow = Date(); let j = SwitchingJournal.migratingLegacy([GuardEvent(level: "info", message: "已自动切换前置：PRIVATE-NODE → PRIVATE-TARGET"), GuardEvent(level: "info", message: "其他事件")], inventory: "v4", now: liveNow.addingTimeInterval(1))
        return j.records.count == 1 && j.records[0].from == "legacy-origin" && j.block(reason: .optimization, candidate: "B", inventory: "v4", now: liveNow.addingTimeInterval(2)) != nil
    }
    test("optimization planner fills the current baseline first and spaces network tests") {
        let a = OptimizationProbePlanner.next(current: "A", eligible: ["B"], history: fast, inventory: "v4", settings: settings, now: now)
        let b = OptimizationProbePlanner.next(current: "A", eligible: ["B"], history: baseline + [fast[0]], inventory: "v4", settings: settings, now: now)
        let c = OptimizationProbePlanner.next(current: "A", eligible: ["B"], history: baseline + [fast[0]], inventory: "v4", settings: settings, now: now.addingTimeInterval(120))
        return a == "A" && b == nil && c == "B"
    }
    test("optimization planner does not keep testing complete fresh evidence") {
        OptimizationProbePlanner.next(current: "A", eligible: ["B"], history: baseline + fast, inventory: "v4", settings: settings, now: now) == nil
    }
    test("empty AI sessions and small heartbeats allow a twenty second switching window") {
        var gate = SwitchQuietGate(); var ready = false
        for i in 0...10 { ready = try gate.sample(fixture(connectionChain: ["Comcast住宅"], upload: UInt64(i * 100)), ownPorts: [], now: now.addingTimeInterval(Double(i * 2))) }
        return ready
    }
    test("actual AI byte transfers reset the switch window immediately") {
        var gate = SwitchQuietGate()
        for i in 0...10 { _ = try gate.sample(fixture(), ownPorts: [], now: now.addingTimeInterval(Double(i * 2))) }
        return try !gate.sample(fixture(connectionChain: ["Comcast住宅"], download: 100_000), ownPorts: [], now: now.addingTimeInterval(22))
    }
    test("own probe connections are excluded from quiet-window traffic") {
        var gate = SwitchQuietGate(); var ready = false
        for i in 0...10 { ready = try gate.sample(fixture(connectionChain: ["Comcast住宅"], upload: UInt64(i * 100_000)), ownPorts: [45678], now: now.addingTimeInterval(Double(i * 2))) }
        return ready
    }
    test("a sampling outage cannot count as an observed quiet interval") {
        var gate = SwitchQuietGate(); _ = try gate.sample(fixture(), ownPorts: [], now: now)
        return try !gate.sample(fixture(), ownPorts: [], now: now.addingTimeInterval(20))
    }
    test("benchmark HTTP or local failures do not become poor-upload recovery evidence") {
        var m = fast[0]; m.diagnostics?.removeAll { $0.stage == .upload }
        for kind in [ProbeFailureKind.endpoint, .local, .invalid] {
            var x = m; x.diagnostics?.append(StageResult(stage: .upload, status: .failed, endpoint: .bingoUpload, failure: ProbeFailure(kind: kind, detail: "fixture")))
            if UploadRecoveryEvidence.poor(x, maxUpload: 15) != nil { return false }
        }
        return UploadRecoveryEvidence.poor(m, maxUpload: 15) == nil && UploadRecoveryEvidence.poor(v4Record("A", date: now, up: 18), maxUpload: 15) == true && UploadRecoveryEvidence.poor(v4Record("A", date: now, success: false), maxUpload: 15) == true
    }
    test("v4 settings migration preserves master pin and strict state and defaults best-node management on") {
        var raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]; raw.removeValue(forKey: "preferBestNode"); raw["settingsVersion"] = 4
        let loaded = try JSONDecoder().decode(GuardSettings.self, from: JSONSerialization.data(withJSONObject: raw))
        return loaded.autoSwitch && loaded.preferBestNode && !loaded.strictProtection && loaded.allowedClaudeIPs == settings.allowedClaudeIPs
    }
    test("v4 exported automatic decisions contain aliases and enums but no node names or pins") {
        var state = StoredState(); state.settings = settings; var j = SwitchingJournal(); j.append(ManagedSwitch(from: "PRIVATE-NODE?password=FAKE", to: "PRIVATE-TARGET", inventory: "PRIVATE-SUB", reason: .optimization, date: now), now: now); state.switchingJournal = j
        let output = String(decoding: try DiagnosticExport.data(state: state, version: "0.4.0", connected: true, network: "Wi-Fi", protection: .disabled), as: UTF8.self)
        return output.contains("automatic_switches") && output.contains("optimization") && !["PRIVATE", "password", "203.0.113.8"].contains(where: output.contains)
    }
}
