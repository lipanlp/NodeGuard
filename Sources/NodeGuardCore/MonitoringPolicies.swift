import Foundation
import CryptoKit

public extension NodeMeasurement {
    var stages: [StageResult] { diagnostics ?? [] }
    func passed(_ stage: DiagnosticStage) -> Bool { stages.contains { $0.stage == stage && $0.status == .passed } }
    var verifiedResidential: Bool { passed(.residential) || (diagnostics == nil && success && ip != nil) }
    var hasFullPerformance: Bool { (kind == nil || kind == .full) && success && uploadSeconds > 0 && downloadMbps > 0 && performanceDeferred != true }
    var outcomeTitle: String {
        if performanceDeferred == true { return "基础检查已完成 · 性能待复测" }
        if success { return kind == .health ? "健康复验通过" : "检查通过" }
        if verifiedResidential { return "出口已验证 · 部分项目异常" }
        if passed(.front) { return "前置连通 · 出口链路待确认" }
        return "检测未通过，详见分层证据"
    }
}

public struct HistorySummary {
    public let total: Int
    public let successes: Int
    public let lastSuccess: Date?
    public let medianMS: Double?
    public let p95MS: Double?
    public let jitterMS: Double?
    public var ratio: Double? { total == 0 ? nil : Double(successes) / Double(total) }
    public static func calculate(_ records: [NodeMeasurement], name: String, inventory: String?, now: Date = Date()) -> HistorySummary {
        let values = records.filter { $0.name == name && $0.inventoryKey == inventory && ($0.kind == nil || $0.kind == .full) && $0.performanceDeferred != true && now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) <= 86400 }.sorted { $0.date > $1.date }.prefix(20)
        let successful = values.filter(\.success); let times = values.filter { $0.latencyMS > 0 && $0.latencyMS.isFinite }.map(\.latencyMS).sorted()
        func percentile(_ fraction: Double) -> Double? { times.isEmpty ? nil : times[min(times.count - 1, Int(ceil(Double(times.count) * fraction)) - 1)] }
        var jitter: Double?
        if times.count >= 2 { let mean = times.reduce(0, +) / Double(times.count); jitter = sqrt(times.reduce(0) { $0 + pow($1 - mean, 2) } / Double(times.count)) }
        return HistorySummary(total: values.count, successes: successful.count, lastSuccess: successful.map(\.date).max(), medianMS: percentile(0.5), p95MS: percentile(0.95), jitterMS: jitter)
    }
}
public enum MeasurementHistory {
    public static func append(_ record: NodeMeasurement, to records: [NodeMeasurement], now: Date = Date()) -> [NodeMeasurement] {
        var counts: [String: Int] = [:]
        return ([record] + records).filter { now.timeIntervalSince($0.date) <= 172800 && now.timeIntervalSince($0.date) >= -60 }.sorted { $0.date > $1.date }.filter { r in
            let key = "\(r.inventoryKey ?? "legacy")\u{0}\(r.name)\u{0}\(r.kind?.rawValue ?? "full")"
            counts[key, default: 0] += 1
            return counts[key]! <= (r.kind == .health ? 36 : 20)
        }.prefix(4000).map { $0 }
    }
}

public enum UploadRecoveryEvidence {
    // Endpoint errors, local errors and unrelated stages cannot prove poor uploads.
    public static func poor(_ record: NodeMeasurement, maxUpload: Double) -> Bool? {
        let uploads = record.stages.filter { $0.stage == .upload }
        if uploads.contains(where: { $0.status == .passed }) { return record.uploadSeconds > maxUpload }
        let failed = uploads.filter { $0.status == .failed }
        guard !failed.isEmpty, failed.allSatisfy({ [.timeout, .tls, .network].contains($0.failureKind) }) else { return nil }
        return true
    }
}

