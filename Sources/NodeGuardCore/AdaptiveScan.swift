import Foundation
import CryptoKit
import CProcess
import Yams

public struct ProbeInterrupted: Error, LocalizedError {
    public let reason: String
    public var errorDescription: String? { reason }
    public init(_ reason: String) { self.reason = reason }
}
public final class ProbeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: String?
    public init() {}
    public func cancel(_ reason: String) { lock.lock(); if self.reason == nil { self.reason = reason }; lock.unlock() }
    public func check() throws { lock.lock(); let r = reason; lock.unlock(); if let r = r { throw ProbeInterrupted(r) } }
}

public struct ByteCounters: Equatable {
    public let up: UInt64
    public let down: UInt64
    public init(up: UInt64, down: UInt64) { self.up = up; self.down = down }
    public static func physical() -> ByteCounters? { var u: UInt64 = 0; var d: UInt64 = 0; return ng_network_bytes(&u, &d) > 0 ? ByteCounters(up: u, down: d) : nil }
    public func rate(since old: ByteCounters?, seconds: Double) -> (Double, Double) {
        guard let old = old, seconds > 0, seconds < 15 else { return (0, 0) }
        return (up >= old.up ? Double(up - old.up) / seconds : 0, down >= old.down ? Double(down - old.down) / seconds : 0)
    }
}

