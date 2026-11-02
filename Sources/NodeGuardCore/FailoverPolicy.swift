import Foundation

public enum FailoverPolicy {
    public static func mayCommit(settings: GuardSettings, snapshot: CoreSnapshot, old: String, quality: NodeMeasurement, health: NodeMeasurement, allowSlowRecovery: Bool = false, now: Date = Date()) -> Bool {
        guard quality.name == health.name, quality.hasFullPerformance, now.timeIntervalSince(quality.date) >= 0, now.timeIntervalSince(quality.date) < 21600,
              (allowSlowRecovery || quality.uploadSeconds <= settings.slowUploadSeconds), quality.country != "CN", settings.allowedClaudeIPs.contains(quality.ip ?? ""),
              health.kind == .health, health.success, health.passed(.residential), health.passed(.claude),
              now.timeIntervalSince(health.date) >= 0, now.timeIntervalSince(health.date) < 30,
              settings.allowedClaudeIPs.contains(health.ip ?? ""), health.country != "CN" else { return false }
        // The fresh health proof and the original performance timestamp remain separate.
        return settings.autoSwitch && settings.candidates.contains(health.name) && health.name != old &&
            !settings.allowedClaudeIPs.isEmpty && snapshot.proxies[settings.frontGroup]?.type == "Selector" &&
            snapshot.proxies[settings.frontGroup]?.now == old && snapshot.proxies[settings.frontGroup]?.all?.contains(health.name) == true &&
            ExitRoute.current(snapshot: snapshot, settings: settings)?.usesFront(settings) == true &&
            ProtectionPolicy.topologyViolation(snapshot: snapshot, settings: settings, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil
    }
    public static func mayCommit(settings: GuardSettings, snapshot: CoreSnapshot, old: String, candidate: NodeMeasurement) -> Bool {
        settings.autoSwitch && !settings.allowedClaudeIPs.isEmpty && settings.candidates.contains(candidate.name) && candidate.name != old &&
        ProtectionPolicy.topologyViolation(snapshot: snapshot, settings: settings, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil &&
        snapshot.config.mode == "rule" && snapshot.proxies[settings.frontGroup]?.type == "Selector" && snapshot.proxies[settings.frontGroup]?.now == old &&
        snapshot.proxies[settings.frontGroup]?.all?.contains(candidate.name) == true && ExitRoute.current(snapshot: snapshot, settings: settings)?.usesFront(settings) == true && candidate.isUsable(allowedIPs: settings.allowedClaudeIPs, maxUpload: settings.slowUploadSeconds)
    }
}