public enum ProtectionPhase: String, Codable {
    case disabled, verifying, armed, unverified, holding, tripped, sleeping
    public var title: String { switch self { case .disabled: return "未武装"; case .verifying: return "正在复验"; case .armed: return "严格保护已武装"; case .unverified: return "暂时无法验证"; case .holding: return "出口不通，保留 Claude"; case .tripped: return "保护已触发"; case .sleeping: return "睡眠暂停，唤醒后复验" } }
}
/// Terminates Claude only on positive evidence (changed IP, mainland exit, route bypass) or when the
/// Clash route itself cannot be inspected. Exit probes that merely fail keep Claude running and ask
/// for a front-node recovery: Claude traffic follows the same broken chain and cannot leak.
public struct StrictProtectionMachine {
    public private(set) var phase: ProtectionPhase = .disabled
    public private(set) var reason = "严格保护未开启"
    public private(set) var lastVerified: Date?
    public private(set) var unknownSince: Date?
    public private(set) var routeUnknownSince: Date?
    public private(set) var needsNetworkRecovery = false
    public init() {}
    public mutating func disable() { self = StrictProtectionMachine() }
    public mutating func beginVerification(_ reason: String, now: Date = Date()) {
        if phase == .sleeping { unknownSince = nil; needsNetworkRecovery = false }
        lastVerified = nil; if unknownSince == nil { unknownSince = now }
        phase = .verifying; self.reason = reason
    }
    public mutating func sleep() { phase = .sleeping; reason = "电脑睡眠中，停止检测负载"; lastVerified = nil; unknownSince = nil; routeUnknownSince = nil; needsNetworkRecovery = false }
    public mutating func verified(at date: Date) { phase = .armed; lastVerified = date; unknownSince = nil; routeUnknownSince = nil; needsNetworkRecovery = false; reason = "锁定出口与真实路由已复验" }
    public mutating func failed(_ kind: ProbeFailureKind, now: Date = Date()) {
        if unknownSince == nil { unknownSince = now }
        guard !needsNetworkRecovery else { return }
        phase = .unverified; reason = kind == .local ? "本地探测错误，正在更换源端口复试" : "出口暂时无法验证，正在有时限复验"
    }
    // The Clash control interface is the only view of Claude's real connections; losing it may mean TUN is gone.
    public mutating func routeUnavailable(now: Date = Date()) {
        if routeUnknownSince == nil { routeUnknownSince = now }
        phase = .unverified; reason = "Clash 控制接口不可用，无法核对 Claude 实际路由"
    }
    public mutating func routeAvailable() { routeUnknownSince = nil }
    public mutating func violation(_ message: String) -> String { phase = .tripped; reason = message; return message }
    public mutating func evaluate(grace: Double, now: Date = Date()) -> String? {
        guard phase != .disabled && phase != .sleeping else { return nil }
        if phase == .tripped { return reason }
        if let since = routeUnknownSince, now.timeIntervalSince(since) >= grace { return violation("连续 \(Int(grace)) 秒无法核对 Claude 实际路由，按严格保护策略退出 Claude") }
        if unknownSince == nil, let proof = lastVerified, now.timeIntervalSince(proof) <= 15 { return nil }
        if unknownSince == nil { unknownSince = lastVerified?.addingTimeInterval(15) ?? now; phase = .unverified; reason = "出口证据过期，正在重新验证" }
        if now.timeIntervalSince(unknownSince!) >= grace {
            needsNetworkRecovery = true
            if routeUnknownSince == nil { phase = .holding; reason = "出口连续 \(Int(grace)) 秒不通，路由与锁定 IP 未见异常；保留 Claude，更换前置后重试" }
        }
        return nil
    }
}

public struct GuardIncident: Codable, Identifiable, Equatable {
    public let id: UUID
    public var key: String
    public var level: String
    public var message: String
    public var firstSeen: Date
    public var lastSeen: Date
    public var count: Int
    public var lastNotified: Date
    public var resolvedAt: Date?
    public var inventoryKey: String?
    public var frontName: String?
    public var resolutionReason: String?
    public init(key: String, level: String, message: String, now: Date, inventory: String? = nil, front: String? = nil) { id = UUID(); self.key = key; self.level = level; self.message = message; firstSeen = now; lastSeen = now; count = 1; lastNotified = now; inventoryKey = inventory; frontName = front }
}
public enum IncidentChange { case opened, escalated, reminder, updated }
/// One failed exit probe only proves that one new connection did not finish; alert on consecutive
/// failures. Strict protection is fed every failure separately and keeps its own deadline.
public struct ExitAlertGate {
    public static let consecutiveFailures = 2
    public private(set) var failures = 0
    public private(set) var firstFailure: Date?
    public init() {}
    public var alerting: Bool { failures >= Self.consecutiveFailures }
    public mutating func failed(now: Date = Date()) -> Bool { failures += 1; if firstFailure == nil { firstFailure = now }; return alerting }
    public mutating func passed() { self = ExitAlertGate() }
}