public struct LoadDecision {
    public let ready: Bool
    public let busy: Bool
    public let reason: String
    public let upKB: Double
    public let downKB: Double
    public let quietFor: Double
}
public enum TestingSensitivity: String, Codable, CaseIterable {
    case conservative, balanced, aggressive
    public var title: String { switch self { case .conservative: return "保守"; case .balanced: return "均衡（推荐）"; case .aggressive: return "积极" } }
    var networkUp: Double { switch self { case .conservative: return 64 * 1024; case .balanced: return 256 * 1024; case .aggressive: return 1024 * 1024 } }
    var networkDown: Double { networkUp * 8 }
    var aiUp: Double { networkUp / 4 }
    var aiDown: Double { networkDown / 8 }
    var cpuThreshold: Double { switch self { case .conservative: return 0.85; case .balanced: return 0.95; case .aggressive: return 0.98 } }
}
public final class CPUUsageSampler: @unchecked Sendable {
    private var previousBusy: UInt64?
    private var previousTotal: UInt64?
    public init() {}
    public func sample() -> Double? {
        var busy: UInt64 = 0; var total: UInt64 = 0
        guard ng_cpu_ticks(&busy, &total) != 0 else { return nil }
        defer { previousBusy = busy; previousTotal = total }
        guard let oldBusy = previousBusy, let oldTotal = previousTotal, busy >= oldBusy, total > oldTotal else { return nil }
        return min(1, Double(busy - oldBusy) / Double(total - oldTotal))
    }
}
public struct ActivityGate {
    private var previous: [String: ByteCounters] = [:]
    private var lastDate: Date?
    private var lastPhysical: ByteCounters?
    private var lastProxy: ByteCounters?
    private var lastProbe: ByteCounters?
    private var quietSince: Date?
    private var pressureSince: Date?
    public init() {}
    public mutating func reset() { self = ActivityGate() }
    public mutating func sample(snapshot: CoreSnapshot, physical: ByteCounters?, probe: ByteCounters?, ownPorts: Set<Int>, cpuFraction: Double, thermalBusy: Bool, idleSeconds: Double, sensitivity: TestingSensitivity = .balanced, now: Date = Date()) -> LoadDecision {
        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 0
        if elapsed <= 0 || elapsed > 15 { quietSince = now; pressureSince = nil }
        let global = snapshot.uploadTotal.flatMap { u in snapshot.downloadTotal.map { ByteCounters(up: u, down: $0) } }
        let reset = [(physical, lastPhysical), (global, lastProxy), (probe, lastProbe)].contains { current, old in
            guard let current = current, let old = old else { return false }; return current.up < old.up || current.down < old.down
        }
        if reset { quietSince = now; pressureSince = nil }
        let proxyRate = global?.rate(since: lastProxy, seconds: elapsed) ?? (0, 0)
        let physicalRate = physical?.rate(since: lastPhysical, seconds: elapsed) ?? (0, 0)
        let probeRate = probe?.rate(since: lastProbe, seconds: elapsed) ?? (0, 0)
        let ownUp = probeRate.0 * 1.10 + (probe == nil ? 0 : 8192)
        let ownDown = probeRate.1 * 1.10 + (probe == nil ? 0 : 8192)
        let up = max(proxyRate.0, max(0, physicalRate.0 - ownUp))
        let down = max(proxyRate.1, max(0, physicalRate.1 - ownDown))
        var next: [String: ByteCounters] = [:]; var aiUp = 0.0; var aiDown = 0.0
        for c in snapshot.connections {
            if let port = c.metadata.sourcePort.flatMap(Int.init), ownPorts.contains(port) { continue }
            let count = ByteCounters(up: c.upload ?? 0, down: c.download ?? 0); next[c.id] = count
            let host = (c.metadata.host ?? "").lowercased()
            let aiHost = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com", "chatgpt.com", "openai.com"].contains { host == $0 || host.hasSuffix("." + $0) }
            if aiHost {
                let rate = count.rate(since: previous[c.id] ?? ByteCounters(up: 0, down: 0), seconds: elapsed)
                aiUp += rate.0; aiDown += rate.1
            }
        }
        // An open/new socket or tiny packet is not evidence that the user is busy.
        let aiHeavy = aiUp >= sensitivity.aiUp || aiDown >= sensitivity.aiDown
        let networkHeavy = up >= sensitivity.networkUp || down >= sensitivity.networkDown
        let cpuHeavy = cpuFraction >= sensitivity.cpuThreshold
        let missing = physical == nil && global == nil
        let immediate = thermalBusy || missing || up >= sensitivity.networkUp * 4 || down >= sensitivity.networkDown * 4 || aiUp >= sensitivity.aiUp * 4 || aiDown >= sensitivity.aiDown * 4
        let pressure = aiHeavy || networkHeavy || cpuHeavy
        if pressure { if pressureSince == nil { pressureSince = now } } else { pressureSince = nil }
        let confirmed = immediate || pressureSince.map { now.timeIntervalSince($0) >= 6 } == true
        if quietSince == nil || confirmed { quietSince = now }
        let quiet = max(0, now.timeIntervalSince(quietSince!))
        let ready = !confirmed && !pressure && quiet >= idleSeconds
        let reason: String
        if missing { reason = "无法确认网络负载，暂停测速" }
        else if thermalBusy { reason = "系统温度达到严重限制，暂停测速" }
        else if confirmed && aiHeavy { reason = String(format: "AI 大流量传输，暂让行（↑ %.0f / ↓ %.0f KB/s）", aiUp / 1024, aiDown / 1024) }
        else if confirmed && networkHeavy { reason = String(format: "持续较大网络流量，暂让行（↑ %.0f / ↓ %.0f KB/s）", up / 1024, down / 1024) }
        else if confirmed && cpuHeavy { reason = String(format: "CPU 持续占用 %.0f%%，暂让行", cpuFraction * 100) }
        else if pressure { reason = "观察短时负载；零星波动不会重置等待" }
        else if ready { reason = "网络低负载，可以测速" }
        else { reason = "等待低负载稳定 \(Int(ceil(max(0, idleSeconds - quiet)))) 秒" }
        lastDate = now; previous = next; lastPhysical = physical; lastProxy = global; lastProbe = probe
        return LoadDecision(ready: ready, busy: confirmed, reason: reason, upKB: up / 1024, downKB: down / 1024, quietFor: quiet)
    }
}

