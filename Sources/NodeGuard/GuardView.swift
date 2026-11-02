import SwiftUI
import NodeGuardCore

private struct NodeSelection: Identifiable { let name: String; var id: String { name } }

struct GuardView: View {
    @ObservedObject var model: MonitorModel
    @State private var page = 0
    @State private var search = ""
    @State private var selectedNode: NodeSelection?
    private let accent = Color(red: 0.13, green: 0.43, blue: 0.84)
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 218)
            Divider()
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.hasIncident {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(model.alertMessage).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        Button("查看告警") { page = 3 }
                    }.padding(14).background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                if page == 0 { overview }
                else if page == 1 { ranking }
                else if page == 2 { settings }
                else { events }
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(minWidth: 1080, minHeight: 740)
            .background(Color(nsColor: .windowBackgroundColor))
            .sheet(item: $selectedNode) { selected in NodeDetailView(model: model, name: selected.name) }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 31)).foregroundStyle(accent)
                Text("节点哨兵").font(.system(size: 23, weight: .bold))
                Text("NODEGUARD  /  macOS").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }.padding(.top, 16)
            VStack(spacing: 6) {
                nav("监控总览", icon: "square.grid.2x2", tag: 0)
                nav("前置节点排名", icon: "chart.bar.xaxis", tag: 1)
                nav("保护与自动切换", icon: "shield.lefthalf.filled", tag: 2)
                nav("告警与事件", icon: "bell", tag: 3)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label(model.statusTitle, systemImage: model.hasIncident ? "exclamationmark.circle.fill" : "circle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(model.hasIncident ? .orange : .teal)
                Text("Clash Verge 关联\n\(model.connected ? "控制接口已连接" : "等待 Clash 启动")").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
                Text("v0.4.2 · Apple Silicon").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(.bottom, 12)
        }.padding(22).background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }
    private func nav(_ title: String, icon: String, tag: Int) -> some View {
        Button { page = tag } label: {
            HStack(spacing: 11) { Image(systemName: icon).frame(width: 20); Text(title); Spacer() }
                .font(.system(size: 13, weight: page == tag ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 12)
                .foregroundStyle(page == tag ? accent : .primary)
                .background(page == tag ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(["监控总览", "前置节点排名", "保护与自动切换", "告警与事件"][page]).font(.system(size: 27, weight: .bold))
                Text(model.activity).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if model.demo || model.readOnly { badge(model.demo ? "演示 · 示例数据" : "只读验收", color: .orange) }
            Button { model.checkNow() } label: { Label("立即检查", systemImage: "arrow.clockwise") }.disabled(model.demo)
        }
    }
    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MonitorReadinessView(model: model)
                HStack(alignment: .top, spacing: 16) {
                    exitCard("Claude", subtitle: model.settings.allowedClaudeIPs.isEmpty ? "出口 IP 监控" : "已锁定出口 IP", observation: model.claudeExit, error: model.claudeError, color: Color(red: 0.71, green: 0.38, blue: 0.23), route: model.snapshot?.routeSummary(model.settings.claudeGroup) ?? "等待验证")
                    exitCard("GPT", subtitle: "独立出口监控", observation: model.gptExit, error: model.gptError, color: accent, route: model.observedRoute(model.gptExit, fallback: model.settings.gptGroup))
                }
                panel {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack { Label("当前前置线路", systemImage: "network").font(.headline); Spacer(); badge(model.connected ? "已关联" : "未连接", color: model.connected ? .teal : .orange) }
                        Text(model.currentFront).font(.system(size: 22, weight: .semibold))
                        Text("前置切换仅作用于 \(model.settings.frontGroup)。候选需保持锁定的出口 IP。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Divider()
                        HStack(spacing: 30) {
                            metric("自动切换", model.settings.autoSwitch ? "已开启" : "未开启")
                            metric("Claude 严格保护", model.protectionPhase.title)
                            metric("备用池", "\(model.readyBackups.count) 就绪 / \(model.backupPool.count) 候选")
                            metric("今日测速估算上限", String(format: "%.1f MB", model.dailyMB) + (model.settings.dailyTestBudgetMB == 0 ? " · 不限量" : ""))
                        }
                    }
                }
                scanPanel
                if model.settings.allowedClaudeIPs.isEmpty {
                    panel {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "pin.circle").font(.title2).foregroundStyle(accent)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("先确认当前出口 IP，再开启自动保护").font(.headline)
                                Text("两次核对真实代理链和出口 IP。锁定后，地址变化不会被自动接受。")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(model.enrolling ? "正在核对…" : "锁定当前出口 IP") { model.enrollCurrentExit() }
                                .disabled(model.enrolling || !model.connected || model.demo || model.readOnly)
                        }
                    }
                }
                recentEvents
                Text("路由与连接每 2 秒检查；出口常规每 15 秒，严格保护每 5 秒发起验证，单次超时 8 秒。确认为出口变化立即处理，不可验证时按设置的复验时限处理。此处是最近一次探测结果，不能保证零泄漏。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(.bottom, 10)
        }
    }
    private func exitCard(_ name: String, subtitle: String, observation: ExitObservation?, error: String?, color: Color, route: String) -> some View {
        let warning = cardWarning(name, observation: observation, error: error)
        return panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(name).font(.system(size: 20, weight: .bold)).foregroundStyle(color); Spacer(); badge(warning != nil ? "需要处理" : (observation == nil ? "等待验证" : "最近已验证"), color: warning != nil ? .orange : .teal) }
                VStack(alignment: .leading, spacing: 7) {
                    Text(observation?.ip ?? "—").font(.system(size: 23, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                    Text("\(observation?.country ?? "待确认")  ·  \(subtitle)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                Text(route).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3).frame(minHeight: 34, alignment: .topLeading)
                if let warning = warning { Text(warning).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3) }
                if let observation = observation { Text("最近检查 \(observation.date.formatted(date: .omitted, time: .standard))").font(.system(size: 10)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func cardWarning(_ name: String, observation: ExitObservation?, error: String?) -> String? {
        if let error = error { return error }
        if !model.connected { return "Clash 未连接，当前出口无法确认" }
        guard let value = observation else { return nil }
        if value.country == "CN" { return "出口位于中国大陆" }
        let limit = name == "Claude" && model.settings.strictProtection ? 12.0 : 25.0
        if !model.demo && Date().timeIntervalSince(value.date) > limit { return "出口结果已过期，当前状态无法确认" }
        if name == "Claude", !model.settings.allowedClaudeIPs.isEmpty, !model.settings.allowedClaudeIPs.contains(value.ip) { return "出口偏离已锁定的出口 IP" }
        return nil
    }
    private var ranking: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                TextField("搜索当前订阅的前置节点", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 330)
                Spacer()
                Text("就绪 \(model.readyBackups.count) · 候选 \(model.backupPool.count)").font(.system(size: 12)).foregroundStyle(.secondary)
                Button { model.runRanking() } label: { Label("立即安排全量测试", systemImage: "speedometer") }.disabled(!model.canScheduleScan || model.demo || model.readOnly)
            }
            scanPanel
            Text("空闲时串行测试当前订阅的全部前置节点。分开记录前置、出口、Claude/GPT、小包上传和完整性能；支持备用测速端点。勾选可补充手动备用。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            HStack { Text("候选 / 前置节点").frame(maxWidth: .infinity, alignment: .leading); Text("综合").frame(width: 48); Text("上传 1 MB").frame(width: 88); Text("下载").frame(width: 85); Text("成功 / 样本").frame(width: 88); Text("证据").frame(width: 42) }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 14)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(model.orderedNodes.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { name in nodeRow(name) }
                }
            }
            Text("评分包含已通过的阶段；部分通过不代表可切换。成功率取最近 24 小时最多 20 次完整测速，备用还需近期健康和精确出口 IP 复验。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func nodeRow(_ name: String) -> some View {
        let m = model.measurement(name); let summary = model.summary(name)
        return HStack(spacing: 12) {
            Toggle("将\(name)加入手动备用", isOn: Binding(get: { model.settings.candidates.contains(name) }, set: { model.setCandidate(name, enabled: $0) })).labelsHidden()
                .accessibilityLabel("将\(name)加入手动备用").disabled(model.demo || model.readOnly)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(name).font(.system(size: 12, weight: .medium)); if name == model.currentFront { badge("当前", color: accent) }; if model.readyBackups.contains(name) { badge("备用就绪", color: .teal) } else if model.backupPool.contains(name) { badge("候选", color: .orange) } }
                if let m = m {
                    HStack(spacing: 8) { stageLabel("前置", .front, m); stageLabel("出口", .residential, m); stageLabel("Claude", .claude, m); stageLabel("GPT", .gpt, m); stageLabel("上传", .upload, m); stageLabel("下载", .download, m) }
                    Text(m.failure ?? m.outcomeTitle).font(.system(size: 10)).foregroundStyle(m.success ? Color.secondary : Color.orange).lineLimit(1)
                } else { Text("尚未测试").font(.caption).foregroundStyle(.secondary) }
                if let last = summary.lastSuccess { Text("最近完整通过 \(last.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(model.backupStatus(name)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(m.map { String(format: "%.0f", $0.score) } ?? "—").font(.system(size: 18, weight: .semibold, design: .rounded)).frame(width: 48)
            Text(m.flatMap { $0.uploadSeconds > 0 ? String(format: "%.2f s", $0.uploadSeconds) : nil } ?? "—").frame(width: 88)
            Text(m.flatMap { $0.downloadMbps > 0 ? String(format: "%.1f Mbps", $0.downloadMbps) : nil } ?? "—").frame(width: 85)
            VStack(spacing: 4) { Text(summary.ratio.map { String(format: "%.0f%%", $0 * 100) } ?? "—"); Text("\(summary.successes) / \(summary.total)").font(.system(size: 10)).foregroundStyle(.secondary) }.frame(width: 88)
            Button("详情") { selectedNode = NodeSelection(name: name) }.font(.system(size: 11)).frame(width: 42).accessibilityLabel("查看\(name)的分层证据和历史")
        }.font(.system(size: 11)).padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func stageLabel(_ name: String, _ stage: DiagnosticStage, _ measurement: NodeMeasurement) -> some View {
        let known = measurement.stages.contains { $0.stage == stage && $0.status != .deferred }
        let passed = measurement.passed(stage)
        return Label(name, systemImage: passed ? "checkmark.circle.fill" : (known ? "exclamationmark.circle" : "minus.circle"))
            .font(.system(size: 9)).foregroundStyle(passed ? Color.teal : (known ? Color.orange : Color.secondary))
            .accessibilityLabel("\(name)：\(passed ? "通过" : (known ? "未通过" : "待确认"))")
    }
    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                panel {
                    VStack(alignment: .leading, spacing: 15) {
                        Label("Claude 出口保护", systemImage: "shield.lefthalf.filled").font(.headline)
                        LabeledContent("锁定 IP", value: model.settings.allowedClaudeIPs.joined(separator: ", ").isEmpty ? "尚未锁定" : model.settings.allowedClaudeIPs.joined(separator: ", "))
                        Toggle("启用严格保护：出口 IP 改变、回到国内或路由绕行时强制结束 Claude", isOn: Binding(get: { model.settings.strictProtection }, set: { model.toggleStrict($0) }))
                        Text("仅核对 Claude 服务域名的出口；内置浏览器访问第三方网站不因普通分流强退。Claude Code 和终端不纳入。确认 IP 改变或路由绕行立即退出；出口仅仅不通时保留 Claude 并更换前置重试；Clash 控制接口不可用时按下方时限复验后退出。锁定 IP 不自动更新。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("状态：\(model.protectionPhase.title) · \(model.protectionReason)").foregroundStyle(model.protectionPhase == .armed ? Color.teal : Color.orange).font(.system(size: 11))
                        Picker("无法核对路由时", selection: Binding(get: { model.settings.unverifiedGrace }, set: { value in model.changeSettings { $0.unverifiedGrace = value } })) {
                            Text("立即退出（最严格）").tag(0.0); Text("复验最多 12 秒后退出").tag(12.0); Text("复验最多 20 秒后退出").tag(20.0)
                        }.disabled(model.settings.strictProtection)
                        Button(model.enrolling ? "正在核对…" : "重新锁定当前出口 IP") { model.enrollCurrentExit() }.disabled(model.enrolling || model.settings.strictProtection)
                    }
                }
                panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("前置节点自动管理", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                        Toggle("启用自动切换与故障恢复", isOn: Binding(get: { model.settings.autoSwitch }, set: { model.toggleAuto($0) }))
                        Text("Claude 出口连续失败 2 次后尝试恢复；优先复验近期健康的备用。断线时允许较慢但完整测试与锁定 IP 合格的节点救援；主动择优仍要求明显更优。切换后复验主路由，失败回退，故障候选冷却 30 分钟。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Toggle("健康时自动择优：只切换到明显更优的节点", isOn: Binding(get: { model.settings.preferBestNode }, set: { value in model.changeSettings { $0.preferBestNode = value } }))
                        Text("\(model.optimalStatus)" + (model.optimalCandidate.map { " · 候选 " + $0 } ?? "")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        Text("择优需同端点两次完整测速，间隔至少 1 分钟；领先至少 10 分且 20%，优势保持 3 分钟。低负载并等待 AI 传输安静 20 秒后再复验切换。切换后冷却 30 分钟，每小时最多 2 次择优；累计 4 次自动操作后停止新切换，必要回退优先执行并计数。离开的节点 60 分钟内不主动切回。手动选择后暂停择优 30 分钟。")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Toggle("自动维护当前订阅的已验证备用池", isOn: Binding(get: { model.settings.automaticBackupPool }, set: { value in model.changeSettings { $0.automaticBackupPool = value } }))
                        Stepper("备用池最多 \(model.settings.backupPoolSize) 个候选", value: Binding(get: { model.settings.backupPoolSize }, set: { value in model.changeSettings { $0.backupPoolSize = value } }), in: 3...5)
                        Picker("备用健康复验间隔", selection: Binding(get: { model.settings.backupHealthInterval }, set: { value in model.changeSettings { $0.backupHealthInterval = value } })) { Text("3 分钟").tag(180.0); Text("5 分钟").tag(300.0); Text("10 分钟").tag(600.0); Text("30 分钟").tag(1800.0) }
                        Text("当前 \(model.readyBackups.count) 个就绪，\(model.backupPool.count) 个候选。优先分散地区，手动名单可补充；开启备用维护不会自动开启节点切换。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("退出程序会停止监控和自动化；保护开关、锁定 IP 和未完成队列会保留。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                panel {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("空闲时自动测试全部前置节点", systemImage: "clock.arrow.2.circlepath").font(.headline)
                        Toggle("启用周期全量测试", isOn: Binding(get: { model.settings.automaticFullScan }, set: { model.setAutomaticScan($0) }))
                        Picker("一轮完成后的间隔", selection: Binding(get: { model.settings.fullScanInterval }, set: { value in model.changeSettings { $0.fullScanInterval = value } })) {
                            Text("30 分钟").tag(1800.0); Text("1 小时").tag(3600.0); Text("3 小时").tag(10800.0); Text("6 小时").tag(21600.0); Text("12 小时").tag(43200.0); Text("24 小时").tag(86400.0)
                        }
                        Picker("测速避让", selection: Binding(get: { model.settings.testingSensitivity }, set: { value in model.changeSettings { $0.testingSensitivity = value } })) {
                            ForEach(TestingSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Stepper("低负载稳定 \(Int(model.settings.idleSeconds)) 秒后测试", value: Binding(get: { model.settings.idleSeconds }, set: { value in model.changeSettings { $0.idleSeconds = value } }), in: 5...300, step: 5)
                        Text("忽略后台心跳、新建空连接和零星请求。持续大流量才让行，短暂波动不重置等待。不限测速流量；切换订阅自动刷新队列，排名按订阅隔离。睡眠和换网后重新验证出口，再续测未完成节点。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                panel {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("告警与运行", systemImage: "bell.badge").font(.headline)
                        HStack { Text(model.notificationsAllowed ? "系统通知已允许" : "系统通知未允许；应用内事件和提示音仍可用"); Spacer(); Button("允许系统通知") { model.enableNotifications() } }
                        HStack { Button(model.notificationTestBusy ? "3 秒后发送，正在验证…" : "发送测试通知") { model.testNotification() }.disabled(!model.notificationsAllowed || model.notificationTestBusy); Text(model.notificationTestStatus).font(.system(size: 11)).foregroundStyle(.secondary) }
                        Button("导出脱敏诊断") { model.exportDiagnostics() }
                        Text("诊断仅保留错误分类、计时、版本和匿名节点标识；不含密钥、订阅 URL、IP 地址、原始配置或会话内容。").font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack { Text("关闭窗口后继续在菜单栏运行"); Spacer(); Button(model.paused ? "恢复监控" : "暂停监控") { model.setPaused(!model.paused) } }
                        Toggle("随 macOS 登录启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                    }
                }
            }.font(.system(size: 12)).disabled(model.demo || model.readOnly)
        }
    }
    private var scanPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack { Label(model.subscriptionName, systemImage: "rectangle.2.swap").font(.system(size: 12, weight: .semibold)); Spacer(); Text(model.scanProgress).font(.system(size: 12, design: .monospaced)) }
                ProgressView(value: model.scanFraction).tint(accent)
                HStack { Text(model.scanStatus); Spacer(); Text(model.networkRate) }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private var events: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                IncidentListView(model: model)
                Text("事件时间线").font(.headline).padding(.top, 18)
                if model.state.events.isEmpty { Text("暂无告警。检测结果与重要状态变化会保留在这里。").foregroundStyle(.secondary).padding(.vertical, 30) }
                ForEach(model.state.events) { e in eventRow(e); Divider().padding(.vertical, 12) }
            }
        }
    }
    private var recentEvents: some View {
        panel {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Text("最近事件").font(.headline); Spacer(); Button("查看全部") { page = 3 }.buttonStyle(.link) }
                if model.state.events.isEmpty { Text("暂未发现异常").font(.system(size: 12)).foregroundStyle(.secondary) }
                ForEach(Array(model.state.events.prefix(3))) { eventRow($0) }
            }
        }
    }
    private func eventRow(_ e: GuardEvent) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: e.level == "info" ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(e.level == "info" ? .teal : .orange)
            Text(e.message).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
    private func metric(_ title: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 12, weight: .medium)) } }
    private func badge(_ text: String, color: Color) -> some View { Text(text).font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 5).foregroundStyle(color).background(color.opacity(0.09), in: Capsule()) }
    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View { content().padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.055), lineWidth: 1)) }
}
