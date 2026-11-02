import Foundation
import Darwin

public enum GuardError: Error, LocalizedError {
    case unavailable(String)
    public var errorDescription: String? { if case .unavailable(let s) = self { return s }; return "检测失败" }
}

public struct GuardSettings: Codable, Equatable {
    public var frontGroup = "KTM前置节点"
    public var claudeGroup = "Claude专线"
    public var gptGroup = "ChatGPT"
    // Retained for decoding older state. Runtime decisions use ExitRoute.current.
    public var residentialNode = ""
    public var candidates: [String] = []
    public var allowedClaudeIPs: [String] = []
    public var autoSwitch = false
    public var preferBestNode = true
    public var strictProtection = false
    public var dailyTestBudgetMB = 0
    public var automaticFullScan = true
    public var fullScanInterval = 21600.0
    public var idleSeconds = 15.0
    public var testingSensitivity = TestingSensitivity.balanced
    public var automaticBackupPool = true
    public var backupPoolSize = 5
    public var backupHealthInterval = 300.0
    public var unverifiedGrace = 12.0
    public var slowUploadSeconds = 15.0
    public var slowCheckInterval = 600.0
    public init() {}
    enum CodingKeys: String, CodingKey { case frontGroup, claudeGroup, gptGroup, residentialNode, candidates, allowedClaudeIPs, autoSwitch, preferBestNode, strictProtection, dailyTestBudgetMB, slowUploadSeconds, slowCheckInterval, automaticFullScan, fullScanInterval, idleSeconds, testingSensitivity, settingsVersion, automaticBackupPool, backupPoolSize, backupHealthInterval, unverifiedGrace }
    public init(from decoder: Decoder) throws {
        self.init(); let c = try decoder.container(keyedBy: CodingKeys.self)
        frontGroup = try c.decodeIfPresent(String.self, forKey: .frontGroup) ?? frontGroup
        claudeGroup = try c.decodeIfPresent(String.self, forKey: .claudeGroup) ?? claudeGroup
        gptGroup = try c.decodeIfPresent(String.self, forKey: .gptGroup) ?? gptGroup
        residentialNode = try c.decodeIfPresent(String.self, forKey: .residentialNode) ?? residentialNode
        candidates = try c.decodeIfPresent([String].self, forKey: .candidates) ?? []
        allowedClaudeIPs = try c.decodeIfPresent([String].self, forKey: .allowedClaudeIPs) ?? []
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? false
        preferBestNode = try c.decodeIfPresent(Bool.self, forKey: .preferBestNode) ?? true
        strictProtection = try c.decodeIfPresent(Bool.self, forKey: .strictProtection) ?? false
        automaticFullScan = try c.decodeIfPresent(Bool.self, forKey: .automaticFullScan) ?? true
        fullScanInterval = try c.decodeIfPresent(Double.self, forKey: .fullScanInterval) ?? fullScanInterval
        let version = try c.decodeIfPresent(Int.self, forKey: .settingsVersion) ?? 1
        let previousIdle = try c.decodeIfPresent(Double.self, forKey: .idleSeconds)
        idleSeconds = version < 3 && previousIdle == 60 ? 15 : (previousIdle ?? idleSeconds)
        testingSensitivity = try c.decodeIfPresent(TestingSensitivity.self, forKey: .testingSensitivity) ?? .balanced
        automaticBackupPool = try c.decodeIfPresent(Bool.self, forKey: .automaticBackupPool) ?? true
        backupPoolSize = try c.decodeIfPresent(Int.self, forKey: .backupPoolSize) ?? 5
        backupHealthInterval = try c.decodeIfPresent(Double.self, forKey: .backupHealthInterval) ?? 300
        unverifiedGrace = try c.decodeIfPresent(Double.self, forKey: .unverifiedGrace) ?? 12
        slowUploadSeconds = try c.decodeIfPresent(Double.self, forKey: .slowUploadSeconds) ?? slowUploadSeconds
        slowCheckInterval = try c.decodeIfPresent(Double.self, forKey: .slowCheckInterval) ?? slowCheckInterval
        // v0.1 capped tests at 200 MB. This release explicitly migrates to the user's unlimited policy.
        if version >= 2 { dailyTestBudgetMB = try c.decodeIfPresent(Int.self, forKey: .dailyTestBudgetMB) ?? 0 } else { dailyTestBudgetMB = 0 }
        normalize()
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(5, forKey: .settingsVersion); try c.encode(testingSensitivity, forKey: .testingSensitivity); try c.encode(frontGroup, forKey: .frontGroup); try c.encode(claudeGroup, forKey: .claudeGroup); try c.encode(gptGroup, forKey: .gptGroup); try c.encode(residentialNode, forKey: .residentialNode)
        try c.encode(automaticBackupPool, forKey: .automaticBackupPool); try c.encode(backupPoolSize, forKey: .backupPoolSize); try c.encode(backupHealthInterval, forKey: .backupHealthInterval); try c.encode(unverifiedGrace, forKey: .unverifiedGrace)
        try c.encode(candidates, forKey: .candidates); try c.encode(allowedClaudeIPs, forKey: .allowedClaudeIPs); try c.encode(autoSwitch, forKey: .autoSwitch); try c.encode(preferBestNode, forKey: .preferBestNode); try c.encode(strictProtection, forKey: .strictProtection)
        try c.encode(dailyTestBudgetMB, forKey: .dailyTestBudgetMB); try c.encode(automaticFullScan, forKey: .automaticFullScan); try c.encode(fullScanInterval, forKey: .fullScanInterval); try c.encode(idleSeconds, forKey: .idleSeconds)
        try c.encode(slowUploadSeconds, forKey: .slowUploadSeconds); try c.encode(slowCheckInterval, forKey: .slowCheckInterval)
    }
    public mutating func normalize() {
        candidates = Array(NSOrderedSet(array: candidates).compactMap { $0 as? String }.prefix(2000))
        allowedClaudeIPs = Array(Set(allowedClaudeIPs.compactMap(IPAddress.canonical))).sorted()
        dailyTestBudgetMB = dailyTestBudgetMB <= 0 ? 0 : min(100000, max(10, dailyTestBudgetMB))
        fullScanInterval = fullScanInterval.isFinite ? max(1800, min(86400, fullScanInterval)) : 21600
        idleSeconds = idleSeconds.isFinite ? max(5, min(600, idleSeconds)) : 15
        backupPoolSize = min(5, max(3, backupPoolSize))
        backupHealthInterval = backupHealthInterval.isFinite ? min(1800, max(180, backupHealthInterval)) : 300
        unverifiedGrace = unverifiedGrace.isFinite ? min(20, max(0, unverifiedGrace)) : 12
        slowUploadSeconds = max(5, min(60, slowUploadSeconds))
        slowCheckInterval = max(300, slowCheckInterval)
        if allowedClaudeIPs.isEmpty { strictProtection = false; autoSwitch = false }
    }
}

