import Foundation
import SwiftUI
import AppKit
import UserNotifications
import ServiceManagement
import NodeGuardCore
import Darwin
import UniformTypeIdentifiers

private struct RuntimePoll {
    let snapshot: CoreSnapshot
    let inventory: Result<SubscriptionInventory, Error>
    let physical: ByteCounters?
    let probe: ByteCounters?
    let ownPorts: Set<Int>
    let cpu: Double
    let thermalBusy: Bool
}

@MainActor final class MonitorModel: ObservableObject {
    @Published var state: StoredState
    var snapshot: CoreSnapshot?
    @Published var viewRevision = 0
    @Published var protectionPhase = ProtectionPhase.disabled
    @Published var protectionReason = "严格保护未开启"
    @Published var networkStatus = "等待网络"
    @Published var sharedDiagnosis: String?
    @Published var notificationTestBusy = false
    @Published var notificationLocalPreview: String?
    private var notificationTestIdentifier: String?
    private var testForegroundRequested = false
    @Published var notificationTestStatus = "尚未发送测试通知"
    @Published var persistenceHealthy = true
    @Published var optimalCandidate: String?
    @Published var optimalStatus = "等待自动择优评估"
    private var bestTracker = BestNodeTracker()
    private var switchQuietGate = SwitchQuietGate()
    private var switchQuiet = false
    private var networkStableSince = Date()
    private var lastOptimalAssessment = Date.distantPast
    private var lastOptimalProbe = Date.distantPast
    private var ownedTransition: (from: String, to: String, until: Date)?
    @Published var claudeExit: ExitObservation?
    @Published var gptExit: ExitObservation?
    @Published var claudeError: String?
    @Published var gptError: String?
    @Published var connected = false
    @Published var activity = "连接 Clash Verge…"
    @Published var testing = false
    @Published var enrolling = false
    @Published var paused = false
    @Published var notificationsAllowed = false
    @Published var loginEnabled = false
    @Published var subscriptionName = "正在识别订阅…"
    @Published var scanStatus = "等待订阅和空闲检测…"
    @Published var scanProgress = "0 / 0"
    @Published var networkRate = "正在采样"
    let demo: Bool
    let readOnly: Bool
    let store = StateStore()
    private let client = MihomoClient()
    private lazy var writer = StateWriter(store)
    private let lifecycle = NetworkLifecycle()
    private var persistenceTask: Task<Void, Never>?
    private var strictMachine = StrictProtectionMachine()
    private var networkAvailable = true
    private var sleeping = false
    private var monitoringActivity: NSObjectProtocol?
    private var windowVisible = true
    private var lastTickDate = Date()
    private var lastPermissionRefresh = Date.distantPast
    private var lastDerived = Date.distantPast
    private var poolCache: [String] = []
    private var readyCache: [String] = []
    private var summaryCache: [String: HistorySummary] = [:]
    private var backupStatusCache: [String: String] = [:]
    private var metadataEpoch = 0
    private var timer: Timer?
    private var fastBusy = false
    private var exitBusy = false
    private var killBusy = false
    private var lastExitStart = Date.distantPast
    private var lastSpeedStart = Date()
    private var lastSwitch = Date.distantPast
    private var lastRecoveryAttempt = Date.distantPast
    private var lastKill = Date.distantPast
    private var badUploadCount = 0
    private var claudeFailures = 0
    private var claudeAlertGate = ExitAlertGate(), gptAlertGate = ExitAlertGate()
    private var quarantined: [String: Date] = [:]
    private var issues: [String: String] = [:]
    private var revision = 0
    private let inventoryReader = InventoryReader()
    private let cpuSampler = CPUUsageSampler()
    private var queue = FullScanQueue()
    private var activityGate = ActivityGate()
    private var load: LoadDecision?
    private var lastLoadDate = Date.distantPast
    private var pendingInventory: SubscriptionInventory?
    private var pendingSince = Date.distantPast
    private var inventoryStable = false
    private var inventoryProblem: String?
    private var forceRound = false
    private var activeCancellation: ProbeCancellation?
    private var purpose = ""
    private var testingNode = ""
    var onStatusChange: (() -> Void)?
    weak var hostWindow: NSWindow?
    var settings: GuardSettings { state.settings }
    var currentFront: String { snapshot?.proxies[settings.frontGroup]?.now ?? "未连接" }
    var availableNodes: [String] { snapshot?.proxies[settings.frontGroup]?.all ?? [] }
    var orderedNodes: [String] {
        availableNodes.sorted { a, b in
            if (measurement(a)?.hasFullPerformance == true) != (measurement(b)?.hasFullPerformance == true) { return measurement(a)?.hasFullPerformance == true }
            let x = measurement(a)?.score ?? -1, y = measurement(b)?.score ?? -1
            return x == y ? a.localizedStandardCompare(b) == .orderedAscending : x > y
        }
    }
    var hasIncident: Bool { !issues.isEmpty }
    var alertMessage: String { issues.values.sorted().prefix(3).joined(separator: "；") }
    var statusTitle: String { paused ? "已暂停" : (hasIncident ? "有待处理事件" : (connected && claudeExit != nil && gptExit != nil ? "监控运行中" : "正在验证")) }
    var dailyMB: Double { Double(state.testBytes) / 1_000_000 }
    var canScheduleScan: Bool { connected && inventoryStable && !testing }
    var scanFraction: Double { queue.total == 0 ? 0 : Double(queue.completed) / Double(queue.total) }
    private var workloadAllowsTests: Bool { !sleeping && networkAvailable && load?.ready == true && Date().timeIntervalSince(lastLoadDate) < 5 }
    var history: [NodeMeasurement] { state.history ?? state.measurements }
    var incidents: [GuardIncident] { state.incidents ?? [] }
    var backupPool: [String] { poolCache }
    var readyBackups: [String] { readyCache }
    var fullSuccessCount: Int { state.measurements.filter { $0.inventoryKey == state.inventoryKey && $0.hasFullPerformance }.count }
    func summary(_ name: String) -> HistorySummary {
        if let value = summaryCache[name] { return value }
        let result = HistorySummary.calculate(history, name: name, inventory: state.inventoryKey); summaryCache[name] = result; return result
    }
    func backupStatus(_ name: String) -> String {
        if quarantined[name, default: .distantPast] > Date() { return "候选冷却中，稍后复验" }
        if let text = backupStatusCache[name] { return text }
        let text = BackupPlanner.readiness(name: name, history: history, health: state.healthChecks ?? [], inventory: state.inventoryKey, settings: settings)
        backupStatusCache[name] = text; return text
    }
    private var excludedBackups: Set<String> { Set(quarantined.filter { $0.value > Date() }.map(\.key)) }
    private func refreshDerived(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastDerived) >= 15 else { return }
        lastDerived = Date(); summaryCache.removeAll(); backupStatusCache.removeAll()
        let pool = BackupPlanner.pool(available: availableNodes, current: currentFront, settings: settings, history: history, health: state.healthChecks ?? [], inventory: state.inventoryKey, excluding: excludedBackups)
        let ready = BackupPlanner.pool(available: availableNodes, current: currentFront, settings: settings, history: history, health: state.healthChecks ?? [], inventory: state.inventoryKey, requireReady: true, excluding: excludedBackups)
        if pool != poolCache || ready != readyCache { poolCache = pool; readyCache = ready; if windowVisible { viewRevision &+= 1 } }
        if !ready.isEmpty { clear("no-backup") }
    }
    func recentHistory(_ name: String) -> [NodeMeasurement] { history.filter { $0.name == name && $0.inventoryKey == state.inventoryKey && Date().timeIntervalSince($0.date) <= 86400 }.sorted { $0.date < $1.date } }
    func setWindowVisible(_ visible: Bool) { windowVisible = visible; if visible { viewRevision &+= 1; refreshPermissions() } }
    func observedRoute(_ observation: ExitObservation?, fallback: String) -> String {
        guard let observation = observation, !observation.chains.isEmpty else { return snapshot?.routeSummary(fallback) ?? "等待验证" }
        var route = Array(observation.chains.reversed())
        if let leaf = observation.chains.first, let dialer = snapshot?.proxies[leaf]?.dialerProxy, !dialer.isEmpty, let extensionRoute = snapshot?.routeSummary(dialer), !extensionRoute.isEmpty { route.append(extensionRoute) }
        return route.joined(separator: " → ")
    }

    init(demo: Bool = false, readOnly: Bool = false) {
        self.demo = demo; self.readOnly = readOnly; state = demo ? StoredState() : store.load(); state.settings.normalize()
        if readOnly { state.settings.strictProtection = false; state.settings.autoSwitch = false }
        if state.history == nil { state.history = state.measurements }
        if state.switchingJournal == nil { state.switchingJournal = SwitchingJournal.migratingLegacy(state.events, inventory: state.inventoryKey) }
        if state.healthChecks == nil { state.healthChecks = [] }; if state.incidents == nil { state.incidents = [] }
        for item in state.incidents ?? [] where item.resolvedAt == nil { issues[item.key] = item.message }
        for item in state.switchingJournal?.records ?? [] where item.inventoryKey == state.inventoryKey {
            if item.status == .verified { quarantined[item.from] = max(quarantined[item.from] ?? .distantPast, item.date.addingTimeInterval(item.reason == .optimization ? 3600 : 1800)) }
            else { quarantined[item.to] = max(quarantined[item.to] ?? .distantPast, item.date.addingTimeInterval(1800)) }
        }
        if demo { makeDemo() }
        if !demo { loginEnabled = SMAppService.mainApp.status == .enabled }
    }
    func start() {
        guard !demo else { return }
        if !readOnly { CandidateProbe.cleanupAbandonedSessions() }
        if FileManager.default.fileExists(atPath: store.file.path), (try? JSONDecoder().decode(StoredState.self, from: Data(contentsOf: store.file))) == nil {
            issue("state", "主状态文件损坏，已尝试恢复上一份有效备份；请核对锁定 IP 和保护开关")
        }
        if settings.strictProtection { strictMachine.beginVerification("程序启动，先获取新的出口证据"); syncProtection() }
        lifecycle.onPath = { [weak self] online, label, changed in self?.networkChanged(online: online, label: label, changed: changed) }
        lifecycle.onSleep = { [weak self] in self?.systemSleep() }
        lifecycle.onWake = { [weak self] in self?.systemWake() }
        lifecycle.start(); updateMonitoringActivity()
        tick()
        let repeating = Timer(timeInterval: 2, repeats: true) { [weak self] _ in guard let receiver = self else { return }; Task { @MainActor in receiver.tick() } }
        timer = repeating; RunLoop.main.add(repeating, forMode: .common)
        refreshPermissions()
    }
    func stop() {
        timer?.invalidate(); lifecycle.stop(); if let token = monitoringActivity { ProcessInfo.processInfo.endActivity(token); monitoringActivity = nil }; activeCancellation?.cancel("程序退出"); CandidateProbe.stopAll(); persistenceTask?.cancel()
        state.scanCheckpoint = queue.checkpoint
        if !demo && !readOnly { writer.flush(state) }
    }
    func save() {
        guard !demo, !readOnly else { return }
        state.scanCheckpoint = queue.checkpoint ?? state.scanCheckpoint
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self = self else { return }
            self.writer.write(self.state) { [weak self] success in guard let receiver = self else { return }; Task { @MainActor in
                if receiver.persistenceHealthy != success { receiver.persistenceHealthy = success }
            } }
        }
    }
    func changeSettings(_ update: (inout GuardSettings) -> Void) {
        guard !readOnly, !demo else { return }
        activeCancellation?.cancel("设置已改变，稍后重新测速")
        let previous = state.settings
        update(&state.settings); state.settings.normalize(); revision += 1; refreshDerived(force: true); save(); onStatusChange?()
        if !settings.strictProtection { strictMachine.disable(); syncProtection() }
        if previous.autoSwitch != settings.autoSwitch || previous.preferBestNode != settings.preferBestNode { bestTracker.reset(); lastOptimalAssessment = .distantPast }
        if previous.idleSeconds != settings.idleSeconds || previous.testingSensitivity != settings.testingSensitivity { activityGate.reset(); load = nil }
        if previous.fullScanInterval != settings.fullScanInterval, queue.pending.isEmpty, let last = state.lastFullScan {
            if Date().timeIntervalSince(last) >= settings.fullScanInterval { queue.schedule() }
            else { queue.resumeAfterCompleted(last, interval: settings.fullScanInterval) }
        }
    }
    func measurement(_ name: String) -> NodeMeasurement? { guard demo || inventoryStable else { return nil }; return state.measurements.first { $0.name == name && $0.inventoryKey == state.inventoryKey } }
    func setAutomaticScan(_ enabled: Bool) { changeSettings { $0.automaticFullScan = enabled }; if !enabled { forceRound = false }; refreshScanStatus() }
    func enableNotifications() {
        guard !demo, !readOnly else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let receiver = self else { return }
            if settings.authorizationStatus == .denied {
                Task { @MainActor in receiver.notificationTestStatus = "系统通知已拒绝，请在 macOS 通知设置中允许节点哨兵"; receiver.openNotificationSettings() }
            } else {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in Task { @MainActor in
                    receiver.notificationsAllowed = ok
                    receiver.notificationTestStatus = ok ? "系统已允许通知，可发送测试通知" : "系统未授予通知权限，请在 macOS 通知设置中允许节点哨兵"
                    if !ok { receiver.openNotificationSettings() }
                } }
            }
        }
    }
    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    func setLoginEnabled(_ enabled: Bool) {
        guard !demo, !readOnly else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { showError("请在 macOS 系统设置的登录项中允许节点哨兵启动。"); SMAppService.openSystemSettingsLoginItems() }
        } catch { loginEnabled = SMAppService.mainApp.status == .enabled; showError("登录启动设置失败：\(error.localizedDescription)。请先将应用固定放置后再尝试。") }
    }
    func setCandidate(_ name: String, enabled: Bool) {
        changeSettings { s in if enabled { if !s.candidates.contains(name) { s.candidates.append(name) } } else { s.candidates.removeAll { $0 == name } } }
    }
    func checkNow() { lastExitStart = .distantPast; tick() }
    func refreshPermissions() {
        lastPermissionRefresh = Date()
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] result in guard let receiver = self else { return }; Task { @MainActor in
            let allowed = result.authorizationStatus == .authorized || result.authorizationStatus == .provisional
            if receiver.notificationsAllowed != allowed { receiver.notificationsAllowed = allowed }
        } }
    }
    func notificationWillPresent(_ identifier: String) {
        guard identifier == notificationTestIdentifier else { return }
        testForegroundRequested = true
        notificationTestStatus = "程序已请求前台横幅和声音，正在等待通知中心回执"
    }
    func testNotification() {
        guard !readOnly, !demo, !notificationTestBusy else { return }
        guard notificationsAllowed else { notificationTestStatus = "尚未允许系统通知，请先授权"; notificationLocalPreview = "请允许节点哨兵发送系统通知"; refreshPermissions(); return }
        notificationTestBusy = true; testForegroundRequested = false
        notificationLocalPreview = "点击已响应：3 秒后发送系统测试通知。这是应用内反馈。"
        notificationTestStatus = "系统测试通知将在 3 秒后发送…"
        let identifier = "NodeGuard-test-" + UUID().uuidString; notificationTestIdentifier = identifier
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            guard let self = self, self.notificationTestIdentifier == identifier, self.notificationTestBusy else { return }
            self.notificationTestBusy = false; self.notificationTestIdentifier = nil
            self.notificationTestStatus = "通知自检等待超时，未确认系统展示，请检查通知设置或重试"
            self.notificationLocalPreview = "点击已响应，但系统通知尚未确认展示"
        }
        let content = UNMutableNotificationContent(); content.title = "节点哨兵 · 通知自检"; content.body = "系统通知测试成功。点击可返回节点哨兵。"; content.sound = .default
        content.interruptionLevel = .active
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)) { [weak self] error in
            guard let receiver = self else { return }
            let failed = error != nil
            Task { @MainActor in
                guard receiver.notificationTestIdentifier == identifier else { return }
                if failed { receiver.notificationTestBusy = false; receiver.notificationTestStatus = "系统拒绝测试通知，请检查 macOS 通知设置"; receiver.notificationLocalPreview = "系统通知未提交成功，请打开通知设置检查权限"; return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                guard receiver.notificationTestIdentifier == identifier else { return }
                receiver.notificationTestBusy = false
                let recorded = delivered.contains { $0.request.identifier == identifier }
                if recorded {
                    receiver.notificationTestStatus = receiver.testForegroundRequested ? "通知中心已收件，前台横幅和声音已请求" : "通知中心已收件；如未见横幅，请检查专注模式和屏幕共享设置"
                    receiver.notificationLocalPreview = "系统已记录本次测试。未见横幅时，请检查「系统设置 → 通知 → 当镜像或共享屏幕时」及专注模式。"
                } else {
                    receiver.notificationTestStatus = "暂未查到通知回执，不能确认系统展示成功"
                    receiver.notificationLocalPreview = "已提交但未确认展示，请检查系统通知设置或重试"
                }
            }
        }
    }
    func exportDiagnostics() {
        guard let window = hostWindow else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "NodeGuard-诊断-" + StateStore.dayKey() + ".json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let receiver = self else { return }
            Task { @MainActor in
                do { let data = try DiagnosticExport.data(state: receiver.state, version: "0.4.2", connected: receiver.connected, network: receiver.networkStatus, protection: receiver.protectionPhase); try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); receiver.event("info", "已导出脱敏诊断：不含密钥、原始配置、IP、节点名称或会话内容") }
                catch { receiver.showError("诊断导出失败，请选择可写入的位置。") }
            }
        }
    }
    private func syncProtection() {
        if protectionPhase != strictMachine.phase { protectionPhase = strictMachine.phase }
        if protectionReason != strictMachine.reason { protectionReason = strictMachine.reason }
    }
    private func beginVerification(_ reason: String) {
        revision += 1; metadataEpoch += 1; activeCancellation?.cancel(reason); claudeExit = nil; gptExit = nil
        networkStableSince = Date(); bestTracker.reset(); switchQuietGate.reset(); switchQuiet = false
        activityGate.reset(); load = nil; lastExitStart = .distantPast
        if settings.strictProtection { strictMachine.beginVerification(reason); syncProtection() }
    }
    private func networkChanged(online: Bool, label: String, changed: Bool) {
        networkAvailable = online; if networkStatus != label { networkStatus = label }
        if !online { activeCancellation?.cancel("本机网络离线"); issue("network", "本机网络离线，测速已暂停") }
        else { clear("network") }
        if changed { beginVerification("网络路径变化，重新核对路由与出口"); event("info", online ? "网络已变化，正在复验出口；全量队列保留" : "本机已离线，保留未完成测试") }
        if online && !sleeping { tick() }
    }
    private func updateMonitoringActivity() {
        let needed = !paused && !sleeping && !demo && !readOnly
        if needed && monitoringActivity == nil { monitoringActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "按用户设置持续监测代理出口和故障；允许电脑正常睡眠") }
        else if !needed, let token = monitoringActivity { ProcessInfo.processInfo.endActivity(token); monitoringActivity = nil }
    }
    private func systemSleep() { sleeping = true; updateMonitoringActivity(); activeCancellation?.cancel("电脑即将睡眠"); activityGate.reset(); load = nil; if settings.strictProtection { strictMachine.sleep(); syncProtection() }; save() }
    private func systemWake() { sleeping = false; updateMonitoringActivity(); lastTickDate = Date(); beginVerification("电脑唤醒，等待新的网络与出口证据"); refreshPermissions(); tick() }

    func setPaused(_ value: Bool) {
        if value && settings.strictProtection {
            let alert = NSAlert(); alert.messageText = "暂停将同时解除 Claude 强制退出保护"; alert.informativeText = "恢复监控后需要重新开启严格保护。"; alert.addButton(withTitle: "暂停并解除保护"); alert.addButton(withTitle: "取消")
            Task { if await confirm(alert) { changeSettings { $0.strictProtection = false }; activeCancellation?.cancel("监控已暂停"); paused = true; updateMonitoringActivity(); refreshScanStatus(); onStatusChange?() } }
            return
        }
        paused = value; updateMonitoringActivity()
        if value { activeCancellation?.cancel("监控已暂停") } else { activityGate.reset(); load = nil; checkNow() }; refreshScanStatus(); onStatusChange?()
    }
    private func tick() {
        guard !paused, !demo, !sleeping else { return }
        if Date().timeIntervalSince(lastTickDate) > 15 { beginVerification("检测到长时间采样间隔，重新验证出口") }
        lastTickDate = Date()
        if Date().timeIntervalSince(lastPermissionRefresh) >= 60 { refreshPermissions() }
        if settings.strictProtection, let reason = strictMachine.evaluate(grace: settings.unverifiedGrace) { trip(reason) }; syncProtection()
        if settings.strictProtection && strictMachine.needsNetworkRecovery {
            if issues["network-hold"] == nil { issue("network-hold", settings.autoSwitch ? "Claude 出口持续不通但未见 IP 或路由异常，保留 Claude，正在更换前置重试" : "Claude 出口持续不通但未见 IP 或路由异常，保留 Claude；自动切换未开启，请手动更换前置") }
        } else if issues["network-hold"] != nil { clear("network-hold") }
        if !networkAvailable { return }
        if testing && purpose != "recovery" && Date().timeIntervalSince(lastLoadDate) > 6 { activeCancellation?.cancel("网络状态采样过期，先让行") }
        if !fastBusy {
            fastBusy = true
            let reader = inventoryReader; let options = settings; let cpuReader = cpuSampler; let epoch = metadataEpoch
            Task {
                let result = await Task.detached(priority: .utility) { Result { () -> RuntimePoll in
                    let snapshot = try MihomoClient().snapshot(configMaxAge: options.strictProtection ? 0 : 10)
                    let inventory = Result { try reader.read(snapshot: snapshot, settings: options) }
                    let cpu = cpuReader.sample() ?? 0
                    let thermal = ProcessInfo.processInfo.thermalState
                    return RuntimePoll(snapshot: snapshot, inventory: inventory, physical: ByteCounters.physical(), probe: ProbeRuntime.counters(), ownPorts: ProbeRuntime.ownPorts(), cpu: cpu, thermalBusy: thermal == .critical || (options.testingSensitivity == .conservative && thermal == .serious))
                } }.value
                fastBusy = false
                guard epoch == metadataEpoch, !sleeping else { return }
                switch result {
                case .success(let sample):
                    let value = sample.snapshot
                    snapshot = value; if !connected { connected = true }; clear("clash"); if settings.strictProtection { strictMachine.routeAvailable() }
                    acceptInventory(sample.inventory)
                    observeFrontSelection()
                    switchQuiet = switchQuietGate.sample(value, ownPorts: sample.ownPorts)
                    load = activityGate.sample(snapshot: value, physical: sample.physical, probe: sample.probe, ownPorts: sample.ownPorts, cpuFraction: sample.cpu, thermalBusy: sample.thermalBusy, idleSeconds: settings.idleSeconds, sensitivity: settings.testingSensitivity)
                    lastLoadDate = Date()
                    if let load = load {
                        if windowVisible { networkRate = String(format: "↑ %.1f / ↓ %.1f KB/s · CPU %.0f%%", load.upKB, load.downKB, sample.cpu * 100) }
                        if load.busy && purpose != "recovery" { activeCancellation?.cancel("让行：\(load.reason)") }
                    }
                    if !testing && windowVisible { let text = "已连接 Clash Verge · \(value.connections.count) 条连接"; if activity != text { activity = text } }
                    let paths = ProcessGuard.monitoredPathPrefixes()
                    if let reason = ProtectionPolicy.topologyViolation(snapshot: value, settings: settings, claudePaths: paths) { issue("topology", reason); trip(reason) } else { clear("topology") }
                    if value.proxies[settings.frontGroup]?.type != "Selector" { issue("selector", "前置节点组不是手动 Selector，自动切换已暂停") } else { clear("selector") }
                    refreshDerived(); if windowVisible { viewRevision &+= 1 }; refreshScanStatus(); considerBestNode(); maintainBackups(); advanceScan()
                case .failure:
                    connected = false; inventoryStable = false; activeCancellation?.cancel("Clash 已断开"); activityGate.reset(); load = nil; refreshScanStatus(); activity = "Clash Verge 未连接"; issue("clash", "Clash 控制接口断开，暂时无法确认代理路线"); if settings.strictProtection { strictMachine.routeUnavailable(); syncProtection() }
                }
                onStatusChange?()
            }
        }
        let interval = settings.strictProtection ? 5.0 : 15.0
        if !exitBusy && Date().timeIntervalSince(lastExitStart) >= interval, let current = snapshot, connected {
            lastExitStart = Date(); probeExits(current)
        }
        let exitDown = claudeFailures >= 2 || (settings.strictProtection && strictMachine.needsNetworkRecovery)
        // A dead exit outranks background scans; free the probe slot for recovery.
        if settings.autoSwitch && exitDown && testing && purpose != "recovery" && Date().timeIntervalSince(lastRecoveryAttempt) >= 60 { activeCancellation?.cancel("出口不通，先更换前置恢复") }
        if settings.autoSwitch && !testing && connected && inventoryStable {
            if exitDown && Date().timeIntervalSince(lastRecoveryAttempt) >= 60 { recover(hard: true) }
            else if badUploadCount >= 2 && Date().timeIntervalSince(lastRecoveryAttempt) >= 60 { recover(hard: false) }
            else if Date().timeIntervalSince(lastSpeedStart) >= settings.slowCheckInterval && workloadAllowsTests { checkUpload() }
        }
        refreshScanStatus(); considerBestNode(); maintainBackups(); advanceScan()
    }
    private func probeExits(_ current: CoreSnapshot) {
        exitBusy = true; let version = revision
        Task {
            let port = current.config.mixedPort > 0 ? current.config.mixedPort : current.config.httpPort
            let pair = await Task.detached(priority: .utility) { () async -> (Result<ExitObservation, Error>, Result<ExitObservation, Error>) in
                let auth: String?
                do { auth = try Probe.localAuthentication() } catch { return (.failure(error), .failure(error)) }
                async let c = Task.detached(priority: .utility) { Result { try Probe.exit(host: "claude.ai", port: port, auth: auth, verifyMainRoute: true) } }.value
                async let g = Task.detached(priority: .utility) { Result { try Probe.exit(host: "chatgpt.com", port: port, auth: auth, verifyMainRoute: true) } }.value
                return await (c, g)
            }.value
            exitBusy = false
            guard !paused, version == revision else { return }
            switch pair.0 {
            case .success(let value):
                claudeExit = value; claudeError = nil; claudeFailures = 0; claudeAlertGate.passed(); clear("claude-network")
                if snapshot.flatMap({ ExitRoute.current(snapshot: $0, settings: settings) })?.matches(value) != true { let reason = "Claude 实际探测连接与当前出口路由不一致，无法确认锁定 IP"; issue("claude-route", reason); trip(reason) } else { clear("claude-route") }
                if value.country == "CN" { issue("claude-country", "Claude 出口回到中国大陆"); trip("Claude 出口回到中国大陆") } else { clear("claude-country") }
                if !settings.allowedClaudeIPs.isEmpty, let reason = ProtectionPolicy.exitViolation(value, allowedIPs: settings.allowedClaudeIPs) { issue("claude-ip", reason); trip(reason) } else { clear("claude-ip") }
                if connected, let s = snapshot, ExitRoute.current(snapshot: s, settings: settings)?.matches(value) == true, !settings.allowedClaudeIPs.isEmpty,
                   ProtectionPolicy.exitViolation(value, allowedIPs: settings.allowedClaudeIPs) == nil,
                   ProtectionPolicy.topologyViolation(snapshot: s, settings: settings, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil { clear("protection"); if settings.strictProtection { strictMachine.verified(at: value.date); syncProtection() } }
            case .failure(let error):
                let failure = ProbeFailure.classify(error); claudeError = failure.localizedDescription; if failure.kind != .local { claudeFailures += 1 }
                if claudeAlertGate.failed() { issue("claude-network", "Claude 出口连续 \(claudeAlertGate.failures) 次探测未通过，暂时无法验证：\(failure.localizedDescription)", since: claudeAlertGate.firstFailure, observations: claudeAlertGate.failures) }
                if settings.strictProtection { strictMachine.failed(failure.kind); syncProtection() }
            }
            switch pair.1 {
            case .success(let value):
                gptExit = value; gptError = nil; gptAlertGate.passed(); clear("gpt-network")
                if value.country == "CN" { issue("gpt-country", "GPT 出口回到中国大陆") } else { clear("gpt-country") }
            case .failure(let error):
                gptError = error.localizedDescription
                if gptAlertGate.failed() { issue("gpt-network", "GPT 出口连续 \(gptAlertGate.failures) 次探测未通过，暂时无法验证：\(error.localizedDescription)", since: gptAlertGate.firstFailure, observations: gptAlertGate.failures) }
            }
            onStatusChange?()
        }
    }
    func enrollCurrentExit() {
        guard !enrolling, !demo, !readOnly, !settings.strictProtection else { return }
        enrolling = true
        let proposed = settings; let version = revision
        Task {
            defer { enrolling = false }
            let result = await Task.detached(priority: .utility) { Result { () -> [ExitObservation] in
                let client = MihomoClient(); let before = try client.snapshot()
                let port = before.config.mixedPort > 0 ? before.config.mixedPort : before.config.httpPort
                let auth = try Probe.localAuthentication()
                let a = try Probe.exit(host: "claude.ai", port: port, auth: auth, verifyMainRoute: true)
                let b = try Probe.exit(host: "claude.ai", port: port, auth: auth, verifyMainRoute: true)
                let after = try client.snapshot()
                guard ProtectionPolicy.topologyViolation(snapshot: before, settings: proposed, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil,
                      ProtectionPolicy.topologyViolation(snapshot: after, settings: proposed, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil,
                      ExitRoute.current(snapshot: before, settings: proposed) == ExitRoute.current(snapshot: after, settings: proposed),
                      ProtectionPolicy.canEnroll(snapshot: after, settings: proposed, observations: [a, b]) else { throw GuardError.unavailable("路由、国家或两次出口结果不一致，拒绝锁定") }
                return [a, b]
            } }.value
            guard version == revision, !settings.strictProtection else { showError("核对期间设置或出口上下文已改变，请重新锁定。"); return }
            switch result {
            case .success(let observations):
                let value = observations[0]
                let alert = NSAlert(); alert.messageText = "锁定当前出口 IP \(value.ip)？"
                alert.informativeText = "Claude 实际出口已连续两次核对一致，国家 \(value.country)。只锁定此 IP，不限定运营商或节点名称。确认时会再次核验，地址以后变化不会自动更新。"
                alert.addButton(withTitle: "锁定此 IP"); alert.addButton(withTitle: "取消")
                if await confirm(alert) {
                    do {
                        let latest = try await Task.detached(priority: .utility) { () -> ExitObservation in
                            let client = MihomoClient(); let before = try client.snapshot()
                            let port = before.config.mixedPort > 0 ? before.config.mixedPort : before.config.httpPort
                            let fresh = try Probe.exit(host: "claude.ai", port: port, auth: try Probe.localAuthentication(), verifyMainRoute: true)
                            let after = try client.snapshot()
                            guard ProtectionPolicy.exitViolation(fresh, allowedIPs: [value.ip]) == nil,
                                  ExitRoute.current(snapshot: before, settings: proposed) == ExitRoute.current(snapshot: after, settings: proposed),
                                  ExitRoute.current(snapshot: after, settings: proposed)?.matches(fresh) == true,
                                  ProtectionPolicy.topologyViolation(snapshot: after, settings: proposed, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil else { throw GuardError.unavailable("确认期间出口已改变或无法复验，原锁定值保留，请重新核对") }
                            return fresh
                        }.value
                        guard version == revision, !settings.strictProtection else { showError("确认期间设置已改变，原锁定值保留，请重新锁定。"); return }
                        changeSettings { $0.allowedClaudeIPs = [latest.ip] }; claudeExit = latest; claudeError = nil
                        event("info", "已由用户锁定当前出口 IP，不限制运营商或节点名称")
                    } catch { showError(error.localizedDescription) }
                }
            case .failure(let error): showError(error.localizedDescription)
            }
        }
    }
    func toggleStrict(_ enabled: Bool) {
        if !enabled { changeSettings { $0.strictProtection = false }; clear("protection"); event("info", "已解除 Claude 严格保护"); return }
        guard !demo, !readOnly, !settings.allowedClaudeIPs.isEmpty, connected, let s = snapshot, let exit = claudeExit,
              Date().timeIntervalSince(exit.date) < 10, claudeError == nil,
              ProtectionPolicy.topologyViolation(snapshot: s, settings: settings, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil,
              ExitRoute.current(snapshot: s, settings: settings)?.matches(exit) == true, ProtectionPolicy.exitViolation(exit, allowedIPs: settings.allowedClaudeIPs) == nil else {
            showError("先锁定当前出口 IP，并完成一次最新的正常出口验证，再开启严格保护。"); checkNow(); return
        }
        let alert = NSAlert(); alert.messageText = "开启 Claude 严格保护？"
        alert.informativeText = "确认出口 IP 改变、回到国内或实际路由绕行时强制结束 Claude 桌面端；Clash 控制接口不可用、无法核对路由时最多复验 \(Int(settings.unverifiedGrace)) 秒后退出。出口仅仅不通时保留 Claude，并在自动切换开启时更换前置重试。启动和唤醒也会重新取证，期间界面显示正在复验。未保存内容可能丢失。锁定 IP 不会自动更新，不限制运营商。Claude Code 和终端不纳入。检测有秒级间隔，不能保证零泄漏。"
        alert.addButton(withTitle: "开启强制退出保护"); alert.addButton(withTitle: "取消")
        Task {
            if await confirm(alert) {
                guard let s = snapshot, let exit = claudeExit, claudeError == nil, Date().timeIntervalSince(exit.date) < 10,
                      ProtectionPolicy.topologyViolation(snapshot: s, settings: settings, claudePaths: ProcessGuard.monitoredPathPrefixes()) == nil,
                      ExitRoute.current(snapshot: s, settings: settings)?.matches(exit) == true, ProtectionPolicy.exitViolation(exit, allowedIPs: settings.allowedClaudeIPs) == nil else { showError("确认期间出口状态已改变，请完成最新检查后再开启。"); return }
                changeSettings { $0.strictProtection = true }; strictMachine.verified(at: exit.date); syncProtection(); event("info", "Claude 严格保护已开启")
            }
        }
    }
    func toggleAuto(_ enabled: Bool) {
        if enabled && ((settings.candidates.isEmpty && readyBackups.isEmpty) || settings.allowedClaudeIPs.isEmpty) { showError("自动切换前，请先锁定当前出口 IP，并等待自动备用池就绪，或手动勾选备用节点。"); return }
        changeSettings { $0.autoSwitch = enabled }; event("info", enabled ? "前置节点自动切换已开启" : "前置节点自动切换已关闭")
    }
    func runRanking() {
        guard !testing, !demo, !readOnly, inventoryStable else { return }
        queue.schedule(); state.lastFullScan = nil; forceRound = true; save(); refreshScanStatus(); advanceScan()
    }
    private func acceptInventory(_ result: Result<SubscriptionInventory, Error>) {
        switch result {
        case .failure(let error):
            inventoryStable = false; activeCancellation?.cancel("订阅更新中，暂停测速")
            inventoryProblem = error.localizedDescription; scanStatus = error.localizedDescription
            return
        case .success(let value):
            inventoryProblem = nil
            if queue.inventory?.key == value.key {
                inventoryStable = true; pendingInventory = nil; if subscriptionName != value.name { subscriptionName = value.name }; clear("subscription"); return
            }
            inventoryStable = false; subscriptionName = value.name + " · 配置稳定确认中"
            if pendingInventory?.key != value.key {
                pendingInventory = value; pendingSince = Date(); revision += 1
                activeCancellation?.cancel("订阅或节点定义已改变，丢弃旧测速")
                return
            }
            guard Date().timeIntervalSince(pendingSince) >= 6 else { return }
            let previousKey = state.inventoryKey; let completedAt = state.lastFullScan
            let needsUpgrade = state.diagnosticSchema != 1
            _ = queue.replace(value)
            if !needsUpgrade, let checkpoint = state.scanCheckpoint, queue.restore(checkpoint, inventory: value) { }
            else if !needsUpgrade, previousKey == value.key, let completedAt = completedAt { queue.resumeAfterCompleted(completedAt, interval: settings.fullScanInterval) }
            else { state.lastFullScan = nil }
            state.diagnosticSchema = 1; state.inventoryKey = value.key; summaryCache.removeAll(); subscriptionName = value.name; inventoryStable = true; pendingInventory = nil
            state.settings.candidates = state.settings.candidates.filter { value.nodes.contains($0) }
            quarantined.removeAll(); badUploadCount = 0; activityGate.reset(); load = nil
            lastExitStart = .distantPast; clear("subscription")
            if previousKey != value.key || needsUpgrade { sharedDiagnosis = nil; state.performanceRetryAt = nil; clear("shared") }
            else { sharedDiagnosis = SharedFailureDetector.assess(history, inventory: state.inventoryKey)?.title }
            event("info", "已关联订阅「\(value.name)」，\(value.nodes.count) 个前置节点将按空闲时间自动测试；旧订阅排名单独保存")
            refreshDerived(force: true); save()
        }
    }
    private func refreshScanStatus() {
        let progress = "\(queue.completed) / \(queue.total)"; if scanProgress != progress { scanProgress = progress }
        let text: String
        if demo { text = "演示模式" }
        else if readOnly { text = "只读验收，不发起自动测速" }
        else if sleeping { text = "电脑睡眠，队列已保存" }
        else if !networkAvailable { text = "本机网络离线，保留未完成队列" }
        else if paused { text = "已暂停" }
        else if !connected { text = "等待 Clash Verge" }
        else if !inventoryStable { text = inventoryProblem ?? "订阅配置更新中，等待稳定后重新排队" }
        else if testing { text = purpose == "scan" ? "正在分层测试：\(testingNode)（\(scanProgress)）" : "\(purpose == "backup" ? "维护备用" : (purpose == "stream" ? "30 秒流式检查" : "线路健康检查"))：\(testingNode)" }
        else if !settings.automaticFullScan && !forceRound { text = "全量自动测速已关闭" }
        else if !queue.pending.isEmpty { text = load?.ready == true ? "准备续测下一个节点" : (load?.reason ?? "等待网络采样") }
        else if let due = queue.nextRound { text = "本轮检查完成 · 完整性能通过 \(fullSuccessCount) 个 · 下轮 \(due.formatted(date: .abbreviated, time: .shortened))" }
        else { text = "等待全量测试队列" }
        if scanStatus != text { scanStatus = text }
    }
    private func advanceScan() {
        guard !demo, !readOnly, !paused, !enrolling, connected, inventoryStable, !testing,
              settings.automaticFullScan || forceRound else { return }
        let wasComplete = queue.pending.isEmpty
        queue.beginDueRound()
        if wasComplete && !queue.pending.isEmpty { state.lastFullScan = nil; save() }
        guard workloadAllowsTests, let name = queue.pending.first, let current = snapshot, let key = queue.inventory?.key else { return }
        if settings.autoSwitch && (claudeFailures >= 2 || Date().timeIntervalSince(lastSpeedStart) >= settings.slowCheckInterval) && (state.switchingJournal ?? SwitchingJournal()).block(reason: .failure, candidate: nil, inventory: state.inventoryKey) == nil { return }
        guard reserve(CandidateProbe.reservationBytes) else { return }
        let token = ProbeCancellation(); activeCancellation = token; testing = true; purpose = "scan"; testingNode = name
        let version = revision; let options = settings; let previous = measurement(name)
        let skip = state.performanceRetryAt.map { $0 > Date() } == true ? "共享依赖疑似异常，暂缓性能负载，保留基础检测" : nil
        activity = "正在测试 \(name)…"; refreshScanStatus()
        Task {
            let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: current, settings: options, previous: previous, cancellation: token, expectedInventory: key, skipPerformance: skip) } }.value
            testing = false; activeCancellation = nil; purpose = ""; testingNode = ""
            guard !paused, version == revision, key == state.inventoryKey, inventoryStable else { refreshScanStatus(); return }
            switch result {
            case .success(let result): update(result.measurement, key: key)
            case .failure(let error):
                if error is ProbeInterrupted { activity = error.localizedDescription; refreshScanStatus(); return }
                update(.failed(name, previous: previous, reason: error.localizedDescription), key: key)
            }
            queue.finish(node: name, inventoryKey: key, interval: settings.fullScanInterval)
            if name == currentFront, measurement(name)?.stages.contains(where: { $0.stage == .upload && $0.status != .deferred }) == true { lastSpeedStart = Date() }
            if queue.pending.isEmpty {
                if let retry = state.performanceRetryAt { queue.retryEarlier(at: max(Date().addingTimeInterval(15), retry)) }
                forceRound = false; state.lastFullScan = Date(); event("info", "订阅「\(subscriptionName)」本轮 \(queue.total) 个前置节点测试完成")
            }
            refreshScanStatus(); save()
        }
    }
    private func checkUpload() {
        if let retry = state.performanceRetryAt, retry > Date() { lastSpeedStart = retry.addingTimeInterval(-settings.slowCheckInterval); return }
        guard !enrolling, let current = snapshot, !testing, let name = current.proxies[settings.frontGroup]?.now, reserve(CandidateProbe.reservationBytes) else { lastSpeedStart = Date(); return }
        testing = true; purpose = "upload"; let token = ProbeCancellation(); activeCancellation = token
        lastSpeedStart = Date(); let options = settings; let version = revision; let previous = measurement(name); let key = state.inventoryKey
        Task {
            let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: current, settings: options, previous: previous, includeDownload: false, cancellation: token, expectedInventory: key) } }.value
            testing = false; activeCancellation = nil; purpose = ""
            guard !paused, version == revision, key == state.inventoryKey, inventoryStable else { return }
            switch result {
            case .success(let value):
                update(value.measurement, key: key)
                if let poor = UploadRecoveryEvidence.poor(value.measurement, maxUpload: settings.slowUploadSeconds) { badUploadCount = poor ? badUploadCount + 1 : 0 }
            case .failure(let error): if error is ProbeInterrupted { return }
            }
            if badUploadCount >= 2 { recover(hard: false) }
        }
    }
    private func recover(hard: Bool) {
        guard settings.autoSwitch, !enrolling, !testing, let start = snapshot, let old = start.proxies[settings.frontGroup]?.now,
              start.proxies[settings.frontGroup]?.type == "Selector", ExitRoute.current(snapshot: start, settings: settings)?.usesFront(settings) == true else { return }
        lastRecoveryAttempt = Date()
        if let blocked = (state.switchingJournal ?? SwitchingJournal()).block(reason: .failure, candidate: nil, inventory: state.inventoryKey) { issue("switch-budget", blocked + "；当前故障请人工处理"); return }
        if !hard && Date().timeIntervalSince(lastSwitch) < 600 { return }
        testing = true; purpose = "recovery"
        var policyOptions = settings
        policyOptions.candidates = Array(Set(settings.candidates + (settings.automaticBackupPool ? availableNodes : [])))
        let options = policyOptions
        let names = BackupPlanner.recoveryCandidates(available: availableNodes, current: old, settings: options, history: history, health: state.healthChecks ?? [], inventory: state.inventoryKey, hard: hard, excluding: excludedBackups)
        let version = revision; let key = state.inventoryKey
        let token = ProbeCancellation(); activeCancellation = token
        Task {
            defer { testing = false; purpose = ""; activeCancellation = nil; refreshScanStatus() }
            for name in names.prefix(5) {
                guard !paused, version == revision, settings.autoSwitch, key == state.inventoryKey, inventoryStable else { return }
                var quality = hard ? BackupPlanner.recoveryQuality(name: name, history: history, inventory: key, settings: options) : BackupPlanner.quality(name: name, history: history, inventory: key, settings: options)
                if quality == nil {
                    guard reserve(CandidateProbe.reservationBytes) else { return }
                    let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: start, settings: options, previous: nil, cancellation: token, expectedInventory: key) } }.value
                    guard version == revision, key == state.inventoryKey, inventoryStable else { return }
                    if case .success(let result) = result { update(result.measurement, key: key); quality = hard ? BackupPlanner.recoveryQuality(name: name, history: history, inventory: key, settings: options) : BackupPlanner.quality(name: name, history: history, inventory: key, settings: options) }
                    else if case .failure(let error) = result, error is ProbeInterrupted { return }
                }
                guard let quality = quality else { quarantined[name] = Date().addingTimeInterval(1800); continue }
                guard reserve(CandidateProbe.healthReservationBytes) else { return }
                let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: start, settings: options, previous: nil, cancellation: token, expectedInventory: key, kind: .health) } }.value
                guard version == revision, key == state.inventoryKey, inventoryStable, settings.autoSwitch else { return }
                guard case .success(let result) = result else { continue }
                let health = result.measurement; update(health, key: key)
                guard health.success else { quarantined[name] = Date().addingTimeInterval(1800); continue }
                _ = await commitManagedSwitch(old: old, quality: quality, health: health, options: options, key: key, reason: .failure, token: token, allowSlowRecovery: hard)
                return
            }
            if hard {
                issue("no-backup", "本轮最多复验 \(min(5, names.count)) 个候选（本次可检查 \(names.count) 个），暂未确认满足锁定 IP 的故障备用；保留当前选择并继续复验")
            } else {
                // Slow uploads must not starve the very maintenance that makes backups ready.
                badUploadCount = 0; lastSpeedStart = Date()
                event("info", "本轮未找到满足性能改善条件的备用；保留当前线路，继续健康维护，稍后重测上传")
            }
        }
    }
    private func commitManagedSwitch(old: String, quality: NodeMeasurement, health: NodeMeasurement, options: GuardSettings, key: String?, reason: ManagedSwitchReason, token: ProbeCancellation, allowSlowRecovery: Bool = false) async -> Bool {
        let name = health.name; let version = revision
        guard settings.autoSwitch, !paused, !enrolling, inventoryStable, state.inventoryKey == key else { return false }
        guard !allowSlowRecovery || reason == .failure else { return false }
        var journal = state.switchingJournal ?? SwitchingJournal()
        if let blocked = journal.block(reason: reason, candidate: name, inventory: key) { optimalStatus = blocked; return false }
        if reason == .optimization {
            guard settings.preferBestNode, workloadAllowsTests, switchQuiet else { return false }
            let decision = bestTracker.evaluate(current: old, eligible: optimizationEligible, history: history, inventory: key, settings: settings, journal: journal, idle: true, stableSince: networkStableSince)
            guard decision.candidate == name else { optimalStatus = decision.message; return false }
        }
        let item = ManagedSwitch(from: old, to: name, inventory: key, reason: reason)
        journal.append(item); state.switchingJournal = journal; save(); writer.flush(state)
        ownedTransition = (old, name, Date().addingTimeInterval(90))
        var committed = false
        do {
            try await Task.detached(priority: .utility) {
                let client = MihomoClient(); let fresh = try client.snapshot()
                guard try InventoryReader().read(snapshot: fresh, settings: options).key == key else { throw ProbeInterrupted("订阅已变，禁止提交旧节点") }
                guard FailoverPolicy.mayCommit(settings: options, snapshot: fresh, old: old, quality: quality, health: health, allowSlowRecovery: allowSlowRecovery) else { throw GuardError.unavailable("备用证据或切换条件已改变，取消切换") }
                try client.select(group: options.frontGroup, node: name, expectedCurrent: old, cancellation: token)
            }.value
            committed = true
            let verified = try await Task.detached(priority: .utility) { () -> ExitObservation in
                let now = try MihomoClient().snapshot(); let port = now.config.mixedPort > 0 ? now.config.mixedPort : now.config.httpPort
                let exit = try Probe.exit(host: "claude.ai", port: port, auth: try Probe.localAuthentication(), verifyMainRoute: true)
                if let violation = ProtectionPolicy.exitViolation(exit, allowedIPs: options.allowedClaudeIPs) { throw ProbeFailure(kind: .route, detail: violation) }
                let after = try MihomoClient().snapshot()
                guard try InventoryReader().read(snapshot: after, settings: options).key == key else { throw ProbeInterrupted("订阅已变，不对新订阅进行旧路由复验") }
                guard after.config.mode == "rule", let route = ExitRoute.current(snapshot: after, settings: options), route.usesFront(options),
                      after.proxies[options.frontGroup]?.now == name, route.matches(exit) else { throw GuardError.unavailable("切换后主路由出口验证失败") }
                return exit
            }.value
            guard version == revision, key == state.inventoryKey, inventoryStable else { throw ProbeInterrupted("设置或订阅已变，不采用旧切换的复验结果") }
            state.switchingJournal?.finish(item.id, verified: true); save(); writer.flush(state)
            claudeExit = verified; claudeError = nil; claudeFailures = 0; badUploadCount = 0; lastSwitch = Date()
            if settings.strictProtection { strictMachine.verified(at: verified.date); syncProtection() }
            quarantined[old] = Date().addingTimeInterval(reason == .optimization ? 3600 : 1800)
            clear("no-backup"); clear("switch"); clear("switch-budget"); bestTracker.reset(); networkStableSince = Date()
            event("info", "\(reason == .optimization ? "已择优切换" : "已故障切换")前置：\(old) → \(name)，主路由锁定 IP 复验通过", notify: true); checkNow(); return true
        } catch {
            state.switchingJournal?.finish(item.id, verified: false); save(); writer.flush(state)
            if !committed { ownedTransition = nil }
            guard !(error is ProbeInterrupted), version == revision, key == state.inventoryKey, inventoryStable else { return false }
            quarantined[name] = Date().addingTimeInterval(1800)
            issue("switch", committed ? "自动切换后未形成有效出口证据，正在安全回退" : "自动切换提交失败，已暂停后续主动择优")
            if (error as? ProbeFailure)?.kind == .route { trip("切换后已确认出口偏离锁定 IP") }
            else if committed && settings.strictProtection { strictMachine.failed(.invalid); syncProtection() }
            if committed {
                let rollback = ManagedSwitch(from: name, to: old, inventory: key, reason: .rollback)
                state.switchingJournal?.append(rollback); save(); writer.flush(state); ownedTransition = (name, old, Date().addingTimeInterval(90))
                do {
                    try await Task.detached(priority: .utility) {
                        let client = MihomoClient(); let fresh = try client.snapshot()
                        guard try InventoryReader().read(snapshot: fresh, settings: options).key == key else { throw ProbeInterrupted("订阅已变，禁止回退旧节点") }
                        try client.select(group: options.frontGroup, node: old, expectedCurrent: name)
                    }.value
                    state.switchingJournal?.finish(rollback.id, verified: true)
                } catch { state.switchingJournal?.finish(rollback.id, verified: false); issue("switch", "自动回退未获确认，请检查当前选择") }
                save(); writer.flush(state)
            }
            checkNow(); return false
        }
    }
    private var optimizationEligible: [String] { (settings.automaticBackupPool ? availableNodes : settings.candidates.filter { availableNodes.contains($0) }).filter { quarantined[$0, default: .distantPast] <= Date() } }
    private func observeFrontSelection() {
        guard inventoryStable else { return }
        let name = currentFront; var journal = state.switchingJournal ?? SwitchingJournal()
        if journal.observedInventory != state.inventoryKey || journal.observedFront == nil {
            journal.observedInventory = state.inventoryKey; journal.observedFront = name; state.switchingJournal = journal
            networkStableSince = Date(); bestTracker.reset(); save(); return
        }
        guard let previous = journal.observedFront, previous != name else { return }
        let owned = ownedTransition.map { $0.from == previous && $0.to == name && $0.until > Date() } == true
        journal.observedFront = name
        if !owned {
            journal.manualHoldUntil = Date().addingTimeInterval(1800); revision += 1
            activeCancellation?.cancel("检测到手动选择，取消旧切换任务"); bestTracker.reset(); networkStableSince = Date()
            event("info", "检测到手动前置选择，暂停主动择优 30 分钟；故障恢复继续监控")
        }
        state.switchingJournal = journal; save()
    }
    private func considerBestNode() {
        guard !demo, !readOnly, !paused, !sleeping, !enrolling, connected, inventoryStable else { return }
        guard Date().timeIntervalSince(lastOptimalAssessment) >= 30 else { return }
        lastOptimalAssessment = Date()
        let journal = state.switchingJournal ?? SwitchingJournal()
        let decision = bestTracker.evaluate(current: currentFront, eligible: optimizationEligible, history: history, inventory: state.inventoryKey, settings: settings, journal: journal, idle: workloadAllowsTests && switchQuiet, stableSince: networkStableSince)
        if optimalStatus != decision.message { optimalStatus = decision.message }; if optimalCandidate != bestTracker.leader { optimalCandidate = bestTracker.leader }
        guard settings.autoSwitch, settings.preferBestNode, !testing, workloadAllowsTests, claudeFailures < 2, badUploadCount < 2 else { return }
        if let until = state.performanceRetryAt, until > Date() { optimalStatus = "共享依赖异常待复验，主动择优暂缓"; return }
        if let name = decision.candidate { runOptimalSwitch(name); return }
        guard Date().timeIntervalSince(lastOptimalProbe) >= 120,
              journal.block(reason: .optimization, candidate: nil, inventory: state.inventoryKey) == nil,
              let name = OptimizationProbePlanner.next(current: currentFront, eligible: optimizationEligible, history: history, inventory: state.inventoryKey, settings: settings) else { return }
        runOptimalProbe(name)
    }
    private func runOptimalProbe(_ name: String) {
        guard let current = snapshot, let key = state.inventoryKey, reserve(CandidateProbe.reservationBytes) else { return }
        lastOptimalProbe = Date(); testing = true; purpose = "optimization-probe"; testingNode = name
        let token = ProbeCancellation(); activeCancellation = token; let options = settings; let version = revision
        Task {
            let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: current, settings: options, previous: nil, cancellation: token, expectedInventory: key, kind: .full) } }.value
            testing = false; purpose = ""; testingNode = ""; activeCancellation = nil
            guard !paused, version == revision, key == state.inventoryKey, inventoryStable else { return }
            if case .success(let result) = result {
                update(result.measurement, key: key)
                if name == currentFront {
                    lastSpeedStart = Date()
                    if let poor = UploadRecoveryEvidence.poor(result.measurement, maxUpload: settings.slowUploadSeconds) { badUploadCount = poor ? badUploadCount + 1 : 0 }
                    if badUploadCount >= 2 { recover(hard: false) }
                }
            }
            refreshScanStatus()
        }
    }
    private func runOptimalSwitch(_ name: String) {
        guard let current = snapshot, let key = state.inventoryKey,
              let quality = BackupPlanner.quality(name: name, history: history, inventory: key, settings: settings), reserve(CandidateProbe.healthReservationBytes) else { return }
        testing = true; purpose = "optimization-switch"; testingNode = name
        let old = currentFront; var approved = settings; approved.candidates = Array(Set(approved.candidates + [name])); let options = approved
        let version = revision; let token = ProbeCancellation(); activeCancellation = token
        Task {
            defer { testing = false; purpose = ""; testingNode = ""; activeCancellation = nil; refreshScanStatus() }
            let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: current, settings: options, previous: nil, cancellation: token, expectedInventory: key, kind: .health) } }.value
            guard version == revision, key == state.inventoryKey, !paused, settings.autoSwitch, settings.preferBestNode else { return }
            guard case .success(let result) = result, result.measurement.success else { quarantined[name] = Date().addingTimeInterval(1800); bestTracker.reset(); optimalStatus = "候选即时健康复验未通过，保持当前节点"; return }
            update(result.measurement, key: key)
            _ = await commitManagedSwitch(old: old, quality: quality, health: result.measurement, options: options, key: key, reason: .optimization, token: token)
        }
    }
    private func reserve(_ bytes: Int) -> Bool {
        let day = StateStore.dayKey()
        if state.budgetDay != day { state.budgetDay = day; state.testBytes = 0 }
        guard settings.dailyTestBudgetMB == 0 || state.testBytes + bytes <= settings.dailyTestBudgetMB * 1_000_000 else { issue("budget", "今日测速流量预算已用完；出口监控继续，自动切换因无法验证备用而暂停"); return false }
        clear("budget"); state.testBytes += bytes; save(); return true
    }
    private func update(_ value: NodeMeasurement, key: String? = nil) {
        var copy = value; copy.inventoryKey = key ?? state.inventoryKey
        state.history = MeasurementHistory.append(copy, to: history); summaryCache.removeValue(forKey: copy.name)
        if copy.kind == .health {
            var checks = state.healthChecks ?? []; checks.removeAll { $0.name == copy.name && $0.inventoryKey == copy.inventoryKey }; checks.append(copy); state.healthChecks = Array(checks.suffix(2000))
        } else if copy.kind != .stream {
            let stats = summary(copy.name); copy.samples = stats.total; copy.reliability = stats.ratio ?? 0
            state.measurements.removeAll { $0.name == copy.name && $0.inventoryKey == copy.inventoryKey }; state.measurements.append(copy)
        }
        if let common = SharedFailureDetector.assess(history, inventory: state.inventoryKey) {
            sharedDiagnosis = common.title; issue("shared", common.title)
            if copy.kind != .health && copy.performanceDeferred != true && common.defersPerformance && state.performanceRetryAt.map({ $0 > Date() }) != true { state.performanceRetryAt = Date().addingTimeInterval(300) }
        } else { sharedDiagnosis = nil; clear("shared") }
        refreshDerived(force: true); save()
    }
    private func maintainBackups() {
        guard !demo, !readOnly, !paused, !enrolling, !testing, inventoryStable, workloadAllowsTests, let current = snapshot, let key = state.inventoryKey else { return }
        if settings.autoSwitch && claudeFailures >= 2 { return }
        let names = backupPool
        let last: (String) -> Date = { name in (self.state.healthChecks ?? []).filter { $0.name == name && $0.inventoryKey == key }.map(\.date).max() ?? .distantPast }
        guard let name = names.sorted(by: { last($0) < last($1) }).first, Date().timeIntervalSince(last(name)) >= settings.backupHealthInterval else { return }
        let quality = BackupPlanner.recoveryQuality(name: name, history: history, inventory: key, settings: settings)
        let needsFull = quality.map { Date().timeIntervalSince($0.date) > 3600 } ?? false
        let cooled = state.performanceRetryAt.map { $0 > Date() } == true
        let healthExpired = Date().timeIntervalSince(last(name)) >= settings.backupHealthInterval * 2
        let kind: MeasurementKind = needsFull && !cooled && !healthExpired ? .full : .health
        guard reserve(kind == .full ? CandidateProbe.reservationBytes : CandidateProbe.healthReservationBytes) else { return }
        testing = true; purpose = "backup"; testingNode = name
        let token = ProbeCancellation(); activeCancellation = token; let version = revision; let options = settings
        Task {
            let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: current, settings: options, previous: nil, cancellation: token, expectedInventory: key, kind: kind) } }.value
            testing = false; purpose = ""; testingNode = ""; activeCancellation = nil
            guard !paused, version == revision, key == state.inventoryKey, inventoryStable else { return }
            switch result { case .success(let result):
                update(result.measurement, key: key)
                if kind == .full {
                    var health = result.measurement; health.kind = .health; health.success = health.passed(.residential) && health.passed(.claude)
                    health.uploadSeconds = 0; health.downloadMbps = 0; health.diagnostics = health.stages.filter { [.front, .residential, .claude, .gpt].contains($0.stage) }
                    health.date = health.stages.map(\.date).max() ?? health.date; update(health, key: key)
                }
            case .failure(let error): if !(error is ProbeInterrupted) { var m = NodeMeasurement.failed(name, previous: nil, reason: error.localizedDescription); m.kind = .health; update(m, key: key) } }
            refreshScanStatus(); advanceScan()
        }
    }
    func runStreamCheck(_ name: String) {
        guard canScheduleScan, !readOnly, !demo, availableNodes.contains(name), let current = snapshot, let key = state.inventoryKey, workloadAllowsTests, reserve(CandidateProbe.healthReservationBytes) else { showError("请等待网络低负载且当前检测结束，再执行 30 秒流式检查。"); return }
        testing = true; purpose = "stream"; testingNode = name
        let token = ProbeCancellation(); activeCancellation = token; let options = settings; let version = revision
        Task {
            let result = await Task.detached(priority: .utility) { Result { try CandidateProbe.measure(candidate: name, snapshot: current, settings: options, previous: nil, cancellation: token, expectedInventory: key, kind: .stream) } }.value
            testing = false; purpose = ""; testingNode = ""; activeCancellation = nil
            guard version == revision, key == state.inventoryKey, !paused else { return }
            if case .success(let result) = result { update(result.measurement, key: key); event(result.measurement.success ? "info" : "warning", "30 秒流式检查：" + result.measurement.outcomeTitle) }
            refreshScanStatus()
        }
    }
    private func trip(_ reason: String) {
        guard settings.strictProtection, !demo, !readOnly, !killBusy else { return }
        _ = strictMachine.violation(reason); syncProtection(); issue("protection", "严格保护：\(reason)", level: "critical")
        guard Date().timeIntervalSince(lastKill) > 1.5 else { return }
        lastKill = Date(); killBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { ProcessGuard.terminateClaude() }.value
            killBusy = false
            if result.ended > 0 { event("critical", "严格保护已强制结束 \(result.ended) 个 Claude 进程：\(reason)", notify: true) }
            if result.failed > 0 { event("critical", "有 \(result.failed) 个 Claude 进程无法结束，请立即人工退出", notify: true) }
        }
    }
    private func issue(_ key: String, _ message: String, level: String = "warning", since: Date? = nil, observations: Int = 1) {
        issues[key] = message
        var records = state.incidents ?? []; let change = IncidentLedger.raise(&records, key: key, level: level, message: message, inventory: inventoryStable ? state.inventoryKey : nil, front: currentFront, since: since, observations: observations); state.incidents = records
        if change != .updated { event(level, message, notify: true) } else { save() }
    }
    private func clear(_ key: String) {
        issues.removeValue(forKey: key)
        var records = state.incidents ?? []
        if let resolved = IncidentLedger.resolve(&records, key: key) {
            state.incidents = records
            let duration = max(0, Int(Date().timeIntervalSince(resolved.firstSeen)))
            if key == "claude-network" || key == "gpt-network" {
                event("info", "出口复验通过：\(resolved.message)（告警到复验 \(duration) 秒，\(resolved.count) 次失败探测）", notify: true)
            } else { event("info", "已恢复：\(resolved.message)（持续 \(duration) 秒，\(resolved.count) 次观察）", notify: true) }
        }
    }
    private func event(_ level: String, _ message: String, notify: Bool = false) {
        state.events.insert(GuardEvent(level: level, message: message), at: 0); state.events = Array(state.events.prefix(200)); save(); onStatusChange?()
        guard notify, !demo, !readOnly else { return }
        NSSound.beep()
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent(); content.title = "节点哨兵 · \(message.hasPrefix("出口复验通过：") ? "出口复验通过" : (level == "info" ? "状态已恢复" : "网络告警"))"; content.body = message; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    private func confirm(_ alert: NSAlert) async -> Bool {
        guard let window = hostWindow, window.attachedSheet == nil else { return false }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in alert.beginSheetModal(for: window) { response in continuation.resume(returning: response == .alertFirstButtonReturn) } }
    }
    private func showError(_ message: String) {
        activity = message
        guard let window = hostWindow, window.attachedSheet == nil else { return }
        let alert = NSAlert(); alert.messageText = "节点哨兵"; alert.informativeText = message; alert.beginSheetModal(for: window)
    }
    private func makeDemo() {
        let fixture: [String: Any] = ["proxies": [
            "KTM前置节点": ["name": "KTM前置节点", "type": "Selector", "now": "台湾 · 01", "all": ["台湾 · 01", "香港 · 01", "日本 · 01"]],
            "Claude专线": ["name": "Claude专线", "type": "Selector", "now": "示例出口代理"],
            "ChatGPT": ["name": "ChatGPT", "type": "Selector", "now": "示例出口代理"],
            "示例出口代理": ["name": "示例出口代理", "type": "Socks5", "dialer-proxy": "KTM前置节点"]]]
        if let data = try? JSONSerialization.data(withJSONObject: fixture), let p = try? JSONDecoder().decode(ProxyEnvelope.self, from: data), let c = try? JSONDecoder().decode(CoreConfig.self, from: Data("{\"mode\":\"rule\",\"mixed-port\":7897,\"port\":0,\"socks-port\":0}".utf8)) { snapshot = CoreSnapshot(proxies: p.proxies, connections: [], config: c) }
        connected = true; activity = "演示模式 · 使用示例数据，所有操作均禁用"
        claudeExit = ExitObservation(ip: "203.0.113.8", country: "US", seconds: 0.64); gptExit = claudeExit
        state.settings.candidates = availableNodes
        state.measurements = [NodeMeasurement(name: "台湾 · 01", date: Date(), success: true, latencyMS: 640, uploadSeconds: 3.9, downloadMbps: 19.6, reliability: 0.98, samples: 12, failure: nil, ip: nil, country: "US"), NodeMeasurement(name: "香港 · 01", date: Date(), success: true, latencyMS: 720, uploadSeconds: 5.1, downloadMbps: 16.2, reliability: 0.96, samples: 8, failure: nil, ip: nil, country: "US"), .failed("日本 · 01", previous: nil, reason: "上传超时")]
        state.events = [GuardEvent(level: "info", message: "示例：备用节点验证通过，锁定的出口 IP 保持一致"), GuardEvent(level: "warning", message: "示例：日本线路上传超时，已进入冷却")]
    }
}
