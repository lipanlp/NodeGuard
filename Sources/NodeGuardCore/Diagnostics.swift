import Foundation

public enum ProbeFailureKind: String, Codable {
    case timeout, tls, network, local, endpoint, route, invalid, unknown
    public var title: String {
        switch self { case .timeout: return "超时"; case .tls: return "TLS 握手"; case .network: return "连接失败"; case .local: return "本机探测错误"; case .endpoint: return "检测服务响应异常"; case .route: return "出口或路由不符"; case .invalid: return "证据不完整"; case .unknown: return "尚未定位" }
    }
}

public struct TransferMetrics: Codable, Equatable {
    public var httpStatus: Int = 0
    public var dnsSeconds: Double = 0
    public var proxyConnectSeconds: Double = 0
    public var tlsSeconds: Double = 0
    public var firstByteSeconds: Double = 0
    public var totalSeconds: Double = 0
    public var uploadedBytes: Int = 0
    public var downloadedBytes: Int = 0
    public init(httpStatus: Int = 0, totalSeconds: Double = 0, uploadedBytes: Int = 0, downloadedBytes: Int = 0) {
        self.httpStatus = httpStatus; self.totalSeconds = totalSeconds; self.uploadedBytes = uploadedBytes; self.downloadedBytes = downloadedBytes
    }
    public static func parse(_ values: Substring) -> TransferMetrics? {
        let parts = values.split(whereSeparator: \.isWhitespace)
        guard parts.count == 8, let status = Int(parts[0]) else { return nil }
        let numbers = parts.dropFirst().compactMap { Double($0) }
        guard numbers.count == 7, numbers.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < 1e12 }) else { return nil }
        var r = TransferMetrics(httpStatus: status, totalSeconds: numbers[4], uploadedBytes: Int(numbers[5]), downloadedBytes: Int(numbers[6]))
        r.dnsSeconds = numbers[0]; r.proxyConnectSeconds = numbers[1]; r.tlsSeconds = numbers[2]; r.firstByteSeconds = numbers[3]
        return r
    }
    public var transferred: Int { uploadedBytes + downloadedBytes }
    public var stoppedAt: String {
        if proxyConnectSeconds == 0 { return "连接本地代理前" }
        if tlsSeconds == 0 { return "代理隧道或 TLS 握手" }
        if firstByteSeconds == 0 { return uploadedBytes > 0 ? "已写出数据，等待服务响应" : "等待首字节" }
        return "响应传输"
    }
}

public struct ProbeFailure: Error, LocalizedError {
    public let kind: ProbeFailureKind
    public let code: Int?
    public let metrics: TransferMetrics?
    public let detail: String
    public var errorDescription: String? { "\(kind.title)：\(detail)" + (code.map { "（curl \($0)）" } ?? "") }
    public init(kind: ProbeFailureKind, code: Int? = nil, metrics: TransferMetrics? = nil, detail: String) { self.kind = kind; self.code = code; self.metrics = metrics; self.detail = detail }
    public static func curl(code: Int, metrics: TransferMetrics?, stderr: String = "") -> ProbeFailure {
        let kind: ProbeFailureKind
        switch code { case 28: kind = .timeout; case 35, 51, 58, 60: kind = .tls; case 2, 23, 26, 27, 43, 45, 48: kind = .local; case 5, 6, 7, 52, 55, 56, 97: kind = .network; case 22: kind = .endpoint; default: kind = .unknown }
        // Raw stderr is never retained. Only recognize a fixed local-bind diagnostic.
        let bind = code == 45 && ["bind", "local port", "address already in use"].contains { stderr.lowercased().contains($0) }
        let detail = bind ? "本地源端口绑定失败，已与线路故障区分" : (metrics?.stoppedAt ?? "未获得传输阶段")
        return ProbeFailure(kind: kind, code: code, metrics: metrics, detail: detail)
    }
    public static func classify(_ error: Error) -> ProbeFailure {
        if let e = error as? ProbeFailure { return e }
        return ProbeFailure(kind: .invalid, detail: "检测未能形成有效证据")
    }
}

