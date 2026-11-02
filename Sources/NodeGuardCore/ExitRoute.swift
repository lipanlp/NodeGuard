import Foundation

/// The current Claude route, read from Clash rather than inferred from an ISP label.
/// Only the IP is pinned. This route is a live reference for observing connections
/// and constructing isolated tests, and is never saved as an identity requirement.
public struct ExitRoute: Equatable {
    public let node: String
    public let path: [String]
    public static func current(snapshot: CoreSnapshot, settings: GuardSettings) -> ExitRoute? {
        guard let leaf = snapshot.leaf(settings.claudeGroup) else { return nil }
        var path: [String] = []; var seen = Set<String>(); var name = settings.claudeGroup
        while let proxy = snapshot.proxies[name] {
            guard seen.insert(name).inserted else { return nil }
            path.append(name)
            if let next = proxy.now { name = next }
            else if let next = proxy.dialerProxy, !next.isEmpty { name = next }
            else { return ExitRoute(node: leaf, path: path) }
        }
        return nil
    }
    public func matches(_ observation: ExitObservation) -> Bool { observation.chains.contains(node) }
    public func matchesConnection(_ chains: [String], settings: GuardSettings) -> Bool {
        // Established sockets retain their original proxy label after a rename.
        // The recorded Claude policy group remains usable route evidence; a
        // direct bypass of a currently proxied route is still rejected.
        if node != "DIRECT", chains.contains("DIRECT") { return false }
        return chains.contains(node) || chains.contains(settings.claudeGroup)
    }
    public func usesFront(_ settings: GuardSettings) -> Bool { path.contains(settings.frontGroup) }
    /// Front selection is allowed to change without changing this evidence context.
    public func testingContext(_ settings: GuardSettings) -> String {
        let stable = path.prefix(while: { $0 != settings.frontGroup })
        return ([settings.claudeGroup] + stable + [settings.frontGroup]).joined(separator: "\u{0}")
    }
}