public enum IncidentLedger {
    // `since` and `observations` describe evidence gathered before a debounced incident was opened.
    public static func raise(_ records: inout [GuardIncident], key: String, level: String, message: String, now: Date = Date(), inventory: String? = nil, front: String? = nil, since: Date? = nil, observations: Int = 1) -> IncidentChange {
        func open() {
            var incident = GuardIncident(key: key, level: level, message: String(message.prefix(600)), now: now, inventory: inventory, front: front)
            if let since = since, since <= now { incident.firstSeen = since }
            incident.count = max(1, min(1_000_000, observations))
            records.insert(incident, at: 0); trim(&records)
        }
        if let i = records.firstIndex(where: { $0.key == key && $0.resolvedAt == nil }) {
            if records[i].inventoryKey != inventory || records[i].frontName != front {
                records[i].resolvedAt = now; records[i].resolutionReason = "contextChanged"
                open(); return .opened
            }
            let escalate = level == "critical" && records[i].level != "critical"
            records[i].count = min(1_000_000, records[i].count + 1); records[i].lastSeen = now; records[i].message = String(message.prefix(600)); records[i].level = level
            let reminder = now.timeIntervalSince(records[i].lastNotified) >= 900
            if escalate || reminder { records[i].lastNotified = now }
            return escalate ? .escalated : (reminder ? .reminder : .updated)
        }
        open(); return .opened
    }
    public static func resolve(_ records: inout [GuardIncident], key: String, now: Date = Date()) -> GuardIncident? {
        guard let i = records.firstIndex(where: { $0.key == key && $0.resolvedAt == nil }) else { return nil }
        records[i].resolvedAt = now; records[i].lastSeen = now; records[i].resolutionReason = "verified"; return records[i]
    }
    private static func trim(_ records: inout [GuardIncident]) { records = Array((records.filter { $0.resolvedAt == nil } + records.filter { $0.resolvedAt != nil }.prefix(200)).prefix(240)) }
}