public enum IPAddress {
    public static func canonical(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var v4 = in_addr(); var v6 = in6_addr(); var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if inet_pton(AF_INET, t, &v4) == 1 { inet_ntop(AF_INET, &v4, &output, socklen_t(output.count)); return String(cString: output) }
        if inet_pton(AF_INET6, t, &v6) == 1 { inet_ntop(AF_INET6, &v6, &output, socklen_t(output.count)); return String(cString: output).lowercased() }
        return nil
    }
    public static func isLocal(_ text: String) -> Bool {
        guard let ip = canonical(text) else { return false }
        if ip == "::1" || ip.hasPrefix("fe80:") || ip.hasPrefix("fc") || ip.hasPrefix("fd") { return true }
        let a = ip.split(separator: ".").compactMap { Int($0) }
        return a.count == 4 && (a[0] == 127 || a[0] == 10 || (a[0] == 192 && a[1] == 168) || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 169 && a[1] == 254))
    }
}

public struct ProxyInfo: Decodable {
    public let name: String
    public let type: String
    public let now: String?
    public let all: [String]?
    public let dialerProxy: String?
    enum CodingKeys: String, CodingKey { case name, type, now, all; case dialerProxy = "dialer-proxy" }
}
public struct ProxyEnvelope: Decodable { public let proxies: [String: ProxyInfo] }
public struct ConnectionInfo: Decodable {
    public struct Metadata: Decodable {
        public let process: String?
        public let processPath: String?
        public let host: String?
        public let destinationIP: String?
        public let sourcePort: String?
    }
    public let id: String
    public let metadata: Metadata
    public let chains: [String]
    public let upload: UInt64?
    public let download: UInt64?
}
public struct ConnectionsEnvelope: Decodable {
    public let connections: [ConnectionInfo]
    public let uploadTotal: UInt64?
    public let downloadTotal: UInt64?
    enum CodingKeys: String, CodingKey { case connections, uploadTotal, downloadTotal }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        connections = try c.decodeIfPresent([ConnectionInfo].self, forKey: .connections) ?? []
        uploadTotal = try c.decodeIfPresent(UInt64.self, forKey: .uploadTotal)
        downloadTotal = try c.decodeIfPresent(UInt64.self, forKey: .downloadTotal)
    }
}
public struct CoreConfig: Decodable {
    public struct Tun: Decodable {
        public let enable: Bool
        public let autoRoute: Bool?
        enum CodingKeys: String, CodingKey { case enable; case autoRoute = "auto-route" }
    }
    public let mode: String
    public let mixedPort: Int
    public let httpPort: Int
    public let socksPort: Int
    public let tun: Tun?
    public let findProcessMode: String?
    enum CodingKeys: String, CodingKey { case mode, tun; case findProcessMode = "find-process-mode"; case mixedPort = "mixed-port"; case httpPort = "port"; case socksPort = "socks-port" }
}

