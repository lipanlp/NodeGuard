import Foundation
import Yams
import Darwin

public struct CurlResult {
    public let body: Data
    public let seconds: Double
    public let httpStatus: Int
    public let transferred: Int
    public let chains: [String]
    public let metrics: TransferMetrics?
    public init(body: Data, seconds: Double, httpStatus: Int, transferred: Int, chains: [String], metrics: TransferMetrics? = nil) { self.body = body; self.seconds = seconds; self.httpStatus = httpStatus; self.transferred = transferred; self.chains = chains; self.metrics = metrics }
}
public enum Probe {
    private static let authLock = NSLock()
    private static var authSignature = ""
    private static var cachedAuth: String?
    // No shell, inherited proxy environment, curlrc, insecure TLS, redirects, or response headers.
    public static func curl(url: String, port: Int, auth: String? = nil, timeout: Double = 6, connectionTimeout: Double? = nil, upload: Data? = nil, download: Bool = false, verifyMainRoute: Bool = false, cancellation: ProbeCancellation? = nil) throws -> CurlResult {
        let deadline = Date().addingTimeInterval(timeout)
        for attempt in 0..<2 {
            try cancellation?.check()
            do { return try perform(url: url, port: port, auth: auth, timeout: max(0.1, deadline.timeIntervalSinceNow), connectionTimeout: connectionTimeout, upload: upload, download: download, verifyMainRoute: verifyMainRoute, cancellation: cancellation) }
            catch let error as ProbeFailure {
                // A local-port race is not an egress failure. Retry with a fresh port inside the same deadline.
                if verifyMainRoute && error.kind == .local && error.code == 45 && attempt == 0 && deadline.timeIntervalSinceNow > 0.2 { continue }
                throw error
            }
        }
        throw ProbeFailure(kind: .local, detail: "本地源端口无法分配")
    }
    private static func perform(url: String, port: Int, auth: String?, timeout: Double, connectionTimeout: Double?, upload: Data?, download: Bool, verifyMainRoute: Bool, cancellation: ProbeCancellation?) throws -> CurlResult {
        guard (1...65535).contains(port), let parsed = URL(string: url), parsed.scheme == "https", parsed.user == nil, parsed.password == nil else { throw ProbeFailure(kind: .local, detail: "检测目标或本地代理端口无效") }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NodeGuard/Transfers", isDirectory: true)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("result"), stderrURL = directory.appendingPathComponent("error")
        for path in [stdoutURL, stderrURL] { guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ProbeFailure(kind: .local, detail: "无法创建私有检测缓冲区") } }
        let stdout = try FileHandle(forWritingTo: stdoutURL), stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        let connectBudget = min(timeout, max(0.1, connectionTimeout ?? 5))
        var args = ["-q", "--silent", "--show-error", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)", "--connect-timeout", String(connectBudget), "--max-time", String(timeout), "--proto", "=https", "--max-redirs", "0", "--config", "-"]
        let sourcePort = verifyMainRoute ? try CandidateProbe.availablePort() : 0
        if sourcePort != 0 { ProbeRuntime.trackPort(sourcePort); args += ["--local-port", String(sourcePort)] }
        defer { if sourcePort != 0 { ProbeRuntime.releasePort(sourcePort) } }
        if download { args += ["--output", "/dev/null"] }
        if let upload = upload {
            let path = directory.appendingPathComponent("payload")
            guard FileManager.default.createFile(atPath: path.path, contents: upload, attributes: [.posixPermissions: 0o600]) else { throw ProbeFailure(kind: .local, detail: "无法创建随机测速数据") }
            args += ["--request", "POST", "--header", "Content-Type: application/octet-stream", "--data-binary", "@" + path.path, "--output", "/dev/null"]
        } else if !download { args += ["--max-filesize", "65535"] }
        args += ["--write-out", "\nNODEGUARD_STATS %{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total} %{size_upload} %{size_download}\n", url]
        process.arguments = args; process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let input = Pipe(); process.standardInput = input; process.standardOutput = stdout; process.standardError = stderr
        do { try process.run() } catch { throw ProbeFailure(kind: .local, detail: "本地 curl 检测进程无法启动") }
        var config = ""
        if let auth = auth {
            let safe = auth.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            config = "proxy-user = \"\(safe)\"\n"
        }
        try? input.fileHandleForWriting.write(contentsOf: Data(config.utf8)); try? input.fileHandleForWriting.close()
        var chains: [String] = []; var lastRouteRead = Date.distantPast
        while process.isRunning {
            do { try cancellation?.check() } catch {
                process.terminate(); let end = Date().addingTimeInterval(0.3)
                while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit(); throw error
            }
            if verifyMainRoute && chains.isEmpty && Date().timeIntervalSince(lastRouteRead) >= 0.25 {
                lastRouteRead = Date()
                if let connections = try? MihomoClient().connections(maxAge: 0.2).connections,
                   let connection = connections.first(where: { $0.metadata.sourcePort == String(sourcePort) && $0.metadata.host == parsed.host }) { chains = connection.chains }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.waitUntilExit(); try? stdout.synchronize(); try? stderr.synchronize()
        let length = (try? FileManager.default.attributesOfItem(atPath: stdoutURL.path)[.size] as? Int) ?? 0
        guard length < 70000 else { throw ProbeFailure(kind: .invalid, detail: "检测响应超过大小限制") }
        let data = try Data(contentsOf: stdoutURL)
        let marker = Data("\nNODEGUARD_STATS ".utf8)
        let split = data.range(of: marker, options: .backwards)
        let metrics = split.flatMap { TransferMetrics.parse(Substring(String(decoding: data[$0.upperBound...], as: UTF8.self))) }
        if process.terminationStatus != 0 {
            let raw = (try? Data(contentsOf: stderrURL).prefix(4096)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            throw ProbeFailure.curl(code: Int(process.terminationStatus), metrics: metrics, stderr: raw)
        }
        guard let metrics = metrics, let split = split else { throw ProbeFailure(kind: .invalid, detail: "检测计时数据不完整") }
        guard (200...299).contains(metrics.httpStatus) else { throw ProbeFailure(kind: .endpoint, metrics: metrics, detail: "检测服务返回 HTTP \(metrics.httpStatus)") }
        if verifyMainRoute && chains.isEmpty { throw ProbeFailure(kind: .invalid, metrics: metrics, detail: "未捕获到实际 Clash 代理链，不能作为出口证据") }
        return CurlResult(body: Data(data[..<split.lowerBound]), seconds: metrics.totalSeconds, httpStatus: metrics.httpStatus, transferred: metrics.transferred, chains: chains, metrics: metrics)
    }
    public static func exit(host: String, port: Int, auth: String? = nil, timeout: Double = 8, verifyMainRoute: Bool = false, cancellation: ProbeCancellation? = nil) throws -> ExitObservation {
        guard ["claude.ai", "chatgpt.com", "www.cloudflare.com"].contains(host) else { throw ProbeFailure(kind: .local, detail: "出口检测域名不在允许列表") }
        let response = try curl(url: "https://\(host)/cdn-cgi/trace", port: port, auth: auth, timeout: timeout, connectionTimeout: timeout, verifyMainRoute: verifyMainRoute, cancellation: cancellation)
        var observation = try ExitObservation.parseTrace(response.body, seconds: response.seconds); observation.chains = response.chains; return observation
    }
    public static func localAuthentication(configURL: URL = ClashFiles.configURL) throws -> String? {
        authLock.lock(); defer { authLock.unlock() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path) else { throw ProbeFailure(kind: .local, detail: "无法读取 Clash 本地认证配置") }
        let signature = "\(configURL.path):\(attributes[.modificationDate] ?? ""): \(attributes[.size] ?? 0):\(attributes[.systemFileNumber] ?? 0)"
        if signature == authSignature { return cachedAuth }
        guard let config = try? Yams.load(yaml: String(contentsOf: configURL, encoding: .utf8)) as? [String: Any] else { throw ProbeFailure(kind: .local, detail: "Clash 本地配置正在更新") }
        cachedAuth = (config["authentication"] as? [String])?.first; authSignature = signature; return cachedAuth
    }
}
public enum ClashFiles {
    public static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev", isDirectory: true) }
    public static var configURL: URL { directory.appendingPathComponent("clash-verge.yaml") }
    public static let coreURL = URL(fileURLWithPath: "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo")
}
