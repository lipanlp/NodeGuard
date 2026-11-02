import Foundation
import NodeGuardCore

func runBackupRecoveryCases() {
    let now = Date(); var settings = GuardSettings(); settings.autoSwitch = true; settings.allowedClaudeIPs = ["203.0.113.8"]; settings.candidates = ["B", "C"]
    var slow = v3Record("B", date: now.addingTimeInterval(-120)); slow.uploadSeconds = 22
    var health = v3Record("B", kind: .health, date: now); health.uploadSeconds = 0; health.downloadMbps = 0
    test("slow but proven bidirectional nodes remain outage recovery candidates") {
        BackupPlanner.quality(name: "B", history: [slow], inventory: "v3", settings: settings, now: now) == nil && BackupPlanner.recoveryQuality(name: "B", history: [slow], inventory: "v3", settings: settings, now: now) != nil
    }
    test("slow fallback requires explicit outage recovery and remains forbidden for performance switching") {
        let s = try fixture()
        return !FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", quality: slow, health: health, now: now) && FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", quality: slow, health: health, allowSlowRecovery: true, now: now)
    }
    test("outage fallback never bypasses the exact locked IP") {
        var h = health; h.ip = "203.0.113.9"
        return try !FailoverPolicy.mayCommit(settings: settings, snapshot: fixture(), old: "A", quality: slow, health: h, allowSlowRecovery: true, now: now)
    }
    test("outage fallback never bypasses the fresh thirty second health limit") {
        var h = health; h.date = now.addingTimeInterval(-31)
        return try !FailoverPolicy.mayCommit(settings: settings, snapshot: fixture(), old: "A", quality: slow, health: h, allowSlowRecovery: true, now: now)
    }
    test("slow recovery nodes are counted ready after recent healthy pin proof") {
        BackupPlanner.pool(available: ["A", "B"], current: "A", settings: settings, history: [slow], health: [health], inventory: "v3", requireReady: true, now: now) == ["B"]
    }
    test("stale health is shown as pending rather than dead or ready") {
        var h = health; h.date = now.addingTimeInterval(-700)
        return BackupPlanner.pool(available: ["A", "B"], current: "A", settings: settings, history: [slow], health: [h], inventory: "v3", requireReady: true, now: now).isEmpty && BackupPlanner.readiness(name: "B", history: [slow], health: [h], inventory: "v3", settings: settings, now: now).contains("过期")
    }
    test("missing initial health is explicitly awaiting verification") {
        BackupPlanner.readiness(name: "B", history: [slow], health: [], inventory: "v3", settings: settings, now: now).contains("首次")
    }
    test("ready slow fallback is not described as a better performance node") {
        BackupPlanner.readiness(name: "B", history: [slow], health: [health], inventory: "v3", settings: settings, now: now).contains("不据此主动择优")
    }
    test("a benchmark endpoint failure does not erase a recent proven outage baseline") {
        var failure = v3Record("B", success: false, date: now.addingTimeInterval(-10)); failure.diagnostics?.append(StageResult(stage: .upload, status: .failed, endpoint: .bingoUpload, failure: ProbeFailure(kind: .endpoint, detail: "fixture")))
        return BackupPlanner.recoveryQuality(name: "B", history: [failure, slow], inventory: "v3", settings: settings, now: now)?.date == slow.date && BackupPlanner.quality(name: "B", history: [failure, slow], inventory: "v3", settings: settings, now: now) == nil
    }
    test("a confirmed newer IP mismatch invalidates even an otherwise good older baseline") {
        var failure = slow; failure.date = now; failure.ip = "203.0.113.9"
        return BackupPlanner.recoveryQuality(name: "B", history: [failure, slow], inventory: "v3", settings: settings, now: now) == nil
    }
    test("outage recovery refuses expired or foreign subscription baselines") {
        var old = slow; old.date = now.addingTimeInterval(-21601)
        return BackupPlanner.recoveryQuality(name: "B", history: [old], inventory: "v3", settings: settings, now: now) == nil && BackupPlanner.recoveryQuality(name: "B", history: [slow], inventory: "other", settings: settings, now: now) == nil
    }
    test("failed current health removes readiness without claiming every subscribed node failed") {
        var h = health; h.success = false
        return BackupPlanner.pool(available: ["A", "B"], current: "A", settings: settings, history: [slow], health: [h], inventory: "v3", requireReady: true, now: now).isEmpty && BackupPlanner.recoveryCandidates(available: ["A", "B"], current: "A", settings: settings, history: [slow], health: [h], inventory: "v3", hard: true, now: now) == ["B"]
    }
    test("all slow nodes do not trigger performance-only churn") {
        BackupPlanner.recoveryCandidates(available: ["A", "B"], current: "A", settings: settings, history: [slow], health: [health], inventory: "v3", hard: false, now: now).isEmpty
    }
    test("outage recovery considers allowed nodes beyond the displayed five-slot pool") {
        let names = (0..<7).map { "备用\($0)" }; let rows = names.map { v3Record($0, date: now) }
        let excluded = Set(names.prefix(5))
        let result = BackupPlanner.recoveryCandidates(available: ["A"] + names, current: "A", settings: settings, history: rows, health: [], inventory: "v3", hard: true, excluding: excluded, now: now)
        return Set(result) == Set(names.suffix(2))
    }
    test("manual-only operation never expands the authorized candidate list") {
        var manual = settings; manual.automaticBackupPool = false; manual.candidates = ["B"]
        return BackupPlanner.recoveryCandidates(available: ["A", "B", "C"], current: "A", settings: manual, history: [slow], health: [], inventory: "v3", hard: true, now: now) == ["B"]
    }
    test("quarantine excludes a stale healthy cache from the displayed ready pool") {
        BackupPlanner.pool(available: ["A", "B"], current: "A", settings: settings, history: [slow], health: [health], inventory: "v3", requireReady: true, excluding: ["B"], now: now).isEmpty
    }
    test("missing performance cannot authorize a switch even in outage mode") {
        var partial = slow; partial.success = false; partial.downloadMbps = 0
        return try !FailoverPolicy.mayCommit(settings: settings, snapshot: fixture(), old: "A", quality: partial, health: health, allowSlowRecovery: true, now: now)
    }
    test("mainland health or baseline cannot authorize an outage switch") {
        var h = health; h.country = "CN"; var q = slow; q.country = "CN"; let s = try fixture()
        return !FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", quality: slow, health: h, allowSlowRecovery: true, now: now) && !FailoverPolicy.mayCommit(settings: settings, snapshot: s, old: "A", quality: q, health: health, allowSlowRecovery: true, now: now)
    }
}
