import Foundation
import Darwin
import SystemConfiguration
import Security
import Yams

public struct CandidateResult {
    public let measurement: NodeMeasurement
    public let chargedBytes: Int
}

public enum CandidateProbe {
    public static let reservationBytes = 9_000_000
    public static let healthReservationBytes = 150_000
    public static var cacheRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NodeGuard/Probes", isDirectory: true) }
    private static let lock = NSLock()
    private static var active: [Int32: Process] = [:]
    public static func stopAll() {
        lock.lock(); let children = Array(active.values); lock.unlock()
        for child in children where child.isRunning { child.terminate() }
    }
    public static func physicalInterface() throws -> String {
        guard let store = SCDynamicStoreCreate(nil, "NodeGuard" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let name = dict["PrimaryInterface"] as? String, name.hasPrefix("en") else {
            throw GuardError.unavailable("没有可确认的物理网络接口，暂停隔离测速以免代理环路")
        }
        return name
    }
    public static func configuration(source: [String: Any], snapshot: CoreSnapshot, candidate: String, settings: GuardSettings, port: Int, interface: String, frontPort: Int? = nil) throws -> [String: Any] {
        guard snapshot.proxies[settings.frontGroup]?.all?.contains(candidate) == true else { throw GuardError.unavailable("候选不属于当前前置节点组") }
        guard let route = ExitRoute.current(snapshot: snapshot, settings: settings), route.usesFront(settings) else { throw GuardError.unavailable("当前出口未经过已关联前置组，暂停前置测速") }
        let nodes = source["proxies"] as? [[String: Any]] ?? []
        let named = Dictionary(nodes.compactMap { node -> (String, [String: Any])? in guard let name = node["name"] as? String else { return nil }; return (name, node) }, uniquingKeysWith: { a, _ in a })
        var added: [String: [String: Any]] = [:]; var visiting = Set<String>()
        func add(_ name: String) throws -> String {
            guard name != settings.frontGroup else { throw GuardError.unavailable("候选依赖自身前置组，切换后会形成循环") }
            guard visiting.insert(name).inserted else { throw GuardError.unavailable("候选代理链出现循环") }
            defer { visiting.remove(name) }
            if let p = snapshot.proxies[name], let next = p.now { return try add(next) }
            if added[name] != nil { return name }
            guard var node = named[name] else { throw GuardError.unavailable("候选依赖外部 provider 或缺少节点定义，暂不支持隔离测试") }
            if let next = node["dialer-proxy"] as? String, !next.isEmpty { node["dialer-proxy"] = try add(next) }
            else { node["interface-name"] = interface }
            added[name] = node; return name
        }
        let front = try add(candidate)
        var substituted = false; var exitVisiting = Set<String>(); var aliasIndex = 0
        func copyExit(_ name: String) throws -> String {
            if name == settings.frontGroup { substituted = true; return front }
            guard exitVisiting.insert(name).inserted else { throw GuardError.unavailable("当前出口代理链出现循环") }
            defer { exitVisiting.remove(name) }
            if let selected = snapshot.proxies[name]?.now { return try copyExit(selected) }
            guard var node = named[name] else { throw GuardError.unavailable("当前出口依赖外部 provider 或缺少节点定义，暂不支持隔离测试") }
            var alias = "NodeGuard-exit"
            while named[alias] != nil || added[alias] != nil { aliasIndex += 1; alias = "NodeGuard-exit-\(aliasIndex)" }
            node["name"] = alias
            // Reserve the alias before copying an upstream dependency.
            added[alias] = node
            if let next = node["dialer-proxy"] as? String, !next.isEmpty { node["dialer-proxy"] = try copyExit(next) }
            else { node["interface-name"] = interface }
            added[alias] = node; return alias
        }
        let exit = try copyExit(settings.claudeGroup)
        guard substituted else { throw GuardError.unavailable("出口节点定义与当前前置链不一致，取消隔离测试") }
        var listeners: [[String: Any]] = [["name": "NodeGuard-probe", "type": "mixed", "listen": "127.0.0.1", "port": port, "proxy": exit, "users": []]]
        if let frontPort = frontPort { listeners.append(["name": "NodeGuard-front-probe", "type": "mixed", "listen": "127.0.0.1", "port": frontPort, "proxy": front, "users": []]) }
        return ["mode": "rule", "allow-lan": false, "log-level": "silent", "ipv6": false, "interface-name": interface,
                "tun": ["enable": false], "sniffer": ["enable": false],
                "dns": ["enable": true, "enhanced-mode": "redir-host", "ipv6": false, "nameserver": ["223.5.5.5", "119.29.29.29"], "default-nameserver": ["223.5.5.5", "119.29.29.29"]],
                "proxies": Array(added.values),
                "listeners": listeners,
                "rules": ["MATCH,REJECT"]]
    }
    public static func measure(candidate: String, snapshot: CoreSnapshot, settings: GuardSettings, previous: NodeMeasurement?, includeDownload: Bool = true, cancellation: ProbeCancellation? = nil, expectedInventory: String? = nil, onStage: ((String) -> Void)? = nil, kind: MeasurementKind? = nil, skipPerformance: String? = nil) throws -> CandidateResult {
        try cancellation?.check()
        if let expected = expectedInventory {
            let actual = try InventoryReader().read(snapshot: MihomoClient().snapshot(), settings: settings)
            guard actual.key == expected else { throw ProbeInterrupted("订阅已改变，停止旧订阅测速") }
        }
        guard FileManager.default.isExecutableFile(atPath: ClashFiles.coreURL.path) else { throw GuardError.unavailable("未找到 Clash Verge 随附的 Mihomo 核心") }
        let source: [String: Any]
        do { source = try Yams.load(yaml: String(contentsOf: ClashFiles.configURL, encoding: .utf8)) as? [String: Any] ?? [:] }
        catch { throw GuardError.unavailable("无法读取 Clash 生成配置；原配置保持不变") }
        let port = try availablePort(); var frontPort = try availablePort()
        while frontPort == port { frontPort = try availablePort() }
        var config = try configuration(source: source, snapshot: snapshot, candidate: candidate, settings: settings, port: port, interface: physicalInterface(), frontPort: frontPort)
        let authUser = "NodeGuard", authPassword = UUID().uuidString
        if var listeners = config["listeners"] as? [[String: Any]], !listeners.isEmpty { for i in listeners.indices { listeners[i]["users"] = [["username": authUser, "password": authPassword]] }; config["listeners"] = listeners }
        let auth = authUser + ":" + authPassword
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("private-config.yaml")
        let yaml: String
        do { yaml = try Yams.dump(object: config) } catch { throw GuardError.unavailable("无法生成隔离测试配置") }
        guard FileManager.default.createFile(atPath: configURL.path, contents: Data(yaml.utf8), attributes: [.posixPermissions: 0o600]) else { throw GuardError.unavailable("无法创建私有临时配置") }
        let process = Process(); process.executableURL = ClashFiles.coreURL
        let socketPath = directory.appendingPathComponent("ctl.sock").path
        process.arguments = ["-d", directory.path, "-f", configURL.path, "-ext-ctl-unix", socketPath]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let pid = process.processIdentifier
        lock.lock(); active[pid] = process; lock.unlock()
        try? Data(String(pid).utf8).write(to: directory.appendingPathComponent("pid"), options: .atomic)
        defer {
            ProbeRuntime.retire(socket: socketPath)
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }; process.waitUntilExit()
            lock.lock(); active.removeValue(forKey: pid); lock.unlock()
        }
        var ready = false
        for _ in 0..<40 {
            try cancellation?.check()
            guard process.isRunning else { break }
            if canConnect(port) { ready = true; break }; Thread.sleep(forTimeInterval: 0.05)
        }
        guard ready else { throw GuardError.unavailable("隔离测速核心未就绪；没有修改 Clash") }
        ProbeRuntime.register(socket: socketPath)
        return try DiagnosticRunner.run(candidate: candidate, settings: settings, kind: kind ?? (includeDownload ? .full : .upload), skipPerformance: skipPerformance, cancellation: cancellation, onStage: onStage) { request in
            var payload: Data?
            if request.uploadBytes > 0 {
                var bytes = [UInt8](repeating: 0, count: request.uploadBytes)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ProbeFailure(kind: .local, detail: "无法生成随机测速数据") }
                payload = Data(bytes)
            }
            return try Probe.curl(url: request.endpoint.url, port: request.frontOnly ? frontPort : port, auth: auth, timeout: request.timeout, connectionTimeout: kind == .health ? request.timeout : nil, upload: payload, download: !request.endpoint.isTrace && payload == nil, cancellation: cancellation)
        }
    }
    public static func cleanupAbandonedSessions() {
        let transfers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NodeGuard/Transfers")
        for path in (try? FileManager.default.contentsOfDirectory(at: transfers, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if UUID(uuidString: path.lastPathComponent) != nil, let date = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 86400 { try? FileManager.default.removeItem(at: path) }
        }
        guard let directories = try? FileManager.default.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return }
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            if let text = try? String(contentsOf: directory.appendingPathComponent("pid")), let pid = Int32(text), let identity = ProcessGuard.identity(pid) {
                // Only our exact core executable with this exact owned scratch directory is eligible.
                if identity.path == ClashFiles.coreURL.path && identity.arguments.contains(directory.path) && identity.arguments.contains(directory.appendingPathComponent("private-config.yaml").path) { _ = Darwin.kill(pid, SIGKILL) }
            }
            try? FileManager.default.removeItem(at: directory)
        }
    }
    public static func availablePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw GuardError.unavailable("无法分配本地测试端口") }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard bound == 0 && result == 0 else { throw GuardError.unavailable("无法分配本地测试端口") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
    private static func canConnect(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
}
