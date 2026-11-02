import Foundation
import Darwin

public final class MihomoClient {
    private static let cacheLock = NSLock()
    private static var frames: [String: (Date, ConnectionsEnvelope)] = [:]
    private static var configs: [String: (Date, CoreConfig)] = [:]
    public let socketPath: String
    public init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"
    }
    public func request(_ method: String, _ path: String, body: Data? = nil) throws -> Data {
        guard !path.contains("\r"), !path.contains("\n") else { throw GuardError.unavailable("无效 API 路径") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw GuardError.unavailable("无法打开 Clash 控制连接") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0); var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw GuardError.unavailable("Clash socket 路径过长") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let connected = withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw GuardError.unavailable("Clash Verge 未运行，或服务控制 socket 不可用") }
        let payload = body ?? Data()
        var request = Data("\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        request.append(payload)
        try request.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard n > 0 else { throw GuardError.unavailable("Clash 控制连接发送失败") }; sent += n
            }
        }
        var response = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n == 0 { break }
            guard n > 0 else { throw GuardError.unavailable("Clash 控制连接超时") }
            response.append(contentsOf: buffer.prefix(n))
            guard response.count <= 8_000_000 else { throw GuardError.unavailable("Clash API 响应超过安全上限") }
        }
        return try Self.parseHTTP(response)
    }
    public static func parseHTTP(_ response: Data) throws -> Data {
        guard let split = response.range(of: Data("\r\n\r\n".utf8)) else { throw GuardError.unavailable("Clash API 响应格式错误") }
        let headers = String(decoding: response[..<split.lowerBound], as: UTF8.self)
        guard let status = headers.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }), (200...299).contains(status) else {
            throw GuardError.unavailable("Clash API 请求失败；请检查代理组和 Clash 版本")
        }
        let body = Data(response[split.upperBound...])
        if headers.lowercased().contains("transfer-encoding: chunked") {
            var result = Data(); var remaining = body
            while let line = remaining.range(of: Data("\r\n".utf8)) {
                let sizeText = String(decoding: remaining[..<line.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
                guard let count = Int(sizeText, radix: 16), count >= 0 else { throw GuardError.unavailable("Clash API 分块响应错误") }
                if count == 0 { return result }
                remaining = Data(remaining[line.upperBound...])
                guard remaining.count >= count + 2 else { throw GuardError.unavailable("Clash API 响应不完整") }
                result.append(remaining.prefix(count)); remaining = Data(remaining.dropFirst(count + 2))
            }
            throw GuardError.unavailable("Clash API 分块响应不完整")
        }
        if let lengthLine = headers.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }), let length = Int(lengthLine.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)), body.count != length {
            throw GuardError.unavailable("Clash API 响应不完整")
        }
        return body
    }
    public func connections(maxAge: Double = 0) throws -> ConnectionsEnvelope {
        Self.cacheLock.lock(); defer { Self.cacheLock.unlock() }
        if let item = Self.frames[socketPath], Date().timeIntervalSince(item.0) < maxAge { return item.1 }
        let frame = try JSONDecoder().decode(ConnectionsEnvelope.self, from: request("GET", "/connections"))
        Self.frames[socketPath] = (Date(), frame); return frame
    }
    public func snapshot(configMaxAge: Double = 0) throws -> CoreSnapshot {
        let decoder = JSONDecoder()
        do {
            let proxies = try decoder.decode(ProxyEnvelope.self, from: request("GET", "/proxies")).proxies
            let config: CoreConfig
            Self.cacheLock.lock(); let cached = Self.configs[socketPath]; Self.cacheLock.unlock()
            if let cached = cached, Date().timeIntervalSince(cached.0) < configMaxAge { config = cached.1 }
            else { config = try decoder.decode(CoreConfig.self, from: request("GET", "/configs")); Self.cacheLock.lock(); Self.configs[socketPath] = (Date(), config); Self.cacheLock.unlock() }
            let connections = try self.connections(maxAge: 0.2)
            return CoreSnapshot(proxies: proxies, connections: connections.connections, config: config, uploadTotal: connections.uploadTotal, downloadTotal: connections.downloadTotal)
        } catch let error as GuardError { throw error }
        catch { throw GuardError.unavailable("无法解析 Clash 状态；不会执行自动切换") }
    }
    public func select(group: String, node: String, expectedCurrent: String, cancellation: ProbeCancellation? = nil) throws {
        let path = "/proxies/" + Self.escape(group)
        let before = try JSONDecoder().decode(ProxyInfo.self, from: request("GET", path))
        guard before.type == "Selector", before.now == expectedCurrent, before.all?.contains(node) == true else {
            throw GuardError.unavailable("代理组被手动修改或候选已消失，取消本次切换")
        }
        try cancellation?.check()
        _ = try request("PUT", path, body: JSONSerialization.data(withJSONObject: ["name": node]))
        let after = try JSONDecoder().decode(ProxyInfo.self, from: request("GET", path))
        guard after.now == node else { throw GuardError.unavailable("Clash 未确认节点切换") }
    }
    public static func escape(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
}
