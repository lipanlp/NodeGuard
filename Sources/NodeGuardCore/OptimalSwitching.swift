import Foundation

public enum ManagedSwitchReason: String, Codable { case optimization, failure, rollback }
public enum ManagedSwitchStatus: String, Codable { case pending, verified, failed }
public struct ManagedSwitch: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let inventoryKey: String?
    public let from: String
    public let to: String
    public let reason: ManagedSwitchReason
    public var status: ManagedSwitchStatus
    public init(from: String, to: String, inventory: String?, reason: ManagedSwitchReason, date: Date = Date()) { id = UUID(); self.date = date; inventoryKey = inventory; self.from = from; self.to = to; self.reason = reason; status = .pending }
}
public struct SwitchingJournal: Codable {
    public var records: [ManagedSwitch] = []
    public var observedFront: String?
    public var observedInventory: String?
    public var manualHoldUntil: Date?
    public init() {}
    public static func migratingLegacy(_ events: [GuardEvent], inventory: String?, now: Date = Date()) -> SwitchingJournal {
        var journal = SwitchingJournal()
        // Preserve recent recovery timestamps from older versions without parsing names.
        for event in events where event.message.hasPrefix("已自动切换前置：") || event.message.hasPrefix("已故障切换前置：") {
            guard now.timeIntervalSince(event.date) >= -60, now.timeIntervalSince(event.date) < 3600 else { continue }
            var item = ManagedSwitch(from: "legacy-origin", to: "legacy-target", inventory: inventory, reason: .failure, date: event.date)
            item.status = .verified; journal.append(item, now: now)
        }
        return journal
    }
    public mutating func append(_ item: ManagedSwitch, now: Date = Date()) {
        records = Array(([item] + records).filter { now.timeIntervalSince($0.date) >= -60 && now.timeIntervalSince($0.date) < 172800 }.prefix(200))
    }
    public mutating func finish(_ id: UUID, verified: Bool) { if let i = records.firstIndex(where: { $0.id == id }) { records[i].status = verified ? .verified : .failed } }
    public func block(reason: ManagedSwitchReason, candidate: String?, inventory: String?, now: Date = Date()) -> String? {
        if records.contains(where: { $0.date.timeIntervalSince(now) > 60 }) { return "切换记录时间异常，暂停自动操作，请检查本机时间" }
        let hour = records.filter { now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) < 3600 }
        if hour.count >= 4 { return "本小时自动操作已达 4 次上限，暂停自动切换" }
        if reason == .optimization {
            if let until = manualHoldUntil, until > now { return "尊重手动选择，\(Int(ceil(until.timeIntervalSince(now) / 60))) 分钟后再择优" }
            if hour.filter({ $0.reason == .optimization }).count >= 2 { return "本小时择优尝试已达 2 次上限" }
            if let latest = records.filter({ $0.reason != .rollback }).map(\.date).max(), now.timeIntervalSince(latest) < 1800 { return "自动切换冷却中，满 30 分钟后再择优" }
            if let candidate = candidate, records.contains(where: { $0.inventoryKey == inventory && $0.from == candidate && $0.status == .verified && now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) < 3600 }) { return "该节点刚被离开，60 分钟内不主动切回" }
        }
        return nil
    }
}