public struct CoreSnapshot {
    public let proxies: [String: ProxyInfo]
    public let connections: [ConnectionInfo]
    public let config: CoreConfig
    public let uploadTotal: UInt64?
    public let downloadTotal: UInt64?
    public let captured = Date()
    public init(proxies: [String: ProxyInfo], connections: [ConnectionInfo], config: CoreConfig, uploadTotal: UInt64? = nil, downloadTotal: UInt64? = nil) {
        self.proxies = proxies; self.connections = connections; self.config = config
        self.uploadTotal = uploadTotal; self.downloadTotal = downloadTotal
    }
    public func leaf(_ name: String) -> String? {
        var seen = Set<String>(); var n = name
        while let p = proxies[n] {
            guard seen.insert(n).inserted else { return nil }
            guard let selected = p.now else { return p.name }
            n = selected
        }
        return nil
    }
    public func routeSummary(_ name: String) -> String {
        var parts: [String] = []; var n = name; var seen = Set<String>()
        while let p = proxies[n], seen.insert(n).inserted {
            parts.append(n)
            if let next = p.now { n = next }
            else if let dialer = p.dialerProxy, !dialer.isEmpty { n = dialer }
            else { break }
        }
        return parts.isEmpty ? "策略组不存在" : parts.joined(separator: " → ")
    }
}

public struct ExitObservation: Codable, Equatable {
    public let ip: String
    public let country: String
    public let seconds: Double
    public let date: Date
    public var chains: [String]
    public init(ip: String, country: String, seconds: Double, date: Date = Date(), chains: [String] = []) { self.ip = ip; self.country = country; self.seconds = seconds; self.date = date; self.chains = chains }
    public static func parseTrace(_ data: Data, seconds: Double) throws -> ExitObservation {
        let text = String(decoding: data, as: UTF8.self)
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let p = line.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2 { fields[p[0]] = p[1] }
        }
        guard let raw = fields["ip"], let ip = IPAddress.canonical(raw), let country = fields["loc"], country.count == 2, country.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
            throw GuardError.unavailable("出口探测没有返回有效 IP 和国家；不会把网页或验证码当作正常结果")
        }
        guard !IPAddress.isLocal(ip) else { throw GuardError.unavailable("出口探测返回了局域网地址") }
        return ExitObservation(ip: ip, country: country, seconds: seconds)
    }
}

public struct NodeMeasurement: Codable, Identifiable, Equatable {
    public var id: String { name }
    public var name: String
    public var date: Date
    public var success: Bool
    public var latencyMS: Double
    public var uploadSeconds: Double
    public var downloadMbps: Double
    public var reliability: Double
    public var samples: Int
    public var failure: String?
    public var ip: String?
    public var country: String?
    public var inventoryKey: String?
    public var diagnostics: [StageResult]?
    public var kind: MeasurementKind?
    public var performanceDeferred: Bool?
    public init(name: String, date: Date, success: Bool, latencyMS: Double, uploadSeconds: Double, downloadMbps: Double, reliability: Double, samples: Int, failure: String?, ip: String?, country: String?) {
        self.name = name; self.date = date; self.success = success; self.latencyMS = latencyMS; self.uploadSeconds = uploadSeconds; self.downloadMbps = downloadMbps; self.reliability = reliability; self.samples = samples; self.failure = failure; self.ip = ip; self.country = country
    }
    public var score: Double {
        if !success, !stages.isEmpty {
            return (passed(.front) ? 2 : 0) + (passed(.residential) ? 4 : 0) + (passed(.claude) ? 3 : 0) + (passed(.gpt) ? 1 : 0) + (passed(.smallUpload) ? 1 : 0) + (passed(.download) ? 1 : 0)
        }
        guard success, kind != .health, kind != .stream else { return 0 }
        let upload = min(1, 3 / max(0.1, uploadSeconds))
        let download = min(1, downloadMbps / 20)
        let latency = min(1, 600 / max(1, latencyMS))
        return (upload * 0.45 + download * 0.20 + latency * 0.15 + reliability * 0.20) * 100
    }
    public func isUsable(now: Date = Date(), allowedIPs: [String], maxUpload: Double) -> Bool {
        success && kind != .health && kind != .stream && uploadSeconds > 0 && now.timeIntervalSince(date) >= 0 && now.timeIntervalSince(date) < 1800 && uploadSeconds <= maxUpload && country != "CN" && (allowedIPs.isEmpty || allowedIPs.contains(ip ?? ""))
    }
    public static func failed(_ name: String, previous: NodeMeasurement?, reason: String) -> NodeMeasurement {
        NodeMeasurement(name: name, date: Date(), success: false, latencyMS: 0, uploadSeconds: 0, downloadMbps: 0, reliability: (previous?.reliability ?? 0) * 0.7, samples: (previous?.samples ?? 0) + 1, failure: reason, ip: nil, country: nil)
    }
}

