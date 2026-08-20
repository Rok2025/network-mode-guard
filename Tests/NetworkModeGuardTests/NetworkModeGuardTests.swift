import Foundation
import Testing
@testable import NetworkModeGuard

@Test
func collectorParsesProxyVPNAndRouteEvidence() {
    let profile = ModeProfile(
        id: "clash",
        mode: .clashProxy,
        displayName: "Clash 代理",
        networkServiceID: "service:test-network",
        proxyHost: "127.0.0.1",
        proxyPort: 7890,
        vpnServiceName: nil,
        isUserConfirmed: true,
        isOperationallyVerified: true
    )
    let responses: [String: CommandResult] = [
        ScriptedCommandRunner.key("/usr/sbin/networksetup", ["-listallnetworkservices"]): result("An asterisk (*) denotes that a network service is disabled.\nTest Network\n", 0),
        ScriptedCommandRunner.key("/usr/sbin/networksetup", ["-getwebproxy", "Test Network"]): result("Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n", 0),
        ScriptedCommandRunner.key("/usr/sbin/networksetup", ["-getsecurewebproxy", "Test Network"]): result("Enabled: Yes\nServer: 127.0.0.1\nPort: 7890\n", 0),
        ScriptedCommandRunner.key("/usr/sbin/networksetup", ["-getsocksfirewallproxy", "Test Network"]): result("Enabled: No\nServer: 127.0.0.1\nPort: 7890\n", 0),
        ScriptedCommandRunner.key("/usr/sbin/networksetup", ["-getautoproxyurl", "Test Network"]): result("Enabled: No\nURL: https://example.invalid/proxy.pac\n", 0),
        ScriptedCommandRunner.key("/usr/sbin/networksetup", ["-getdnsservers", "Test Network"]): result("8.8.8.8\n", 0),
        ScriptedCommandRunner.key("/usr/sbin/scutil", ["--nc", "list"]): result("* (Disconnected) Work VPN\n", 0),
        ScriptedCommandRunner.key("/sbin/route", ["-n", "get", "default"]): result("interface: en0\n", 0),
        ScriptedCommandRunner.key("/usr/bin/nc", ["-z", "-G", "1", "127.0.0.1", "7890"]): result("", 0)
    ]

    let snapshot = NetworkStateCollector(
        runner: ScriptedCommandRunner(responses: responses),
        profiles: [profile]
    ).collect()

    #expect(snapshot.services.count == 1)
    #expect(snapshot.services[0].id == "service:test-network")
    #expect(snapshot.activeProxies.count == 2)
    #expect(snapshot.vpnServices.first?.state == .disconnected)
    #expect(snapshot.defaultInterface == "en0")
    #expect(snapshot.portObservations.first?.isListening == true)
}

@Test
func classifierIdentifiesClashProxyWhenPortIsReady() {
    let profile = ModeProfile(
        id: "clash",
        mode: .clashProxy,
        displayName: "Clash 代理",
        networkServiceID: "service:wi-fi",
        proxyHost: "127.0.0.1",
        proxyPort: 7890,
        vpnServiceName: nil,
        isUserConfirmed: true,
        isOperationallyVerified: true
    )
    let snapshot = NetworkSnapshot(
        collectedAt: .now,
        services: [NetworkServiceSnapshot(
            id: "service:wi-fi",
            name: "Wi-Fi",
            enabled: true,
            proxies: [ProxyEndpoint(kind: .http, enabled: true, server: "127.0.0.1", port: 7890, url: nil)],
            dnsServers: []
        )],
        vpnServices: [],
        defaultInterface: "en0",
        portObservations: [PortObservation(host: "127.0.0.1", port: 7890, isListening: true)],
        dnsCheck: .notChecked,
        httpsCheck: .notChecked
    )

    let assessment = ModeClassifier(profiles: [profile]).assess(snapshot)

    #expect(assessment.mode == .clashProxy)
    #expect(assessment.isHealthy)
    #expect(assessment.confidence == 95)
}