public struct SubscriptionInventory: Equatable {
    public let key: String
    public let name: String
    public let nodes: [String]
    public init(key: String, name: String, nodes: [String]) { self.key = key; self.name = name; self.nodes = nodes }
}
public final class InventoryReader: @unchecked Sendable {
    private var cachedStamp = ""
    private var sourceHash = ""
    private var uid = ""
    private var name = "当前订阅"
    public init() {}
    public static func identity(uid: String, sourceHash: String, group: String, nodes: [String]) -> String {
        let data = Data(([uid, sourceHash, group] + nodes.sorted()).joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public func read(snapshot: CoreSnapshot, settings: GuardSettings) throws -> SubscriptionInventory {
        let configURL = ClashFiles.configURL, profilesURL = ClashFiles.directory.appendingPathComponent("profiles.yaml")
        func stamp(_ url: URL) throws -> String { let a = try FileManager.default.attributesOfItem(atPath: url.path); return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a[.size] ?? 0):\(a[.systemFileNumber] ?? 0)" }
        let signature = try stamp(configURL) + stamp(profilesURL)
        if signature != cachedStamp {
            let raw: [String: Any], profiles: [String: Any]
            do {
                raw = try Yams.load(yaml: String(contentsOf: configURL, encoding: .utf8)) as? [String: Any] ?? [:]
                profiles = try Yams.load(yaml: String(contentsOf: profilesURL, encoding: .utf8)) as? [String: Any] ?? [:]
            } catch { throw GuardError.unavailable("订阅配置正在更新，稍后重新读取") }
            guard let current = profiles["current"] as? String, !current.isEmpty else { throw GuardError.unavailable("无法确认当前订阅") }
            let definition = raw["proxies"] as? [[String: Any]] ?? []
            guard JSONSerialization.isValidJSONObject(definition) else { throw GuardError.unavailable("节点定义格式不支持，等待有效订阅") }
            let data = try JSONSerialization.data(withJSONObject: definition, options: [.sortedKeys])
            sourceHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            uid = current; name = ((profiles["items"] as? [[String: Any]])?.first { $0["uid"] as? String == current })?["name"] as? String ?? "当前订阅"
            cachedStamp = signature
        }
        let nodes = Array(Set(snapshot.proxies[settings.frontGroup]?.all ?? [])).sorted()
        guard !nodes.isEmpty else { throw GuardError.unavailable("当前订阅没有可关联的前置节点组 \(settings.frontGroup)") }
        guard let route = ExitRoute.current(snapshot: snapshot, settings: settings), route.usesFront(settings) else { throw GuardError.unavailable("当前 Claude 出口未经过已关联前置组，出口监控继续，前置测速暂停") }
        let context = route.testingContext(settings) + "\u{0}" + settings.allowedClaudeIPs.sorted().joined(separator: ",")
        return SubscriptionInventory(key: Self.identity(uid: uid, sourceHash: sourceHash, group: settings.frontGroup + "\u{0}" + context, nodes: nodes), name: name, nodes: nodes)
    }
}

public enum ProbeRuntime {
    private static let lock = NSLock()
    private static var ports: [Int: Date] = [:]
    private static var activeSocket: String?
    private static var retired = ByteCounters(up: 0, down: 0)
    public static func trackPort(_ port: Int) { lock.lock(); ports[port] = .distantFuture; lock.unlock() }
    public static func releasePort(_ port: Int) { lock.lock(); ports[port] = Date().addingTimeInterval(15); lock.unlock() }
    public static func ownPorts() -> Set<Int> { lock.lock(); defer { lock.unlock() }; ports = ports.filter { $0.value > Date() }; return Set(ports.keys) }
    public static func register(socket: String) { lock.lock(); activeSocket = socket; lock.unlock() }
    public static func counters() -> ByteCounters? {
        lock.lock(); let path = activeSocket; let base = retired; lock.unlock()
        guard let path = path else { return base }
        guard let data = try? MihomoClient(socketPath: path).request("GET", "/connections"), let d = try? JSONDecoder().decode(ConnectionsEnvelope.self, from: data), let u = d.uploadTotal, let v = d.downloadTotal else { return nil }
        lock.lock(); defer { lock.unlock() }
        if activeSocket != path { return retired }
        return ByteCounters(up: retired.up + u, down: retired.down + v)
    }
    public static func retire(socket: String) {
        let totals = counters()
        lock.lock(); defer { lock.unlock() }
        if activeSocket == socket { if let totals = totals { retired = totals }; activeSocket = nil }
    }
}

public struct ScanCheckpoint: Codable {
    public let inventoryKey: String
    public let pending: [String]
    public let completed: Int
    public let total: Int
    public let nextRound: Date?
    public init(inventoryKey: String, pending: [String], completed: Int, total: Int, nextRound: Date?) { self.inventoryKey = inventoryKey; self.pending = pending; self.completed = completed; self.total = total; self.nextRound = nextRound }
}
public struct FullScanQueue {
    public private(set) var inventory: SubscriptionInventory?
    public private(set) var pending: [String] = []
    public private(set) var total = 0
    public private(set) var completed = 0
    public private(set) var nextRound: Date?
    public init() {}
    @discardableResult public mutating func replace(_ inventory: SubscriptionInventory, now: Date = Date()) -> Bool {
        guard self.inventory?.key != inventory.key else { return false }
        self.inventory = inventory; schedule(now: now); return true
    }
    public mutating func schedule(now: Date = Date()) { pending = inventory?.nodes ?? []; total = pending.count; completed = 0; nextRound = nil }
    public mutating func resumeAfterCompleted(_ date: Date, interval: Double, now: Date = Date()) { if now.timeIntervalSince(date) < interval { pending = []; completed = total; nextRound = date.addingTimeInterval(interval) } }
    public mutating func beginDueRound(now: Date = Date()) { if pending.isEmpty, let due = nextRound, now >= due { schedule(now: now) } }
    public var checkpoint: ScanCheckpoint? { inventory.map { ScanCheckpoint(inventoryKey: $0.key, pending: pending, completed: completed, total: total, nextRound: nextRound) } }
    @discardableResult public mutating func restore(_ checkpoint: ScanCheckpoint, inventory value: SubscriptionInventory, now: Date = Date()) -> Bool {
        if let due = checkpoint.nextRound, !due.timeIntervalSince1970.isFinite || due.timeIntervalSince(now) > 172800 { return false }
        guard checkpoint.inventoryKey == value.key, checkpoint.total == value.nodes.count, checkpoint.completed >= 0,
              checkpoint.completed + checkpoint.pending.count == checkpoint.total, Set(checkpoint.pending).count == checkpoint.pending.count,
              Set(checkpoint.pending).isSubset(of: Set(value.nodes)), !checkpoint.pending.isEmpty || checkpoint.nextRound != nil,
              checkpoint.pending.isEmpty || checkpoint.nextRound == nil else { return false }
        inventory = value; pending = checkpoint.pending; completed = checkpoint.completed; total = checkpoint.total; nextRound = checkpoint.nextRound; return true
    }
    public mutating func retryEarlier(at date: Date) { if pending.isEmpty { nextRound = min(nextRound ?? date, date) } }
    public static func activeRetry(_ retry: Date?, now: Date = Date()) -> Date? { retry.flatMap { $0 > now ? $0 : nil } }
    // A deferred round earns one early retry. An expired deadline is consumed here, otherwise every later round would restart 15 seconds after it ends.
    public mutating func finishRound(performanceRetry retry: Date?, now: Date = Date()) -> Date? {
        guard let retry = retry else { return nil }
        retryEarlier(at: max(now.addingTimeInterval(15), retry))
        return Self.activeRetry(retry, now: now)
    }
    public mutating func finish(node: String, inventoryKey: String, interval: Double, now: Date = Date()) {
        guard inventory?.key == inventoryKey, let index = pending.firstIndex(of: node) else { return }
        pending.remove(at: index); completed += 1
        if pending.isEmpty { nextRound = now.addingTimeInterval(interval) }
    }
}