public enum DiagnosticStage: String, Codable, CaseIterable {
    case front, residential, claude, gpt, smallUpload, upload, download, stream
    public var title: String { switch self { case .front: return "前置独立连通"; case .residential: return "出口 IP 验证"; case .claude: return "Claude 目标"; case .gpt: return "GPT 目标"; case .smallUpload: return "64 KB 上传"; case .upload: return "1 MB 上传"; case .download: return "下载"; case .stream: return "30 秒流式连接" } }
}
public enum StageStatus: String, Codable { case passed, failed, deferred }
public enum MeasurementKind: String, Codable { case full, health, upload, stream }
public enum DiagnosticEndpoint: String, Codable {
    case cloudflareTrace, claudeTrace, gptTrace, cloudflareUpload, bingoUpload, cloudflareDownload, bingoDownload, bingoStream
    public var url: String {
        switch self {
        case .cloudflareTrace: return "https://www.cloudflare.com/cdn-cgi/trace"
        case .claudeTrace: return "https://claude.ai/cdn-cgi/trace"
        case .gptTrace: return "https://chatgpt.com/cdn-cgi/trace"
        case .cloudflareUpload: return "https://speed.cloudflare.com/__up"
        case .bingoUpload: return "https://httpbingo.org/upload"
        case .cloudflareDownload: return "https://speed.cloudflare.com/__down?bytes=2000000"
        case .bingoDownload: return "https://httpbingo.org/bytes/262144"
        case .bingoStream: return "https://httpbingo.org/drip?duration=30&numbytes=60&delay=0&code=200"
        }
    }
    public var title: String { switch self { case .bingoUpload, .bingoDownload: return "HTTPBingo 备用端点"; case .bingoStream: return "HTTPBingo 流式端点"; case .claudeTrace: return "Claude"; case .gptTrace: return "GPT"; default: return "Cloudflare" } }
    public var isTrace: Bool { [.cloudflareTrace, .claudeTrace, .gptTrace].contains(self) }
    // HTTPBingo rejects request bodies above roughly 512 KiB with HTTP 500/400, so a 1 MB fallback could never pass.
    public static let fallbackUploadBytes = 500_000
    // Scale only the payload phase to a 1 MB equivalent; the proxy and TLS setup is paid once either way.
    public static func megabyteUploadSeconds(_ response: CurlResult, bytes: Int) -> Double {
        guard bytes > 0, bytes < 1_000_000 else { return response.seconds }
        let setup = min(response.seconds, response.metrics?.tlsSeconds ?? 0)
        return setup + (response.seconds - setup) * 1_000_000 / Double(bytes)
    }
}
public struct StageResult: Codable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var stage: DiagnosticStage
    public var status: StageStatus
    public var endpoint: DiagnosticEndpoint
    public var date: Date = Date()
    public var metrics: TransferMetrics?
    public var failureKind: ProbeFailureKind?
    public var errorCode: Int?
    public var note: String?
    public init(stage: DiagnosticStage, status: StageStatus, endpoint: DiagnosticEndpoint, metrics: TransferMetrics? = nil, failure: ProbeFailure? = nil, note: String? = nil) {
        self.stage = stage; self.status = status; self.endpoint = endpoint; self.metrics = metrics ?? failure?.metrics; self.failureKind = failure?.kind; self.errorCode = failure?.code; self.note = note ?? failure?.errorDescription
    }
}
public struct DiagnosticRequest {
    public let endpoint: DiagnosticEndpoint
    public let frontOnly: Bool
    public let uploadBytes: Int
    public let timeout: Double
    public init(_ endpoint: DiagnosticEndpoint, frontOnly: Bool = false, uploadBytes: Int = 0, timeout: Double = 6) { self.endpoint = endpoint; self.frontOnly = frontOnly; self.uploadBytes = uploadBytes; self.timeout = timeout }
}

