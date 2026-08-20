import Foundation

struct WriteReport: Equatable, Sendable {
    let succeeded: Bool
    let appliedOperations: [String]
    let error: String?
}

struct NetworkConfigurationWriter {
    let runner: any CommandRunning

    init(runner: any CommandRunning = SystemCommandRunner()) {
        self.runner = runner
    }

    /// Executes only the system-proxy portion of a verified Direct ↔ Clash transition.
    /// VPN controls and PAC writes are intentionally rejected until their real-device
    /// capability checks have passed.
    func apply(target: ModeProfile, snapshot: NetworkSnapshot) -> WriteReport {
        guard [.direct, .clashProxy].contains(target.mode) else {
            return WriteReport(succeeded: false, appliedOperations: [], error: "该模式尚未接入系统写入能力")
        }

        let candidateServices: [NetworkServiceSnapshot]
        if let serviceID = target.networkServiceID {
            candidateServices = snapshot.services.filter { $0.id == serviceID }
        } else {
            candidateServices = snapshot.services.filter { $0.activeProxyCount > 0 }
        }

        guard candidateServices.count == 1, let service = candidateServices.first else {
            return WriteReport(succeeded: false, appliedOperations: [], error: "无法唯一确定要修改的网络服务")
        }

        if service.proxies.contains(where: { $0.kind == .pac && $0.isActive }) {
            return WriteReport(succeeded: false, appliedOperations: [], error: "检测到 PAC 接管；当前写入层不会覆盖 PAC 配置")
        }

        if target.mode == .clashProxy {
            guard let host = target.proxyHost, let port = target.proxyPort else {
                return WriteReport(succeeded: false, appliedOperations: [], error: "Clash 代理地址或端口未登记")
            }
            guard snapshot.portObservations.contains(where: { $0.host == host && $0.port == port && $0.isListening }) else {
                return WriteReport(succeeded: false, appliedOperations: [], error: "目标 Clash 端口未确认监听")
            }
        }

        let original = service.proxies.filter { [.http, .https, .socks].contains($0.kind) }
        var applied: [String] = []
        let result: WriteReport

        switch target.mode {
        case .direct:
            result = disableAll(service: service.name, applied: &applied)
        case .clashProxy:
            result = configureClash(service: service.name, host: target.proxyHost!, port: target.proxyPort!, applied: &applied)
        default:
            result = WriteReport(succeeded: false, appliedOperations: applied, error: "未支持的写入目标")
        }

        guard result.succeeded else {
            _ = restore(service: service.name, endpoints: original)
            return WriteReport(succeeded: false, appliedOperations: applied, error: result.error ?? "网络代理写入失败，已尝试回退")
        }

        let after = readService(service.name, id: service.id)
        guard after.proxies.filter({ [.http, .https, .socks].contains($0.kind) }) == expectedEndpoints(for: target, original: original) else {
            _ = restore(service: service.name, endpoints: original)
            return WriteReport(succeeded: false, appliedOperations: applied, error: "写入后复核不一致，已尝试回退")
        }

        return WriteReport(succeeded: true, appliedOperations: applied, error: nil)
    }

    private func disableAll(service: String, applied: inout [String]) -> WriteReport {
        for (command, label) in [
            ("-setwebproxystate", "HTTP 代理"),
            ("-setsecurewebproxystate", "HTTPS 代理"),
            ("-setsocksfirewallproxystate", "SOCKS 代理")
        ] {
            guard run(command, arguments: [service, "off"]) else {
                return WriteReport(succeeded: false, appliedOperations: applied, error: "关闭\(label)失败")
            }
            applied.append("关闭\(label)")
        }
        return WriteReport(succeeded: true, appliedOperations: applied, error: nil)
    }

