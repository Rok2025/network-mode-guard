import Foundation

struct ModeClassifier {
    let profiles: [ModeProfile]

    func assess(_ snapshot: NetworkSnapshot) -> ModeAssessment {
        let clashMatches = profiles.filter { profile in
            profile.mode == .clashProxy && matchesClash(profile, snapshot: snapshot)
        }
        let vpnMatches = profiles.filter { profile in
            [.surgeVPN, .palantirVPN].contains(profile.mode) && matchesVPN(profile, snapshot: snapshot)
        }

        let activeKnownModes = Set((clashMatches + vpnMatches).map(\.mode))
        let activeProxyCount = snapshot.activeProxies.count
        let activeVPNCount = snapshot.activeVPNServices.count
        var evidence: [String] = []
        var blockers: [String] = []

        if activeProxyCount > 0 {
            evidence.append("检测到 \(activeProxyCount) 个系统代理/PAC 接管项")
        } else {
            evidence.append("系统代理与 PAC 未启用")
        }

        if activeVPNCount > 0 {
            evidence.append("检测到 \(activeVPNCount) 个活动 VPN 服务")
        } else {
            evidence.append("没有活动 VPN 服务")
        }

        if let interfaceName = snapshot.defaultInterface {
            evidence.append("默认路由接口：\(interfaceName)")
        }

        if activeKnownModes.count > 1 || activeVPNCount > 1 {
            blockers.append("多个网络接管层同时生效")
            return ModeAssessment(
                mode: .conflict,
                confidence: 100,
                summary: "检测到模式冲突，需要先选择切换目标",
                evidence: evidence,
                blockers: blockers
            )
        }

        if let mode = activeKnownModes.first {
            let profile = profiles.first(where: { $0.mode == mode })
            if mode == .clashProxy && !hasListeningClashPort(profile: profile, snapshot: snapshot) {
                blockers.append("系统代理指向的 Clash 本地端口未确认监听")
            }
            return ModeAssessment(
                mode: mode,
                confidence: blockers.isEmpty ? 95 : 70,
                summary: blockers.isEmpty ? "已匹配登记的网络模式" : "已匹配模式，但目标接管尚未就绪",
                evidence: evidence,
                blockers: blockers
            )
        }

        if activeProxyCount == 0 && activeVPNCount == 0 {
            return ModeAssessment(
                mode: .direct,
                confidence: 90,
                summary: "未发现已登记代理或 VPN 接管",
                evidence: evidence,
                blockers: []
            )
        }

        blockers.append("检测到未登记或无法匹配的网络接管层")
        return ModeAssessment(
            mode: .unknown,
            confidence: 40,
            summary: "无法安全匹配当前网络模式",
            evidence: evidence,
            blockers: blockers
        )
    }

    private func matchesClash(_ profile: ModeProfile, snapshot: NetworkSnapshot) -> Bool {
        guard let serviceID = profile.networkServiceID,
              let host = profile.proxyHost,
              let port = profile.proxyPort,
              let service = snapshot.services.first(where: { $0.id == serviceID }) else { return false }
        return service.proxies.contains { endpoint in
            endpoint.isActive && endpoint.server == host && endpoint.port == port
        }
    }

    private func matchesVPN(_ profile: ModeProfile, snapshot: NetworkSnapshot) -> Bool {
        guard let vpnName = profile.vpnServiceName else { return false }
        return snapshot.vpnServices.contains { $0.name == vpnName && $0.isActive }
    }

    private func hasListeningClashPort(profile: ModeProfile?, snapshot: NetworkSnapshot) -> Bool {
        guard let profile,
              let host = profile.proxyHost,
              let port = profile.proxyPort else { return false }
        return snapshot.portObservations.contains { $0.host == host && $0.port == port && $0.isListening }
    }
}

struct TransitionPlanner {
    let executionLayerAvailable: Bool

    init(executionLayerAvailable: Bool = false) {
        self.executionLayerAvailable = executionLayerAvailable
    }

    func plan(from source: ModeAssessment, to target: ModeProfile, snapshot: NetworkSnapshot) -> TransitionPlan {
        var blockers = source.blockers
        if source.mode == .conflict || source.mode == .unknown {
            blockers.append("当前模式不明确，禁止覆盖未知接管层")
        }
        if !target.isConfigured {
            blockers.append("目标模式尚未登记完整")
        }
        if !target.isOperationallyVerified {
            blockers.append("目标模式尚未完成真实机能力验证")
        }
        if !executionLayerAvailable {
            blockers.append("写入执行层尚未启用，目前仅提供只读预检")
        }

        let willDisable = disableOperations(for: snapshot)
        let willEnable = enableOperations(for: target)
        let willNotTouch = [
            "第三方客户端内部节点、订阅和规则",
            "DNS 配置与未登记 VPN",
            "浏览记录、令牌和诊断原始输出"
        ]

        return TransitionPlan(
            source: source,
            target: target,
            willDisable: willDisable,
            willEnable: willEnable,
            willNotTouch: willNotTouch,
            blockers: unique(blockers)
        )
    }

    private func disableOperations(for snapshot: NetworkSnapshot) -> [String] {
        var operations = snapshot.services.flatMap { service in
            service.proxies.filter(\.isActive).map { endpoint in
                "关闭 \(service.name) 的 \(endpoint.kind.displayName)"
            }
        }
        operations.append(contentsOf: snapshot.activeVPNServices.map { "断开已登记 VPN：\($0.name)" })
        return operations.isEmpty ? ["无已登记接管层需要关闭"] : operations
    }

    private func enableOperations(for target: ModeProfile) -> [String] {
        switch target.mode {
        case .direct:
            return ["保持直连，不启动新的接管层"]
        case .clashProxy:
            guard let serviceID = target.networkServiceID,
                  let host = target.proxyHost,
                  let port = target.proxyPort else { return ["目标 Clash 代理未登记完整"] }
            return ["在 \(serviceID) 启用系统代理：\(host):\(port)"]
        case .surgeVPN, .palantirVPN:
            return ["连接已登记 VPN：\(target.vpnServiceName ?? "未命名服务")"]
        case .conflict, .unknown:
            return []
        }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension ProxyKind {
    var displayName: String {
        switch self {
        case .http: "HTTP 代理"
        case .https: "HTTPS 代理"
        case .socks: "SOCKS 代理"
        case .pac: "PAC"
        }
    }
}