public enum DiagnosticRunner {
    public static func run(candidate: String, settings: GuardSettings, kind: MeasurementKind, skipPerformance: String? = nil, cancellation: ProbeCancellation? = nil, onStage: ((String) -> Void)? = nil, transport: (DiagnosticRequest) throws -> CurlResult) throws -> CandidateResult {
        var results: [StageResult] = []; var charged = 0
        var exit: ExitObservation?; var uploadSeconds = 0.0; var downMbps = 0.0
        func attempt(_ stage: DiagnosticStage, _ request: DiagnosticRequest, validate: (CurlResult) throws -> Void = { _ in }) throws -> CurlResult? {
            try cancellation?.check(); onStage?(stage == .residential ? "出口验证" : stage.title)
            var receivedResponse = false
            do {
                let response = try transport(request); receivedResponse = true
                charged += response.transferred
                try validate(response)
                let metrics = response.metrics ?? TransferMetrics(httpStatus: response.httpStatus, totalSeconds: response.seconds, downloadedBytes: response.transferred)
                results.append(StageResult(stage: stage, status: .passed, endpoint: request.endpoint, metrics: metrics)); return response
            } catch is ProbeInterrupted { throw ProbeInterrupted("检测已让行，保留队列等待续测") }
            catch {
                let failure = ProbeFailure.classify(error)
                if !receivedResponse { charged += failure.metrics?.transferred ?? 0 }
                results.append(StageResult(stage: stage, status: .failed, endpoint: request.endpoint, failure: failure)); return nil
            }
        }
        func trace(_ stage: DiagnosticStage, _ endpoint: DiagnosticEndpoint, front: Bool = false) throws -> ExitObservation? {
            var observation: ExitObservation?
            _ = try attempt(stage, DiagnosticRequest(endpoint, frontOnly: front, timeout: kind == .health ? 8 : 6)) { r in
                let value = try ExitObservation.parseTrace(r.body, seconds: r.seconds)
                if !front, value.country == "CN" || (!settings.allowedClaudeIPs.isEmpty && !settings.allowedClaudeIPs.contains(value.ip)) {
                    throw ProbeFailure(kind: .route, metrics: r.metrics, detail: "出口不符合锁定 IP，拒绝作为备用")
                }
                observation = value
            }
            return observation
        }
        func deferred(_ stage: DiagnosticStage, _ endpoint: DiagnosticEndpoint, _ reason: String) { results.append(StageResult(stage: stage, status: .deferred, endpoint: endpoint, note: reason)) }
        _ = try trace(.front, .cloudflareTrace, front: true)
        exit = try trace(.residential, .cloudflareTrace)
        if exit == nil, !results.contains(where: { $0.stage == .residential && $0.failureKind == .route }) { exit = try trace(.residential, .claudeTrace) }
        if exit != nil {
            _ = try trace(.claude, .claudeTrace)
            _ = try trace(.gpt, .gptTrace)
        } else {
            deferred(.claude, .claudeTrace, "出口未验证，目标服务结果待定")
            deferred(.gpt, .gptTrace, "出口未验证，目标服务结果待定")
        }
        if kind == .full || kind == .upload {
            if let reason = skipPerformance { deferred(.upload, .cloudflareUpload, reason); deferred(.download, .cloudflareDownload, reason) }
            else if exit == nil { deferred(.upload, .cloudflareUpload, "出口未验证，不执行性能负载"); deferred(.download, .cloudflareDownload, "出口未验证，不执行性能负载") }
            else {
                let small = try attempt(.smallUpload, DiagnosticRequest(.cloudflareUpload, uploadBytes: 65_536, timeout: 12))
                if small == nil { _ = try attempt(.smallUpload, DiagnosticRequest(.bingoUpload, uploadBytes: 65_536, timeout: 12)) }
                var up = try attempt(.upload, DiagnosticRequest(.cloudflareUpload, uploadBytes: 1_000_000, timeout: 30)) { r in
                    guard (r.metrics?.uploadedBytes ?? r.transferred) >= 1_000_000 else { throw ProbeFailure(kind: .invalid, metrics: r.metrics, detail: "上传字节未完整确认") }
                }
                uploadSeconds = up?.seconds ?? 0
                if up == nil {
                    let bytes = DiagnosticEndpoint.fallbackUploadBytes
                    up = try attempt(.upload, DiagnosticRequest(.bingoUpload, uploadBytes: bytes, timeout: 30)) { r in
                        guard (r.metrics?.uploadedBytes ?? r.transferred) >= bytes else { throw ProbeFailure(kind: .invalid, metrics: r.metrics, detail: "备用上传未完整确认") }
                    }
                    uploadSeconds = up.map { DiagnosticEndpoint.megabyteUploadSeconds($0, bytes: bytes) } ?? 0
                }
                if kind == .full {
                    var bytes = 2_000_000
                    var down = try attempt(.download, DiagnosticRequest(.cloudflareDownload, timeout: 15)) { r in
                        guard (r.metrics?.downloadedBytes ?? r.transferred) >= 2_000_000 else { throw ProbeFailure(kind: .invalid, metrics: r.metrics, detail: "下载数据不完整") }
                    }
                    if down == nil {
                        bytes = 262_144
                        down = try attempt(.download, DiagnosticRequest(.bingoDownload, timeout: 12)) { r in
                            guard (r.metrics?.downloadedBytes ?? r.transferred) >= 262_144 else { throw ProbeFailure(kind: .invalid, metrics: r.metrics, detail: "备用下载数据不完整") }
                        }
                    }
                    if let down = down { downMbps = Double(bytes) * 8 / 1_000_000 / max(0.001, down.seconds) }
                }
            }
        }
        if kind == .stream, exit != nil {
            _ = try attempt(.stream, DiagnosticRequest(.bingoStream, timeout: 40)) { r in
                guard r.seconds >= 27, (r.metrics?.downloadedBytes ?? r.transferred) >= 60 else { throw ProbeFailure(kind: .invalid, metrics: r.metrics, detail: "未形成完整 30 秒流式证据") }
            }
        }
        let passed: (DiagnosticStage) -> Bool = { stage in results.contains { $0.stage == stage && $0.status == .passed } }
        let success: Bool
        switch kind { case .health: success = passed(.residential) && passed(.claude); case .stream: success = passed(.residential) && passed(.stream); case .upload: success = passed(.residential) && passed(.claude) && passed(.upload); case .full: success = passed(.residential) && passed(.claude) && passed(.upload) && passed(.download) }
        let failure = results.first { $0.status == .failed && !passed($0.stage) }
        var measurement = NodeMeasurement(name: candidate, date: Date(), success: success, latencyMS: (exit?.seconds ?? 0) * 1000, uploadSeconds: uploadSeconds, downloadMbps: downMbps, reliability: success ? 1 : 0, samples: 1, failure: success ? nil : failure.map { "\($0.stage.title)：\($0.note ?? "未通过")" }, ip: exit?.ip, country: exit?.country)
        measurement.kind = kind; measurement.diagnostics = results
        measurement.performanceDeferred = skipPerformance != nil
        return CandidateResult(measurement: measurement, chargedBytes: charged)
    }
}

