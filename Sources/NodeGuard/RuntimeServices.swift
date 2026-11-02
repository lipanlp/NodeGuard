import Foundation
import AppKit
import Network
import SystemConfiguration
import NodeGuardCore

final class StateWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.nodeguard.state", qos: .utility)
    private let store: StateStore
    init(_ store: StateStore) { self.store = store }
    func write(_ state: StoredState, completion: @escaping (Bool) -> Void) { queue.async { do { try self.store.save(state); completion(true) } catch { completion(false) } } }
    func flush(_ state: StoredState) { queue.sync { try? store.save(state) } }
}

@MainActor final class NetworkLifecycle {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var previous = ""
    private var addressStore: SCDynamicStore?
    private var currentOnline = true
    private var currentLabel = "等待网络"
    var onPath: ((Bool, String, Bool) -> Void)?
    var onSleep: (() -> Void)?
    var onWake: (() -> Void)?
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let receiver = self else { return }
            let online = path.status == .satisfied
            let label = !online ? "离线" : (path.usesInterfaceType(.wifi) ? "Wi-Fi" : (path.usesInterfaceType(.wiredEthernet) ? "有线" : "其他"))
            // No SSID, local IP, gateway address or hardware identifier is retained.
            let signature = "\(online):\(label):\(path.availableInterfaces.map(\.name).sorted()):\(path.supportsIPv4):\(path.supportsIPv6):\(path.supportsDNS)"
            Task { @MainActor in
                let changed = !receiver.previous.isEmpty && receiver.previous != signature
                receiver.previous = signature; receiver.currentOnline = online; receiver.currentLabel = label; receiver.onPath?(online, label, changed)
            }
        }
        monitor.start(queue: DispatchQueue(label: "local.nodeguard.network", qos: .utility))
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        addressStore = SCDynamicStoreCreate(nil, "NodeGuard network changes" as CFString, { _, _, info in
            guard let info = info else { return }
            let receiver = Unmanaged<NetworkLifecycle>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in receiver.onPath?(receiver.currentOnline, receiver.currentLabel, true) }
        }, &context)
        if let store = addressStore {
            SCDynamicStoreSetNotificationKeys(store, ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray, ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6"] as CFArray)
            SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main)
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in guard let receiver = self else { return }; Task { @MainActor in receiver.onSleep?() } })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in guard let receiver = self else { return }; Task { @MainActor in receiver.onWake?() } })
    }
    func stop() { monitor.cancel(); if let store = addressStore { SCDynamicStoreSetDispatchQueue(store, nil) }; addressStore = nil; for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }; observers.removeAll() }
}