public enum BackupPlanner {
    /// A recent proven bidirectional baseline for outage recovery. Slowness is
    /// not disconnection; every commit still needs a new health and exact-IP proof.
    public static func recoveryQuality(name: String, history: [NodeMeasurement], inventory: String?, settings: GuardSettings, now: Date = Date()) -> NodeMeasurement? {
        let rows = history.filter { $0.name == name && $0.inventoryKey == inventory && ($0.kind == nil || $0.kind == .full || $0.kind == .upload) && $0.performanceDeferred != true && now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) < 21600 }.sorted { $0.date > $1.date }
        if let latest = rows.first {
            if latest.country == "CN" || latest.ip.map({ !settings.allowedClaudeIPs.contains($0) }) == true || latest.stages.contains(where: { $0.failureKind == .route }) { return nil }
        }
        return rows.first { $0.hasFullPerformance && $0.country != "CN" && settings.allowedClaudeIPs.contains($0.ip ?? "") }
    }
    private static func recentHealth(name: String, health: [NodeMeasurement], inventory: String?, settings: GuardSettings, now: Date) -> NodeMeasurement? {
        guard let row = health.filter({ $0.name == name && $0.inventoryKey == inventory }).max(by: { $0.date < $1.date }), row.success,
              row.country != "CN", settings.allowedClaudeIPs.contains(row.ip ?? ""), now.timeIntervalSince(row.date) >= 0, now.timeIntervalSince(row.date) < settings.backupHealthInterval * 2 else { return nil }
        return row
    }
    public static func recoveryCandidates(available: [String], current: String, settings: GuardSettings, history: [NodeMeasurement], health: [NodeMeasurement], inventory: String?, hard: Bool, excluding: Set<String> = [], now: Date = Date()) -> [String] {
        let allowed = settings.automaticBackupPool ? available : settings.candidates
        let names = Array(Set(allowed)).filter { $0 != current && available.contains($0) && !excluding.contains($0) }
        let evidence = Dictionary(uniqueKeysWithValues: names.compactMap { name in (hard ? recoveryQuality(name: name, history: history, inventory: inventory, settings: settings, now: now) : quality(name: name, history: history, inventory: inventory, settings: settings, now: now)).map { (name, $0) } })
        return names.filter { hard || evidence[$0] != nil }.sorted { a, b in
            func tier(_ name: String) -> Int { evidence[name] == nil ? 2 : (recentHealth(name: name, health: health, inventory: inventory, settings: settings, now: now) == nil ? 1 : 0) }
            let x = tier(a), y = tier(b); if x != y { return x < y }
            let p = evidence[a]?.score ?? -1, q = evidence[b]?.score ?? -1
            return p == q ? a < b : p > q
        }
    }
    public static func readiness(name: String, history: [NodeMeasurement], health: [NodeMeasurement], inventory: String?, settings: GuardSettings, now: Date = Date()) -> String {
        guard let quality = recoveryQuality(name: name, history: history, inventory: inventory, settings: settings, now: now) else { return "暂无有效的完整性能基线，需重新测速并验证锁定 IP" }
        guard recentHealth(name: name, health: health, inventory: inventory, settings: settings, now: now) != nil else {
            if let last = health.filter({ $0.name == name && $0.inventoryKey == inventory }).max(by: { $0.date < $1.date }) {
                if now.timeIntervalSince(last.date) >= settings.backupHealthInterval * 2 { return "健康证据已过期，等待重新验证锁定 IP" }
                return "最近健康/IP 探测未通过，需重新复验"
            }
            return "已有性能基线，等待首次健康/IP 复验"
        }
        return quality.uploadSeconds > settings.slowUploadSeconds || self.quality(name: name, history: history, inventory: inventory, settings: settings, now: now) == nil ? "可作故障备用 · 性能较慢或待复测，不据此主动择优" : "可作故障备用 · 性能与近期出口复验通过"
    }
    public static func quality(name: String, history: [NodeMeasurement], inventory: String?, settings: GuardSettings, now: Date = Date()) -> NodeMeasurement? {
        let records = history.filter { $0.name == name && $0.inventoryKey == inventory && ($0.kind == nil || $0.kind == .full || $0.kind == .upload) && $0.performanceDeferred != true }.sorted { $0.date > $1.date }
        guard let latest = records.first, latest.success, latest.uploadSeconds <= settings.slowUploadSeconds,
              let full = records.first(where: { $0.kind == nil || $0.kind == .full }), full.hasFullPerformance,
              now.timeIntervalSince(full.date) >= 0, now.timeIntervalSince(full.date) < 21600,
              full.uploadSeconds <= settings.slowUploadSeconds, full.country != "CN", settings.allowedClaudeIPs.contains(full.ip ?? "") else { return nil }
        return full
    }
    public static func region(_ name: String) -> String {
        for word in ["香港", "台湾", "日本", "韩国", "新加坡", "美国", "英国", "德国", "🇭🇰", "🇹🇼", "🇯🇵", "🇰🇷", "🇸🇬", "🇺🇸", "🇬🇧", "🇩🇪"] { if name.contains(word) { return word } }
        return "其他"
    }
    public static func pool(available: [String], current: String, settings: GuardSettings, history: [NodeMeasurement], health: [NodeMeasurement], inventory: String?, requireReady: Bool = false, excluding: Set<String> = [], now: Date = Date()) -> [String] {
        let allowed = settings.automaticBackupPool ? available : settings.candidates
        var choices = Array(Set(allowed)).filter { available.contains($0) && $0 != current && !excluding.contains($0) }
        choices = choices.filter { name in
            let quality = recoveryQuality(name: name, history: history, inventory: inventory, settings: settings, now: now)
            if requireReady { return quality != nil && recentHealth(name: name, health: health, inventory: inventory, settings: settings, now: now) != nil }
            return quality != nil || history.contains { $0.name == name && $0.inventoryKey == inventory && $0.verifiedResidential } || settings.candidates.contains(name)
        }
        let qualities = Dictionary(uniqueKeysWithValues: choices.compactMap { name in recoveryQuality(name: name, history: history, inventory: inventory, settings: settings, now: now).map { (name, $0) } })
        choices.sort { a, b in
            if (qualities[a] != nil) != (qualities[b] != nil) { return qualities[a] != nil }
            let x = qualities[a]?.score ?? history.first { $0.name == a && $0.inventoryKey == inventory }?.score ?? -1
            let y = qualities[b]?.score ?? history.first { $0.name == b && $0.inventoryKey == inventory }?.score ?? -1
            return x == y ? a < b : x > y
        }
        var regions = Set<String>(); var diverse: [String] = []
        // Diversity never displaces a performance-qualified candidate with an unqualified one.
        for tier in [choices.filter { qualities[$0] != nil }, choices.filter { qualities[$0] == nil }] {
            for name in tier { if regions.insert(region(name)).inserted { diverse.append(name) } }
            diverse += tier.filter { !diverse.contains($0) }
        }
        return Array(diverse.prefix(settings.backupPoolSize))
    }
}

