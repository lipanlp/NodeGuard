import SwiftUI
import Charts
import NodeGuardCore

struct MonitorReadinessView: View {
    @ObservedObject var model: MonitorModel
    private var exitsFresh: Bool {
        guard model.connected, model.claudeError == nil, model.gptError == nil, let c = model.claudeExit, let g = model.gptExit else { return false }
        return model.demo || [c.date, g.date].allSatisfy { let age = Date().timeIntervalSince($0); return age >= 0 && age < 25 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 20) {
                state("控制接口", model.connected ? "已连接" : "断开", ok: model.connected)
                state("出口", exitsFresh ? "最近验证通过" : "等待复验", ok: exitsFresh)
                state("保护", model.protectionPhase.title, ok: model.protectionPhase == .armed)
                state("备用", "\(model.readyBackups.count) 就绪 / \(model.backupPool.count) 候选", ok: !model.readyBackups.isEmpty)
                state("通知", model.notificationsAllowed ? "已允许" : "未允许", ok: model.notificationsAllowed)
            }
            if !model.persistenceHealthy { Label("状态保存失败，退出后可能无法续测，请检查磁盘空间和目录权限", systemImage: "externaldrive.badge.exclamationmark").foregroundStyle(.red) }
            if !model.settings.strictProtection || !model.settings.autoSwitch || !model.notificationsAllowed {
                Text("当前：\(model.settings.strictProtection ? "严格保护已开启" : "严格保护未武装") · \(model.settings.autoSwitch ? "自动切换已开启" : "自动切换未开启") · \(model.networkStatus)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            if model.settings.autoSwitch {
                Text("自动择优：" + model.optimalStatus + (model.optimalCandidate.map { " · " + $0 } ?? "")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let preview = model.notificationLocalPreview {
                HStack(alignment: .top) { Label(preview, systemImage: "bell.badge").font(.system(size: 12)); Spacer(); Button("关闭反馈") { model.notificationLocalPreview = nil }.font(.caption) }
                    .padding(10).background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            if let diagnosis = model.sharedDiagnosis { Label(diagnosis, systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("检查出口") { model.checkNow() }
                Button(model.notificationTestBusy ? "测试发送中…" : "通知自检") { model.testNotification() }.disabled(!model.notificationsAllowed || model.readOnly || model.demo || model.notificationTestBusy)
                Button("系统通知设置") { model.openNotificationSettings() }
                Button("导出脱敏诊断") { model.exportDiagnostics() }
                Spacer()
                if !model.notificationsAllowed { Button("允许系统通知") { model.enableNotifications() }.disabled(model.readOnly || model.demo) }
            }.font(.system(size: 11))
            if model.notificationTestStatus != "尚未发送测试通知" { Text(model.notificationTestStatus).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.padding(16).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
    private func state(_ title: String, _ value: String, ok: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 10)).foregroundStyle(.secondary); Label(value, systemImage: ok ? "checkmark.circle.fill" : "circle.dashed").font(.system(size: 11, weight: .semibold)).foregroundStyle(ok ? Color.teal : Color.orange) }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NodeDetailView: View {
    @ObservedObject var model: MonitorModel
    let name: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { VStack(alignment: .leading, spacing: 5) { Text(name).font(.title2.bold()); Text("最近 24 小时 · 当前订阅的独立样本").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("备用资格：" + model.backupStatus(name)).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    statistics
                    historyChart
                    Button("执行 30 秒流式连接专项检查") { model.runStreamCheck(name) }.disabled(model.testing || model.readOnly || model.demo)
                    Text("流式检查验证这条代理链到测试端点的持续响应，不代表 Claude/GPT 已登录会话或 WebSocket 必然稳定。随机测速数据不包含会话内容。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let latest = model.recentHistory(name).last {
                        Text("最近一轮分层证据").font(.headline)
                        if latest.stages.isEmpty { Text("旧版本未保存分层证据，等待本版复测后显示。").font(.caption).foregroundStyle(.secondary) }
                        ForEach(latest.stages) { stage in stageRow(stage) }
                    }
                    Text("历史记录").font(.headline)
                    ForEach(Array(model.recentHistory(name).reversed().prefix(20).enumerated()), id: \.offset) { _, r in
                        DisclosureGroup {
                            if r.stages.isEmpty { Text("旧版本未保存该样本的分层证据").font(.caption).foregroundStyle(.secondary) }
                            ForEach(r.stages) { stage in stageRow(stage) }
                        } label: {
                            HStack(alignment: .top) { Text(r.date.formatted(date: .abbreviated, time: .standard)).font(.caption.monospacedDigit()); Spacer(); Text(r.kind == .health ? "健康复验" : (r.kind == .stream ? "流式检查" : "性能检测")).font(.caption); Text(r.outcomeTitle).font(.caption).foregroundStyle(r.success ? Color.teal : Color.orange) }
                        }
                        Divider()
                    }
                }
            }
        }.padding(24).frame(width: 770, height: 660)
    }
    private var statistics: some View {
        let s = model.summary(name)
        return HStack(spacing: 24) {
            statistic("完整测速成功", "\(s.successes) / \(s.total)")
            statistic("P50", s.medianMS.map { String(format: "%.0f ms", $0) } ?? "—")
            statistic("P95", s.p95MS.map { String(format: "%.0f ms", $0) } ?? "—")
            statistic("延迟标准差", s.jitterMS.map { String(format: "%.0f ms", $0) } ?? "—")
            statistic("最近完整通过", s.lastSuccess?.formatted(date: .omitted, time: .shortened) ?? "暂无")
        }
    }
    private var historyChart: some View {
        let points = model.recentHistory(name).filter { $0.latencyMS > 0 }
        return VStack(alignment: .leading) {
            Text("出口请求耗时（包含建连与响应）").font(.caption).foregroundStyle(.secondary)
            Text("图含健康复验；上方分位数只统计完整测速样本。少于两个耗时样本时不计算标准差。").font(.system(size: 10)).foregroundStyle(.secondary)
            if points.isEmpty { Text("尚无可绘制的出口耗时样本").foregroundStyle(.secondary).frame(height: 130) }
            else {
                Chart(Array(points.enumerated()), id: \.offset) { _, point in
                    PointMark(x: .value("时间", point.date), y: .value("耗时 ms", point.latencyMS)).foregroundStyle(point.success ? Color.teal : Color.orange)
                }.frame(height: 150).chartXScale(range: .plotDimension(padding: 10)).chartYAxisLabel("ms").accessibilityLabel("过去24小时出口请求耗时散点图，详细样本见下方列表")
            }
        }
    }
    private func statistic(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 13, weight: .semibold)) } }
    private func stageRow(_ r: StageResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Label(r.stage.title, systemImage: r.status == .passed ? "checkmark.circle" : (r.status == .deferred ? "clock" : "exclamationmark.circle")).foregroundStyle(r.status == .passed ? Color.teal : Color.orange); Spacer(); Text(r.endpoint.title).foregroundStyle(.secondary); Text(r.status == .passed ? "通过" : (r.status == .deferred ? "待复测" : "未通过")) }
            if let m = r.metrics { Text(String(format: "本地 DNS %.3fs · 本地代理连接 %.3fs · TLS %.3fs · 首字节 %.3fs · 总耗时 %.3fs · 上传 %d / 下载 %d 字节 · HTTP %d", m.dnsSeconds, m.proxyConnectSeconds, m.tlsSeconds, m.firstByteSeconds, m.totalSeconds, m.uploadedBytes, m.downloadedBytes, m.httpStatus)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let note = r.note { Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }.font(.system(size: 11)).padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct IncidentListView: View {
    @ObservedObject var model: MonitorModel
    @State private var showResolved = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Picker("事件范围", selection: $showResolved) { Text("待处理").tag(false); Text("已结束 / 恢复").tag(true) }.pickerStyle(.segmented).frame(width: 220); Spacer(); Button("导出脱敏诊断") { model.exportDiagnostics() } }
            let records = model.incidents.filter { ($0.resolvedAt != nil) == showResolved }
            if records.isEmpty { Text(showResolved ? "尚无恢复记录" : "当前没有未恢复的事件").foregroundStyle(.secondary) }
            ForEach(records) { r in
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Label(r.resolvedAt == nil ? (r.level == "critical" ? "严重事件" : "待处理") : (r.resolutionReason == "contextChanged" ? "上下文已变化" : "已恢复"), systemImage: r.resolvedAt == nil ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(r.resolvedAt == nil ? Color.orange : Color.teal); Spacer(); Text("观察 \(r.count) 次").foregroundStyle(.secondary) }
                    Text(r.message).textSelection(.enabled)
                    if let front = r.frontName { Text("发生时前置：" + front).font(.caption).foregroundStyle(.secondary) }
                    Text("开始 \(r.firstSeen.formatted(date: .abbreviated, time: .standard)) · \(r.resolvedAt == nil ? "最近" : "恢复") \((r.resolvedAt ?? r.lastSeen).formatted(date: .omitted, time: .standard)) · 持续 \(max(0, Int((r.resolvedAt ?? Date()).timeIntervalSince(r.firstSeen)))) 秒").font(.caption).foregroundStyle(.secondary)
                }.font(.system(size: 12)).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