    private func configureClash(service: String, host: String, port: Int, applied: inout [String]) -> WriteReport {
        let definitions: [(String, String)] = [
            ("-setwebproxy", "HTTP 代理"),
            ("-setsecurewebproxy", "HTTPS 代理"),
            ("-setsocksfirewallproxy", "SOCKS 代理")
        ]
        for (command, label) in definitions {
            guard run(command, arguments: [service, host, String(port), "off", "", ""]),
                  run(stateCommand(for: command), arguments: [service, "on"]) else {
                return WriteReport(succeeded: false, appliedOperations: applied, error: "配置\(label)失败")
            }
            applied.append("启用\(label)：\(host):\(port)")
        }
        return WriteReport(succeeded: true, appliedOperations: applied, error: nil)
    }

    private func restore(service: String, endpoints: [ProxyEndpoint]) -> Bool {
        for endpoint in endpoints {
            guard let stateCommand = stateCommand(for: endpoint.kind),
                  run(stateCommand, arguments: [service, "off"]) else { return false }
            guard endpoint.enabled,
                  let host = endpoint.server,
                  let port = endpoint.port,
                  let setCommand = setCommand(for: endpoint.kind),
                  run(setCommand, arguments: [service, host, String(port), "off", "", ""]),
                  run(stateCommand, arguments: [service, "on"]) else { continue }
        }
        return true
    }

    private func readService(_ service: String, id: String) -> NetworkServiceSnapshot {
        NetworkServiceSnapshot(
            id: id,
            name: service,
            enabled: true,
            proxies: [
                readProxy(.http, service: service, command: "-getwebproxy"),
                readProxy(.https, service: service, command: "-getsecurewebproxy"),
                readProxy(.socks, service: service, command: "-getsocksfirewallproxy"),
                readProxy(.pac, service: service, command: "-getautoproxyurl")
            ],
            dnsServers: []
        )
    }

    private func readProxy(_ kind: ProxyKind, service: String, command: String) -> ProxyEndpoint {
        let result = runner.run("/usr/sbin/networksetup", arguments: [command, service])
        let values = result.output.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) { values, line in
            let pieces = line.split(separator: ":", maxSplits: 1).map(String.init)
            if pieces.count == 2 {
                values[pieces[0].trimmingCharacters(in: .whitespaces)] = pieces[1].trimmingCharacters(in: .whitespaces)
            }
        }
        let enabled = values["Enabled"].map { ["yes", "true", "1", "on"].contains($0.lowercased()) } ?? false
        return ProxyEndpoint(
            kind: kind,
            enabled: enabled,
            server: kind == .pac ? nil : values["Server"],
            port: kind == .pac ? nil : values["Port"].flatMap(Int.init),
            url: kind == .pac ? values["URL"] : nil
        )
    }

    private func expectedEndpoints(for target: ModeProfile, original: [ProxyEndpoint]) -> [ProxyEndpoint] {
        guard target.mode == .clashProxy,
              let host = target.proxyHost,
              let port = target.proxyPort else {
            return original.map { ProxyEndpoint(kind: $0.kind, enabled: false, server: $0.server, port: $0.port, url: $0.url) }
        }
        return original.map { endpoint in
            ProxyEndpoint(kind: endpoint.kind, enabled: true, server: host, port: port, url: nil)
        }
    }

    private func run(_ command: String, arguments: [String]) -> Bool {
        runner.run("/usr/sbin/networksetup", arguments: [command] + arguments).succeeded
    }

    private func setCommand(for kind: ProxyKind) -> String? {
        switch kind {
        case .http: "-setwebproxy"
        case .https: "-setsecurewebproxy"
        case .socks: "-setsocksfirewallproxy"
        case .pac: nil
        }
    }

    private func stateCommand(for command: String) -> String {
        switch command {
        case "-setwebproxy": "-setwebproxystate"
        case "-setsecurewebproxy": "-setsecurewebproxystate"
        default: "-setsocksfirewallproxystate"
        }
    }

    private func stateCommand(for kind: ProxyKind) -> String? {
        switch kind {
        case .http: "-setwebproxystate"
        case .https: "-setsecurewebproxystate"
        case .socks: "-setsocksfirewallproxystate"
        case .pac: nil
        }
    }
}
