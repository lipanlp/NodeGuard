import Foundation
import NodeGuardCore

private func v45Upload(_ name: String, passed: Bool, date: Date, key: String = "v3") -> NodeMeasurement {
    var m = v3Record(name, success: passed, date: date, key: key)
    m.diagnostics? += [StageResult(stage: .upload, status: passed ? .passed : .failed, endpoint: .cloudflareUpload)]
    return m
}
private func v45Deferred(_ name: String, date: Date) -> NodeMeasurement {
    var m = v3Record(name, date: date); m.diagnostics? += [StageResult(stage: .upload, status: .deferred, endpoint: .cloudflareUpload)]; return m
}
private func v45Queue(_ nodes: [String]) -> FullScanQueue { var q = FullScanQueue(); q.replace(SubscriptionInventory(key: "v3", name: "demo", nodes: nodes)); return q }
func runV45Cases() {
    let now = Date(); let hours6 = 21600.0
    let opened = now.addingTimeInterval(-100)
    func status(_ rows: [NodeMeasurement]) -> LineAlertStatus { SharedFailureDetector.lineStatus(rows, line: "中转线路2", since: opened, inventory: "v3", now: now) }
    let failures = [v45Upload("中转线路2-台湾01", passed: false, date: now.addingTimeInterval(-300)), v45Upload("中转线路2-台湾02", passed: false, date: now.addingTimeInterval(-200)), v45Upload("中转线路2-日本01", passed: false, date: now.addingTimeInterval(-100))]
    test("a round without a deferred retry waits the full scan interval") {
        var q = v45Queue(["A"]); q.finish(node: "A", inventoryKey: "v3", interval: hours6, now: now)
        return q.finishRound(performanceRetry: nil, now: now) == nil && q.nextRound == now.addingTimeInterval(hours6)
    }
    test("an expired performance retry earns one early round and is consumed") {
        var q = v45Queue(["A"]); q.finish(node: "A", inventoryKey: "v3", interval: hours6, now: now)
        let left = q.finishRound(performanceRetry: now.addingTimeInterval(-60000), now: now)
        return left == nil && q.nextRound == now.addingTimeInterval(15)
    }
    test("rounds return to the scan interval instead of looping on a stale retry deadline") {
        var q = v45Queue(["A"]); var retry: Date? = now.addingTimeInterval(-60000); var clock = now; var gaps: [TimeInterval] = []
        for _ in 0..<4 {
            q.finish(node: "A", inventoryKey: "v3", interval: hours6, now: clock)
            retry = q.finishRound(performanceRetry: retry, now: clock)
            let due = q.nextRound!; gaps.append(due.timeIntervalSince(clock)); clock = due
            q.beginDueRound(now: clock); retry = FullScanQueue.activeRetry(retry, now: clock)
        }
        return gaps == [15, hours6, hours6, hours6]
    }
    test("a retry deadline still in force delays the next round to it and is spent when that round starts") {
        var q = v45Queue(["A"]); let until = now.addingTimeInterval(120)
        q.finish(node: "A", inventoryKey: "v3", interval: hours6, now: now)
        let kept = q.finishRound(performanceRetry: until, now: now)
        guard kept == until, q.nextRound == until else { return false }
        q.beginDueRound(now: until); let started = !q.pending.isEmpty
        let spent = FullScanQueue.activeRetry(kept, now: until)
        q.finish(node: "A", inventoryKey: "v3", interval: hours6, now: until)
        return started && spent == nil && q.finishRound(performanceRetry: spent, now: until) == nil && q.nextRound == until.addingTimeInterval(hours6)
    }
    test("line failures name the line and round-trip through the incident key") {
        let result = SharedFailureDetector.assess(failures, inventory: "v3", now: now)
        let key = SharedFailureDetector.lineIncidentKey("中转线路2")
        return result?.line == "中转线路2" && SharedFailureDetector.line(fromIncidentKey: key) == "中转线路2" && SharedFailureDetector.line(fromIncidentKey: "shared") == nil
    }
    test("a shared fault across lines names no line") {
        let rows = [v45Upload("甲-01", passed: false, date: now.addingTimeInterval(-200)), v45Upload("丙-01", passed: false, date: now.addingTimeInterval(-100)), v45Upload("丁-01", passed: false, date: now)]
        return SharedFailureDetector.assess(rows, inventory: "v3", now: now)?.line == nil
    }
    test("a line alert stays open on the failures that opened it") { status(failures) == .failing }
    test("the scan moving on to other lines is not recovery") {
        let later = (0..<5).map { v45Upload("中转线路3-节点0\($0)", passed: true, date: now.addingTimeInterval(Double(-50 + $0))) }
        return SharedFailureDetector.assess(failures + later, inventory: "v3", now: now) == nil && status(failures + later) == .failing
    }
    test("one passing node on a failing line is not recovery yet") {
        status(failures + [v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-10))]) == .failing
    }
    test("the same node passing twice counts once") {
        status(failures + [v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-20)), v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-10))]) == .failing
    }
    test("two different nodes of the line passing after the alert prove recovery") {
        status(failures + [v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-20)), v45Upload("中转线路2-香港02", passed: true, date: now.addingTimeInterval(-10))]) == .recovered
    }
    test("a pass followed by a failure keeps the line alert open") {
        status(failures + [v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-20)), v45Upload("中转线路2-香港02", passed: false, date: now.addingTimeInterval(-10))]) == .failing
    }
    test("passes from before the alert opened do not count as recovery") {
        status([v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-400)), v45Upload("中转线路2-香港02", passed: true, date: now.addingTimeInterval(-350)), v45Upload("中转线路2-日本01", passed: false, date: now.addingTimeInterval(-100))]) == .failing
            && status([v45Upload("中转线路2-香港01", passed: true, date: now.addingTimeInterval(-400)), v45Upload("中转线路2-香港02", passed: true, date: now.addingTimeInterval(-350))]) == .failing
    }
    test("deferred uploads and other lines or subscriptions are not evidence about the line") {
        let noise = [v45Deferred("中转线路2-香港01", date: now.addingTimeInterval(-30)), v45Upload("中转线路1-香港01", passed: true, date: now.addingTimeInterval(-20)), v45Upload("中转线路2-香港02", passed: true, date: now.addingTimeInterval(-10), key: "other")]
        return status(noise) == .unobserved && status(failures + noise) == .failing
    }
    test("a line with no upload result for 15 minutes is unobserved rather than recovered") {
        let old = failures.map { m -> NodeMeasurement in var c = m; c.date = now.addingTimeInterval(-901); return c }
        return status(old) == .unobserved
    }
    test("closing an incident as unobserved records that it was never verified") {
        var rows: [GuardIncident] = []
        _ = IncidentLedger.raise(&rows, key: "line:中转线路2", level: "warning", message: "x", now: now)
        let closed = IncidentLedger.close(&rows, key: "line:中转线路2", reason: "unobserved", now: now)
        return closed?.resolutionReason == "unobserved" && closed?.resolvedAt == now && IncidentLedger.resolve(&rows, key: "line:中转线路2", now: now) == nil
    }
    test("switching front does not reopen an alert raised without a front") {
        var rows: [GuardIncident] = []
        let first = IncidentLedger.raise(&rows, key: "line:中转线路2", level: "warning", message: "x", now: now, inventory: "v3", front: nil)
        let second = IncidentLedger.raise(&rows, key: "line:中转线路2", level: "warning", message: "y", now: now.addingTimeInterval(5), inventory: "v3", front: nil)
        return first == .opened && second == .updated && rows.count == 1
    }
}
