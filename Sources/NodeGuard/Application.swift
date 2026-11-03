import Foundation
import AppKit
import SwiftUI
import Darwin
import CryptoKit
import NodeGuardCore
import UserNotifications

enum AppVersion {
    static let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    static let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    static let display = "\(short) (\(build))"
}

func diagnose(measure: Bool, candidate: String? = nil) -> Int32 {
    var report: [String: Any] = ["version": AppVersion.display, "date": ISO8601DateFormatter().string(from: Date()), "mode": measure ? "isolated-measurement" : "read-only", "global_selection_changed": false, "claude_terminated": false]
    func configHash() -> String { guard let data = try? Data(contentsOf: ClashFiles.configURL) else { return "unreadable" }; return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    let before = configHash()
    do {
        let current = try MihomoClient().snapshot(); let settings = StateStore().load().settings
        if let inventory = try? InventoryReader().read(snapshot: current, settings: settings) { report["subscription"] = inventory.name; report["inventory_key"] = inventory.key }
        report["automatic_full_scan"] = settings.automaticFullScan; report["full_scan_interval_hours"] = settings.fullScanInterval / 3600; report["idle_seconds"] = settings.idleSeconds; report["test_budget_unlimited"] = settings.dailyTestBudgetMB == 0
        report["front"] = current.proxies[settings.frontGroup]?.now ?? "missing"
        report["claude_route"] = current.routeSummary(settings.claudeGroup); report["gpt_route"] = current.routeSummary(settings.gptGroup)
        report["candidate_count"] = current.proxies[settings.frontGroup]?.all?.count ?? 0
        let port = current.config.mixedPort > 0 ? current.config.mixedPort : current.config.httpPort
        let auth = try Probe.localAuthentication()
        for (key, host) in [("claude", "claude.ai"), ("gpt", "chatgpt.com")] {
            do { let exit = try Probe.exit(host: host, port: port, auth: auth, verifyMainRoute: true); report[key] = ["ip": exit.ip, "country": exit.country, "seconds": exit.seconds, "actual_chains": exit.chains] as [String: Any] }
            catch { report[key] = ["error": error.localizedDescription] }
        }
        report["claude_processes_identified"] = ProcessGuard.processes().count
        if measure, let front = candidate ?? current.proxies[settings.frontGroup]?.now {
            report["measured_front"] = front
            let result = try CandidateProbe.measure(candidate: front, snapshot: current, settings: settings, previous: nil)
            let r = result.measurement
            report["measurement"] = ["success": r.success, "score": r.score, "upload_seconds_1mb": r.uploadSeconds, "download_mbps": r.downloadMbps, "failure": r.failure ?? "", "recorded_transfer_bytes": result.chargedBytes] as [String: Any]
        }
    } catch { report["error"] = error.localizedDescription }
    report["clash_config_unchanged"] = before == configHash()
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) { print(text) }
    let exitsOK = ((report["claude"] as? [String: Any])?["error"] == nil) && ((report["gpt"] as? [String: Any])?["error"] == nil)
    let measurementOK = !measure || (report["measurement"] as? [String: Any])?["success"] as? Bool == true
    return report["error"] == nil && exitsOK && measurementOK ? 0 : 1
}