public struct SharedFailure: Equatable {
    public let key: String
    public let title: String
    public let nodeCount: Int
    // Only a suspected common exit fault pauses performance load for every other node.
    public var defersPerformance: Bool { key == "residential" || key == "payload" }
}
public enum SharedFailureDetector {
    // Names such as "中转线路2-台湾01" share one relay entry; flags and region suffixes are not independent evidence.
    public static func lineGroup(_ name: String) -> String {
        let cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !(0x1F1E6...0x1F1FF).contains($0.value) })).trimmingCharacters(in: .whitespaces)
        guard let separator = cleaned.firstIndex(where: { $0 == "-" || $0 == "|" }) else { return name }
        let prefix = cleaned[..<separator].trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? name : prefix
    }
    public static func assess(_ records: [NodeMeasurement], inventory: String?, now: Date = Date()) -> SharedFailure? {
        let recent = records.filter { $0.inventoryKey == inventory && $0.kind != .health && $0.performanceDeferred != true && now.timeIntervalSince($0.date) >= 0 && now.timeIntervalSince($0.date) < 900 }.sorted { $0.date > $1.date }
        var seen = Set<String>(); let sample = recent.filter { seen.insert($0.name).inserted }.prefix(5)
        guard sample.count >= 3 else { return nil }
        let nodes = sample.filter { $0.passed(.front) && !$0.passed(.residential) && !$0.stages.contains { $0.failureKind == .route } }
        if nodes.count >= 3 { return SharedFailure(key: "residential", title: "多个独立前置能连通，但出口链路共同失败；出口或其上游疑似异常", nodeCount: nodes.count) }
        let payload = sample.filter { $0.passed(.residential) && !$0.passed(.upload) && $0.stages.contains { $0.stage == .upload && $0.status == .failed } }
        if payload.count >= 3 {
            let failedNames = Set(payload.map(\.name)); let firstFailure = payload.map(\.date).min() ?? now
            // Another node completing the large upload after the failures began proves the shared exit and service still work.
            let contradicted = recent.contains { !failedNames.contains($0.name) && $0.date >= firstFailure && $0.passed(.upload) }
            let lines = Set(payload.map { lineGroup($0.name) })
            if lines.count == 1, let line = lines.first, !failedNames.contains(line) {
                let peers = contradicted ? "同期其他节点经同一出口通过" : "其他线路尚未同时失败"
                return SharedFailure(key: "line", title: "「\(line)」的 \(payload.count) 个节点在大上传阶段失败，\(peers)；疑似该线路上游异常，不暂缓其他节点性能测试", nodeCount: payload.count)
            }
            if !contradicted { return SharedFailure(key: "payload", title: "多条线路的节点在大上传阶段共同失败；先排查共享出口与测速服务，性能负载暂缓 5 分钟", nodeCount: payload.count) }
        }
        let endpoint = sample.filter { $0.stages.contains { $0.stage == .upload && $0.endpoint == .cloudflareUpload && $0.status == .failed } && $0.stages.contains { $0.stage == .upload && $0.endpoint == .bingoUpload && $0.status == .passed } }
        if endpoint.count >= 3 { return SharedFailure(key: "speed-service", title: "主测速端点多次失败，备用端点通过；主端点疑似异常", nodeCount: endpoint.count) }
        return nil
    }
}