public struct StableNodePerformance {
    public let name: String
    public let score: Double
    public let uploadSeconds: Double
    public let downloadMbps: Double
    public let latencyMS: Double
    public let successfulSamples: Int
    public let newestDate: Date
    public let uploadEndpoint: DiagnosticEndpoint
    public let downloadEndpoint: DiagnosticEndpoint
    public static func collect(name: String, history: [NodeMeasurement], inventory: String?, allowedIPs: [String], candidate: Bool, maxUpload: Double, now: Date = Date()) -> StableNodePerformance? {
        let rows = history.filter { $0.name == name && $0.inventoryKey == inventory && $0.kind == .full && $0.performanceDeferred != true && now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) <= 7200 }.sorted { $0.date > $1.date }
        guard let latest = rows.first, latest.hasFullPerformance, now.timeIntervalSince(latest.date) <= 1800,
              latest.country != "CN", allowedIPs.contains(latest.ip ?? ""), latest.passed(.residential), latest.passed(.claude),
              let uploadEndpoint = latest.stages.last(where: { $0.stage == .upload && $0.status == .passed })?.endpoint,
              let downloadEndpoint = latest.stages.last(where: { $0.stage == .download && $0.status == .passed })?.endpoint else { return nil }
        if candidate && latest.uploadSeconds > maxUpload { return nil }
        var spaced: [NodeMeasurement] = []
        for row in rows where row.hasFullPerformance && now.timeIntervalSince(row.date) <= 1800 && row.country != "CN" && allowedIPs.contains(row.ip ?? "") {
            guard row.stages.last(where: { $0.stage == .upload && $0.status == .passed })?.endpoint == uploadEndpoint,
                  row.stages.last(where: { $0.stage == .download && $0.status == .passed })?.endpoint == downloadEndpoint else { continue }
            if spaced.allSatisfy({ abs($0.date.timeIntervalSince(row.date)) >= 60 }) { spaced.append(row) }
            if spaced.count == 3 { break }
        }
        guard spaced.count >= 2 else { return nil }
        func median(_ values: [Double]) -> Double { let v = values.sorted(); let i = v.count / 2; return v.count % 2 == 0 ? (v[i - 1] + v[i]) / 2 : v[i] }
        let up = median(spaced.map(\.uploadSeconds)), down = median(spaced.map(\.downloadMbps)), latency = median(spaced.map(\.latencyMS))
        if candidate && up > maxUpload { return nil }
        let recent = Array(rows.prefix(5)); let reliability = Double(recent.filter(\.success).count) / Double(recent.count)
        let uploadPart: Double = min(1.0, 3.0 / max(0.1, up)) * 0.45
        let downloadPart: Double = min(1.0, down / 20.0) * 0.20
        let latencyPart: Double = min(1.0, 600.0 / max(1.0, latency)) * 0.15
        let score: Double = (uploadPart + downloadPart + latencyPart + reliability * 0.20) * 100.0
        return StableNodePerformance(name: name, score: score, uploadSeconds: up, downloadMbps: down, latencyMS: latency, successfulSamples: spaced.count, newestDate: latest.date, uploadEndpoint: uploadEndpoint, downloadEndpoint: downloadEndpoint)
    }
    public func clearlyBeats(_ current: StableNodePerformance) -> Bool {
        let gain = score - current.score
        guard uploadEndpoint == current.uploadEndpoint, downloadEndpoint == current.downloadEndpoint, gain >= 10, score >= current.score * 1.2 else { return false }
        return uploadSeconds <= current.uploadSeconds * 0.8 ||
            (downloadMbps >= current.downloadMbps * 1.5 && uploadSeconds <= current.uploadSeconds * 1.1 && latencyMS <= current.latencyMS * 1.25) ||
            (latencyMS <= current.latencyMS * 0.6 && uploadSeconds <= current.uploadSeconds * 1.1)
    }
}

public enum OptimizationProbePlanner {
    public static func next(current: String, eligible: [String], history: [NodeMeasurement], inventory: String?, settings: GuardSettings, now: Date = Date()) -> String? {
        func newest(_ name: String) -> Date { history.filter { $0.name == name && $0.inventoryKey == inventory && $0.kind == .full && $0.performanceDeferred != true }.map(\.date).max() ?? .distantPast }
        func needsEvidence(_ name: String, candidate: Bool) -> Bool {
            StableNodePerformance.collect(name: name, history: history, inventory: inventory, allowedIPs: settings.allowedClaudeIPs, candidate: candidate, maxUpload: settings.slowUploadSeconds, now: now) == nil || now.timeIntervalSince(newest(name)) >= 900
        }
        let ranked = eligible.filter { $0 != current }.compactMap { name -> NodeMeasurement? in BackupPlanner.quality(name: name, history: history, inventory: inventory, settings: settings, now: now) }.sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }.prefix(3).map(\.name)
        let names = [current] + ranked
        return names.first { now.timeIntervalSince(newest($0)) >= 120 && needsEvidence($0, candidate: $0 != current) }
    }
}