@MainActor final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var item: NSStatusItem!
    var model: MonitorModel!
    private var notificationPresenter: NotificationPresenter?
    private var instanceFD: Int32 = -1
    private var lastStatus = ""
    private var terminationSignal: DispatchSourceSignal?
    private var signalQuit = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let readOnly = CommandLine.arguments.contains("--observe-only")
        if !demo && !claimInstance() { NSApp.terminate(nil); return }
        model = MonitorModel(demo: demo, readOnly: readOnly)
        let receiver = model!
        notificationPresenter = NotificationPresenter(foreground: { [weak receiver] identifier in
            guard let receiver = receiver else { return }; Task { @MainActor in receiver.notificationWillPresent(identifier) }
        }, opened: { [weak self] in guard let receiver = self else { return }; Task { @MainActor in receiver.showWindow() } })
        UNUserNotificationCenter.current().delegate = notificationPresenter
        model.onStatusChange = { [weak self] in self?.updateStatus() }
        let hosting = NSHostingController(rootView: GuardView(model: model))
        window = NSWindow(contentViewController: hosting)
        model.hostWindow = window
        window.title = "节点哨兵 · NodeGuard"; window.setContentSize(NSSize(width: 1150, height: 800)); window.center()
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]; window.delegate = self
        window.isReleasedWhenClosed = false
        if let icon = Bundle.main.url(forResource: "NodeGuard", withExtension: "icns").flatMap(NSImage.init(contentsOf:)) { NSApp.applicationIconImage = icon }
        let menu = NSMenu(); let appMenu = NSMenu(); let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        appMenu.addItem(withTitle: "打开节点哨兵", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出节点哨兵", action: #selector(quit), keyEquivalent: "q").target = self
        NSApp.mainMenu = menu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "打开节点哨兵", action: #selector(showWindow), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "立即检查", action: #selector(check), keyEquivalent: "").target = self
        statusMenu.addItem(withTitle: "暂停 / 恢复监控", action: #selector(pause), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "").target = self
        item.menu = statusMenu; updateStatus(); showWindow(); model.start()
        installTerminationSignal()
    }
    private func claimInstance() -> Bool {
        let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/NodeGuard")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        instanceFD = Darwin.open(cache.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        return instanceFD >= 0 && flock(instanceFD, LOCK_EX | LOCK_NB) == 0
    }
    // SIGTERM（升级替换、launchd、kill）走正常退出流程保存状态并停止候选核心，不弹确认框。
    private func installTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self, !self.signalQuit else { return }
            self.signalQuit = true; self.model?.noteSignalQuit()
            if let sheet = self.window.attachedSheet { self.window.endSheet(sheet, returnCode: .alertFirstButtonReturn) } else { NSApp.terminate(nil) }
        }
        source.resume(); terminationSignal = source
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); model?.setWindowVisible(true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc func check() { model.checkNow() }
    @objc func pause() { model.setPaused(!model.paused) }
    @objc func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) { model?.setWindowVisible(false) }
    func windowDidMiniaturize(_ notification: Notification) { model?.setWindowVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model?.setWindowVisible(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) { model?.setWindowVisible(window.isVisible && window.occlusionState.contains(.visible)) }
    func applicationDidHide(_ notification: Notification) { model?.setWindowVisible(false) }
    func applicationDidUnhide(_ notification: Notification) { model?.setWindowVisible(true) }
    func updateStatus() {
        let status = "\(model.statusTitle):\(model.hasIncident)"
        guard status != lastStatus else { return }; lastStatus = status
        guard let button = item?.button else { return }
        button.image = NSImage(systemSymbolName: model.hasIncident ? "shield.lefthalf.filled.trianglebadge.exclamationmark" : "network.badge.shield.half.filled", accessibilityDescription: model.statusTitle) ?? NSImage(systemSymbolName: "network", accessibilityDescription: model.statusTitle)
        button.title = model.hasIncident ? " !" : ""
        button.toolTip = "节点哨兵 · \(model.statusTitle)"
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.settings.strictProtection == true && !signalQuit {
            let alert = NSAlert(); alert.messageText = "退出后 Claude 将失去保护"; alert.informativeText = "严格保护设置会保留，下次启动继续生效。"; alert.addButton(withTitle: "退出"); alert.addButton(withTitle: "取消")
            guard window.attachedSheet == nil else { return .terminateCancel }
            showWindow()
            alert.beginSheetModal(for: window) { response in NSApp.reply(toApplicationShouldTerminate: response == .alertFirstButtonReturn) }
            return .terminateLater
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { model?.stop(); if instanceFD >= 0 { close(instanceFD) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main struct NodeGuardApplication {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--export-diagnostics"), CommandLine.arguments.count > index + 1 {
            do { let state = StateStore().load(); let connected = (try? MihomoClient().snapshot()) != nil; let data = try DiagnosticExport.data(state: state, version: AppVersion.display, connected: connected, network: "其他", protection: state.settings.strictProtection ? .verifying : .disabled); let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]); try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); print("脱敏诊断已导出"); exit(0) } catch { print("诊断导出失败"); exit(1) }
        }
        if CommandLine.arguments.contains("--diagnose") || CommandLine.arguments.contains("--measure-current") || CommandLine.arguments.contains("--measure-node") {
            let index = CommandLine.arguments.firstIndex(of: "--measure-node")
            let name = index.flatMap { CommandLine.arguments.count > $0 + 1 ? CommandLine.arguments[$0 + 1] : nil }
            if index != nil && name == nil { print("--measure-node requires an exact front-node name"); exit(2) }
            exit(diagnose(measure: CommandLine.arguments.contains("--measure-current") || name != nil, candidate: name))
        }
        let application = NSApplication.shared
        let delegate = ApplicationDelegate()
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
