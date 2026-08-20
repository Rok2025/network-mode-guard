import AppKit
import SwiftUI

@main
struct NetworkModeGuardApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Network Mode Guard", systemImage: "network") {
            MenuBarMenuView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Network Mode Guard", id: "main") {
            NetworkModeGuardView()
                .environmentObject(appState)
        }
        .defaultSize(width: 430, height: 560)
    }
}

private struct MenuBarMenuView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button("打开主窗口") {
            openWindow(id: "main")
        }
        Text("当前：\(appState.assessment.mode.title)")
        Divider()
        Button("重新采集") {
            appState.refresh()
        }
        Button("退出") {
            NSApplication.shared.terminate(nil)
        }
    }
}

struct NetworkModeGuardView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var showingDiagnostics = false
    @State private var showingRegistration = false

    var body: some View {
        Group {
            if showingDiagnostics {
                DiagnosticsView {
                    showingDiagnostics = false
                }
                .environmentObject(appState)
            } else {
                mainContent
            }
        }
        .padding(16)
        .frame(width: 430)
        .task {
            if appState.snapshot == .empty { appState.refresh() }
        }
        .sheet(isPresented: $showingRegistration) {
            ProfileRegistrationView()
                .environmentObject(appState)
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            currentModeCard
            modePicker

            if let plan = appState.transitionPlan {
                TransitionPlanCard(plan: plan)
            }

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Label("Network Mode Guard", systemImage: "network")
                .font(.headline)
            Spacer()
            Button {
                appState.refresh()
            } label: {
                Image(systemName: appState.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新采集网络状态")
        }
    }

    private var currentModeCard: some View {
        HStack(spacing: 12) {
            Image(systemName: appState.assessment.mode.systemImage)
                .font(.title2)
                .foregroundStyle(appState.assessment.isHealthy ? .green : .orange)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(appState.assessment.mode.title)
                    .font(.title3.weight(.semibold))
                Text(appState.assessment.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let suggestion = appState.assessment.suggestedProfile {
                    Button("确认登记 \(suggestion.displayName)") {
                        appState.confirmSuggestedMode()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                }
            }
            Spacer()
            Text("\(appState.assessment.confidence)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("选择目标模式")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("登记模式") { showingRegistration = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            ForEach(appState.profiles.filter { [.direct, .clashProxy, .surgeVPN, .palantirVPN].contains($0.mode) }) { profile in
                ModeRow(
                    profile: profile,
                    currentMode: appState.assessment.mode,
                    isSuggested: profile.mode == appState.assessment.suggestedProfile?.mode
                ) {
                    appState.prepareTransition(to: profile)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("查看诊断") { showingDiagnostics = true }
                .buttonStyle(.borderless)
            Spacer()
            Button("关闭窗口") { dismiss() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Button("退出") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

private struct ModeRow: View {
    let profile: ModeProfile
    let currentMode: NetworkMode
    let isSuggested: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: profile.mode.systemImage)
                    .frame(width: 22)
                    .foregroundStyle(profile.mode == currentMode ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .foregroundStyle(.primary)
                    Text(isSuggested ? "已自动发现，待确认" : profile.capabilityDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if profile.mode == currentMode {
                    Text("当前")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                } else if !profile.isConfigured {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .disabled(!profile.isConfigured || profile.mode == currentMode)
    }
}

private struct TransitionPlanCard: View {
    let plan: TransitionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("切换至 \(plan.target.displayName)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: plan.canProceed ? "checkmark.circle.fill" : "lock.fill")
                    .foregroundStyle(plan.canProceed ? .green : .orange)
            }

            PlanSection(title: "将关闭", items: plan.willDisable, color: .orange)
            PlanSection(title: "将启动", items: plan.willEnable, color: .blue)
            PlanSection(title: "不会触碰", items: plan.willNotTouch, color: .green)

            if !plan.blockers.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("当前不可执行", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(plan.blockers, id: \.self) { blocker in
                        Text("· \(blocker)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct PlanSection: View {
    let title: String
    let items: [String]
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            ForEach(items, id: \.self) { item in
                Text("• \(item)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("网络诊断")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("完成", action: onDone)
                    .buttonStyle(.borderless)
            }

            Text("当前模式：\(appState.assessment.mode.title)")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label(appState.assessment.summary, systemImage: appState.assessment.isHealthy ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(appState.assessment.isHealthy ? .green : .orange)
                    ForEach(appState.assessment.evidence, id: \.self) { evidence in
                        Text(evidence)
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !appState.assessment.blockers.isEmpty {
                GroupBox("阻断原因") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(appState.assessment.blockers, id: \.self) { blocker in
                            Text("• \(blocker)")
                                .font(.caption)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Text("采集时间：\(appState.snapshot.collectedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(18)
        .frame(width: 400, height: 340)
    }
}

struct ProfileRegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @State private var mode: NetworkMode = .clashProxy
    @State private var serviceID = ""
    @State private var proxyHost = "127.0.0.1"
    @State private var proxyPort = "7890"
    @State private var vpnServiceName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登记网络模式")
                .font(.title3.weight(.semibold))

            Picker("模式", selection: $mode) {
                Text("Clash 代理").tag(NetworkMode.clashProxy)
                Text("Surge VPN").tag(NetworkMode.surgeVPN)
                Text("Palantir VPN").tag(NetworkMode.palantirVPN)
            }
            .pickerStyle(.segmented)

            if mode == .clashProxy {
                TextField("网络服务 ID，例如 service:wi-fi", text: $serviceID)
                TextField("本地代理地址", text: $proxyHost)
                TextField("本地代理端口", text: $proxyPort)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("系统 VPN 服务名称", text: $vpnServiceName)
                    .textFieldStyle(.roundedBorder)
            }

            Text("登记只保存切换所需的最小元数据；写入能力仍需真实机验证。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存登记") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func save() {
        let id: String
        let displayName: String
        switch mode {
        case .clashProxy:
            id = "clash"
            displayName = "Clash 代理"
        case .surgeVPN:
            id = "surge"
            displayName = "Surge VPN"
        case .palantirVPN:
            id = "palantir"
            displayName = "Palantir VPN"
        default:
            return
        }

            appState.save(profile: ModeProfile(
            id: id,
            mode: mode,
            displayName: displayName,
            networkServiceID: mode == .clashProxy ? serviceID.nilIfEmpty : nil,
            proxyHost: mode == .clashProxy ? proxyHost.nilIfEmpty : nil,
                proxyPort: mode == .clashProxy ? Int(proxyPort) : nil,
                vpnServiceName: mode == .clashProxy ? nil : vpnServiceName.nilIfEmpty,
                isUserConfirmed: true,
                isOperationallyVerified: false
            ))
        dismiss()
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