public enum DiagnosticExport {
    public static func data(state: StoredState, version: String, connected: Bool, network: String, protection: ProtectionPhase) throws -> Data {
        func alias(_ name: String, inventory: String?) -> String { "node-" + SHA256.hash(data: Data(((inventory ?? "legacy") + "\u{0}" + name).utf8)).prefix(5).map { String(format: "%02x", $0) }.joined() }
        func safe(_ number: Double) -> Double { number.isFinite ? max(0, min(1e12, number)) : 0 }
        let history = (state.history ?? state.measurements).sorted { $0.date > $1.date }.prefix(300).map { r -> [String: Any] in
            var item: [String: Any] = ["node": alias(r.name, inventory: r.inventoryKey), "date": ISO8601DateFormatter().string(from: r.date), "kind": r.kind?.rawValue ?? "legacy", "success": r.success, "latency_ms": safe(r.latencyMS), "upload_seconds": safe(r.uploadSeconds), "download_mbps": safe(r.downloadMbps)]
            item["stages"] = r.stages.map { stage -> [String: Any] in
                var entry: [String: Any] = ["stage": stage.stage.rawValue, "status": stage.status.rawValue, "endpoint": stage.endpoint.rawValue]
                if let code = stage.errorCode { entry["curl_code"] = code }
                if let kind = stage.failureKind { entry["failure_kind"] = kind.rawValue }
                if let m = stage.metrics { entry["metrics"] = ["http_status": m.httpStatus, "client_dns_seconds": safe(m.dnsSeconds), "local_proxy_connect_seconds": safe(m.proxyConnectSeconds), "tls_seconds": safe(m.tlsSeconds), "first_byte_seconds": safe(m.firstByteSeconds), "total_seconds": safe(m.totalSeconds), "uploaded_bytes": m.uploadedBytes, "downloaded_bytes": m.downloadedBytes] }
                return entry
            }
            return item
        }
        let allowedKeys = Set(["clash", "topology", "selector", "claude-network", "gpt-network", "claude-route", "claude-country", "gpt-country", "claude-ip", "protection", "no-backup", "switch", "switch-budget", "budget", "subscription", "shared", "network", "state"])
        let incidents = (state.incidents ?? []).prefix(200).map { r -> [String: Any] in
            ["key": allowedKeys.contains(r.key) ? r.key : "other", "level": ["warning", "critical", "info"].contains(r.level) ? r.level : "other", "count": r.count, "first_seen": ISO8601DateFormatter().string(from: r.firstSeen), "last_seen": ISO8601DateFormatter().string(from: r.lastSeen), "resolved": r.resolvedAt != nil, "end_reason": r.resolutionReason == "contextChanged" ? "contextChanged" : "verifiedOrOpen", "front": r.frontName.map { alias($0, inventory: r.inventoryKey) } ?? "unknown"]
        }
        let report: [String: Any] = ["format": 1, "app_version": version, "generated_at": ISO8601DateFormatter().string(from: Date()), "controller_connected": connected, "network": ["Wi-Fi", "有线", "离线", "其他", "等待网络"].contains(network) ? network : "其他", "protection_phase": protection.rawValue, "settings": ["strict": state.settings.strictProtection, "auto_switch": state.settings.autoSwitch, "prefer_best": state.settings.preferBestNode, "automatic_scan": state.settings.automaticFullScan, "automatic_pool": state.settings.automaticBackupPool, "idle_seconds": state.settings.idleSeconds, "backup_pool_size": state.settings.backupPoolSize], "records": history, "incidents": incidents, "privacy": "No credentials, subscription URLs, raw config, raw messages, node names, IP addresses, local paths or chat content included."]
        var output = report
        output["automatic_switches"] = (state.switchingJournal?.records ?? []).prefix(200).map { r -> [String: Any] in
            ["date": ISO8601DateFormatter().string(from: r.date), "from": alias(r.from, inventory: r.inventoryKey), "to": alias(r.to, inventory: r.inventoryKey), "reason": r.reason.rawValue, "status": r.status.rawValue]
        }
        return try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    }
}