public struct BestNodeDecision {
    public let candidate: String?
    public let message: String
    public let currentScore: Double?
    public let candidateScore: Double?
}
public struct BestNodeTracker {
    public private(set) var leader: String?
    public private(set) var leaderSince: Date?
    private var context: String?
    public init() {}
    public mutating func reset() { self = BestNodeTracker() }
    public mutating func evaluate(current: String, eligible: [String], history: [NodeMeasurement], inventory: String?, settings: GuardSettings, journal: SwitchingJournal, idle: Bool, stableSince: Date, now: Date = Date()) -> BestNodeDecision {
        func wait(_ text: String, currentScore: Double? = nil, candidateScore: Double? = nil) -> BestNodeDecision { BestNodeDecision(candidate: nil, message: text, currentScore: currentScore, candidateScore: candidateScore) }
        let key = (inventory ?? "unknown") + "\u{0}" + current
        if context != key { reset(); context = key }
        guard settings.autoSwitch && settings.preferBestNode else { reset(); return wait("自动择优未开启") }
        guard now.timeIntervalSince(stableSince) >= 180 else { leader = nil; leaderSince = nil; return wait("等待路由稳定 3 分钟后评估") }
        if let blocked = journal.block(reason: .optimization, candidate: nil, inventory: inventory, now: now) { leader = nil; leaderSince = nil; return wait(blocked) }
        guard let baseline = StableNodePerformance.collect(name: current, history: history, inventory: inventory, allowedIPs: settings.allowedClaudeIPs, candidate: false, maxUpload: settings.slowUploadSeconds, now: now) else { leader = nil; leaderSince = nil; return wait("当前节点需两次间隔至少 1 分钟的完整测速，先补测") }
        let ranked = eligible.filter { $0 != current }.compactMap { name -> StableNodePerformance? in
            guard journal.block(reason: .optimization, candidate: name, inventory: inventory, now: now) == nil else { return nil }
            return StableNodePerformance.collect(name: name, history: history, inventory: inventory, allowedIPs: settings.allowedClaudeIPs, candidate: true, maxUpload: settings.slowUploadSeconds, now: now)
        }.sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
        guard let best = ranked.first else { leader = nil; leaderSince = nil; return wait("等待候选的两次完整测速与锁定出口证据", currentScore: baseline.score) }
        guard best.clearlyBeats(baseline) else { leader = nil; leaderSince = nil; return wait("评分接近或性能优势不足，保持当前节点", currentScore: baseline.score, candidateScore: best.score) }
        if leader != best.name { leader = best.name; leaderSince = now }
        let held = now.timeIntervalSince(leaderSince ?? now)
        guard held >= 180 else { return wait("候选优势观察中，尚需 \(Int(ceil((180 - held) / 60))) 分钟", currentScore: baseline.score, candidateScore: best.score) }
        guard idle else { return wait("优势已确认，等待低负载与 AI 传输安静窗口", currentScore: baseline.score, candidateScore: best.score) }
        return BestNodeDecision(candidate: best.name, message: String(format: "优势已确认：%.1f → %.1f 分，准备复验后择优", baseline.score, best.score), currentScore: baseline.score, candidateScore: best.score)
    }
}

public struct SwitchQuietGate {
    private var lastCounts: [String: ByteCounters] = [:]
    private var lastDate: Date?
    private var quietSince: Date?
    public init() {}
    public mutating func reset() { self = SwitchQuietGate() }
    public mutating func sample(_ snapshot: CoreSnapshot, ownPorts: Set<Int>, now: Date = Date()) -> Bool {
        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 0
        if elapsed <= 0 || elapsed > 6 { quietSince = now }
        var activeBytes: UInt64 = 0; var next: [String: ByteCounters] = [:]
        for c in snapshot.connections {
            if let p = c.metadata.sourcePort.flatMap(Int.init), ownPorts.contains(p) { continue }
            let host = (c.metadata.host ?? "").lowercased()
            guard ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com", "chatgpt.com", "openai.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { continue }
            let bytes = ByteCounters(up: c.upload ?? 0, down: c.download ?? 0); next[c.id] = bytes
            let old = lastCounts[c.id] ?? ByteCounters(up: 0, down: 0)
            activeBytes += (bytes.up >= old.up ? bytes.up - old.up : 0) + (bytes.down >= old.down ? bytes.down - old.down : 0)
        }
        if quietSince == nil || (elapsed > 0 && Double(activeBytes) / elapsed >= 2048) { quietSince = now }
        lastDate = now; lastCounts = next
        return now.timeIntervalSince(quietSince ?? now) >= 20
    }
}