public enum ProtectionPolicy {
    public static func topologyViolation(snapshot: CoreSnapshot, settings: GuardSettings, claudePaths: [String]) -> String? {
        guard snapshot.config.mode == "rule" else { return "Clash 当前不是规则模式，无法确认 Claude 路由" }
        guard snapshot.config.tun?.enable == true, snapshot.config.tun?.autoRoute == true else { return "Clash TUN 或自动路由未开启，无法确认 Claude 桌面端流量被接管" }
        guard ["strict", "always"].contains(snapshot.config.findProcessMode ?? "") else { return "Clash 未启用进程识别，无法核对 Claude 实际连接" }
        guard let route = ExitRoute.current(snapshot: snapshot, settings: settings) else { return "无法解析当前 Claude 出口路由" }
        for c in snapshot.connections {
            guard let path = c.metadata.processPath, claudePaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            if let ip = c.metadata.destinationIP, IPAddress.isLocal(ip) { continue }
            guard ClaudeServiceScope.contains(c.metadata.host) else { continue }
            let host = c.metadata.host ?? ""
            if !route.matchesConnection(c.chains, settings: settings) { return "Claude 服务连接与当前出口探测路由不一致，无法确认锁定 IP：\(host)" }
        }
        return nil
    }
    public static func exitViolation(_ observation: ExitObservation, allowedIPs: [String]) -> String? {
        if observation.country == "CN" { return "Claude 出口回到了中国大陆" }
        guard allowedIPs.contains(observation.ip) else { return "Claude 出口 IP 偏离已锁定的出口 IP" }
        return nil
    }
    public static func canEnroll(snapshot: CoreSnapshot, settings: GuardSettings, observations: [ExitObservation], now: Date = Date()) -> Bool {
        guard snapshot.config.mode == "rule", let route = ExitRoute.current(snapshot: snapshot, settings: settings), observations.count == 2 else { return false }
        return observations.allSatisfy { $0.country != "CN" && IPAddress.canonical($0.ip) != nil && !IPAddress.isLocal($0.ip) && route.matches($0) && now.timeIntervalSince($0.date) < 20 && now.timeIntervalSince($0.date) >= 0 } && Set(observations.map(\.ip)).count == 1
    }
}

public struct GuardEvent: Codable, Identifiable {
    public let id: UUID
    public let date: Date
    public let level: String
    public let message: String
    public init(level: String, message: String) { id = UUID(); date = Date(); self.level = level; self.message = String(message.prefix(600)) }
}

public struct StoredState: Codable {
    public var settings = GuardSettings()
    public var measurements: [NodeMeasurement] = []
    public var events: [GuardEvent] = []
    public var budgetDay = ""
    public var testBytes = 0
    public var inventoryKey: String?
    public var lastFullScan: Date?
    public var history: [NodeMeasurement]?
    public var healthChecks: [NodeMeasurement]?
    public var incidents: [GuardIncident]?
    public var scanCheckpoint: ScanCheckpoint?
    public var performanceRetryAt: Date?
    public var diagnosticSchema: Int?
    public var switchingJournal: SwitchingJournal?
    public init() {}
}

public final class StateStore {
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("state.json") }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NodeGuard", isDirectory: true)
    }
    public func load() -> StoredState {
        if let data = try? Data(contentsOf: file), let state = try? JSONDecoder().decode(StoredState.self, from: data) { return state }
        return (try? JSONDecoder().decode(StoredState.self, from: Data(contentsOf: directory.appendingPathComponent("state.previous.json")))) ?? StoredState()
    }
    public func save(_ state: StoredState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var copy = state; copy.events = Array(copy.events.prefix(200)); copy.measurements = Array(copy.measurements.suffix(4000))
        if let history = copy.history { copy.history = Array(history.prefix(4000)) }
        if let data = try? Data(contentsOf: file), (try? JSONDecoder().decode(StoredState.self, from: data)) != nil {
            let backup = directory.appendingPathComponent("state.previous.json")
            try data.write(to: backup, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let data = try JSONEncoder().encode(copy)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; return formatter.string(from: date)
    }
}
