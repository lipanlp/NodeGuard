import Foundation

/// Claude's own service traffic, not every website opened by its embedded browser.
public enum ClaudeServiceScope {
    public static let domains = ["claude.ai", "claude.com", "anthropic.com", "claudeusercontent.com"]
    public static func contains(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !host.isEmpty else { return false }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(where: { "/:@ ".contains($0) }) else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