@Test
func classifierBlocksUnknownProxyInsteadOfGuessingClient() {
    let snapshot = NetworkSnapshot(
        collectedAt: .now,
        services: [NetworkServiceSnapshot(
            id: "service:wi-fi",
            name: "Wi-Fi",
            enabled: true,
            proxies: [ProxyEndpoint(kind: .http, enabled: true, server: "127.0.0.1", port: 9999, url: nil)],
            dnsServers: []
        )],
        vpnServices: [],
        defaultInterface: "en0",
        portObservations: [],
        dnsCheck: .notChecked,
        httpsCheck: .notChecked
    )

    let assessment = ModeClassifier(profiles: ModeProfile.defaults).assess(snapshot)

    #expect(assessment.mode == .unknown)
    #expect(assessment.blockers.contains("检测到未登记或无法匹配的网络接管层"))
}

@Test
func classifierSuggestsPalantirBindingFromProviderEvidence() {
    let snapshot = NetworkSnapshot(
        collectedAt: .now,
        services: [],
        vpnServices: [VPNServiceSnapshot(
            id: "vpn:242e0168-88e1-4299-aac6-6724c9bc4306",
            name: "Palantir",
            state: .connected,
            providerIdentifier: "com.ai.security.palantir.mac"
        )],
        defaultInterface: "utun4",
        portObservations: [],
        dnsCheck: .notChecked,
        httpsCheck: .notChecked
    )

    let assessment = ModeClassifier(profiles: ModeProfile.defaults).assess(snapshot)

    #expect(assessment.mode == .palantirVPN)
    #expect(assessment.summary == "已自动识别，等待确认登记")
    #expect(assessment.suggestedProfile?.vpnServiceName == "Palantir")
    #expect(assessment.suggestedProfile?.providerIdentifier == "com.ai.security.palantir.mac")
}

@Test
func transitionPlannerExplainsReadOnlyBoundary() {
    let source = ModeAssessment(
        mode: .direct,
        confidence: 90,
        summary: "直连",
        evidence: [],
        blockers: []
    )
    let target = ModeProfile.defaults.first(where: { $0.mode == .clashProxy })!
    let plan = TransitionPlanner().plan(from: source, to: target, snapshot: .empty)

    #expect(plan.willNotTouch.contains("第三方客户端内部节点、订阅和规则"))
    #expect(plan.blockers.contains("目标模式尚未登记完整"))
    #expect(plan.blockers.contains("写入执行层尚未启用，目前仅提供只读预检"))
    #expect(!plan.canProceed)
}

@Test
func writerRefusesPACInsteadOfOverwritingIt() {
    let snapshot = NetworkSnapshot(
        collectedAt: .now,
        services: [NetworkServiceSnapshot(
            id: "service:test-network",
            name: "Test Network",
            enabled: true,
            proxies: [ProxyEndpoint(kind: .pac, enabled: true, server: nil, port: nil, url: "https://example.invalid/proxy.pac")],
            dnsServers: []
        )],
        vpnServices: [],
        defaultInterface: "en0",
        portObservations: [],
        dnsCheck: .notChecked,
        httpsCheck: .notChecked
    )

    let report = NetworkConfigurationWriter(runner: ScriptedCommandRunner(responses: [:])).apply(
        target: ModeProfile.defaults[0],
        snapshot: snapshot
    )

    #expect(!report.succeeded)
    #expect(report.error == "检测到 PAC 接管；当前写入层不会覆盖 PAC 配置")
    #expect(report.appliedOperations.isEmpty)
}

@Test
func writerRefusesUnverifiedVPNMode() {
    let profile = ModeProfile(
        id: "surge",
        mode: .surgeVPN,
        displayName: "Surge VPN",
        networkServiceID: nil,
        proxyHost: nil,
        proxyPort: nil,
        vpnServiceName: "Surge",
        isOperationallyVerified: false
    )

    let report = NetworkConfigurationWriter(runner: ScriptedCommandRunner(responses: [:])).apply(
        target: profile,
        snapshot: .empty
    )

    #expect(!report.succeeded)
    #expect(report.error == "该模式尚未接入系统写入能力")
}

private func result(_ output: String, _ status: Int32) -> CommandResult {
    CommandResult(output: output, error: "", status: status)
}
