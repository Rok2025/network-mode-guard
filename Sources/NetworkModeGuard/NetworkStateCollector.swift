import Foundation
import SystemConfiguration

struct NetworkStateCollector {
    let runner: any CommandRunning
    let profiles: [ModeProfile]

    init(runner: any CommandRunning = SystemCommandRunner(), profiles: [ModeProfile] = ModeProfile.defaults) {
        self.runner = runner
        self.profiles = profiles
    }

    func collect() -> NetworkSnapshot {
        let discoveredServices = discoverServices()
        let services = discoveredServices.map { service in
            NetworkServiceSnapshot(
                id: service.id,
                name: service.name,
                enabled: service.enabled,
                proxies: [
                    readProxy(.http, service: service.name, command: "-getwebproxy"),
                    readProxy(.https, service: service.name, command: "-getsecurewebproxy"),
                    readProxy(.socks, service: service.name, command: "-getsocksfirewallproxy"),
                    readProxy(.pac, service: service.name, command: "-getautoproxyurl")
                ],
                dnsServers: readDNSServers(service: service.name)
            )
        }

        let vpnServices = readVPNServices()
        let portObservations = profiles.compactMap { profile -> PortObservation? in
            guard profile.mode == .clashProxy,
                  let host = profile.proxyHost,
                  let port = profile.proxyPort else { return nil }
            let result = runner.run("/usr/bin/nc", arguments: ["-z", "-G", "1", host, String(port)])
            return PortObservation(host: host, port: port, isListening: result.succeeded)
        }

        return NetworkSnapshot(
            collectedAt: .now,
            services: services,
            vpnServices: vpnServices,
            defaultInterface: readDefaultInterface(),
            portObservations: portObservations,
            dnsCheck: .notChecked,
            httpsCheck: .notChecked
        )
    }

    private func discoverServices() -> [(id: String, name: String, enabled: Bool)] {
        let result = runner.run("/usr/sbin/networksetup", arguments: ["-listallnetworkservices"])
        guard result.succeeded else { return [] }
        let systemIDs = systemServiceIDs()

        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty && !$0.contains("An asterisk") }
            .map { rawName in
                let disabled = rawName.hasPrefix("*")
                let name = disabled ? String(rawName.dropFirst()).trimmingCharacters(in: .whitespaces) : rawName
                return (id: systemIDs[name] ?? stableServiceID(for: name), name: name, enabled: !disabled)
            }
    }

    private func systemServiceIDs() -> [String: String] {
        guard let preferences = SCPreferencesCreate(nil, ("NetworkModeGuard" as NSString) as CFString, nil),
              let currentSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(currentSet) else { return [:] }

        var result: [String: String] = [:]
        for case let service as SCNetworkService in services as NSArray {
            if let name = SCNetworkServiceGetName(service),
               let id = SCNetworkServiceGetServiceID(service) {
                result[name as String] = id as String
            }
        }
        return result
    }

    private func readProxy(_ kind: ProxyKind, service: String, command: String) -> ProxyEndpoint {
        let result = runner.run("/usr/sbin/networksetup", arguments: [command, service])
        let values = parseKeyValueOutput(result.output)
        let enabled = parseBoolean(values["Enabled"])
        if kind == .pac {
            return ProxyEndpoint(kind: kind, enabled: enabled, server: nil, port: nil, url: values["URL"])
        }

        return ProxyEndpoint(
            kind: kind,
            enabled: enabled,
            server: values["Server"],
            port: values["Port"].flatMap(Int.init),
            url: nil
        )
    }

    private func readDNSServers(service: String) -> [String] {
        let result = runner.run("/usr/sbin/networksetup", arguments: ["-getdnsservers", service])
        guard result.succeeded else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("aren't any dns") }
    }

    private func readVPNServices() -> [VPNServiceSnapshot] {
        let result = runner.run("/usr/sbin/scutil", arguments: ["--nc", "list"])
        guard result.succeeded else { return [] }

        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> VPNServiceSnapshot? in
                let text = String(line).trimmingCharacters(in: .whitespaces)
                guard let open = text.firstIndex(of: "("),
                      let close = text[open...].firstIndex(of: ")") else { return nil }
                let stateText = String(text[text.index(after: open)..<close]).lowercased()
                let remainder = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
                let name = quotedName(in: remainder) ?? remainder
                guard !name.isEmpty else { return nil }
                let providerIdentifier = providerIdentifier(in: remainder)
                let serviceID = remainder
                    .split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first(where: { UUID(uuidString: String($0)) != nil })
                    .map(String.init)
                return VPNServiceSnapshot(
                    id: "vpn:\(serviceID ?? stableIdentifier(for: name))",
                    name: name,
                    state: vpnState(from: stateText),
                    providerIdentifier: providerIdentifier
                )
            }
    }

    private func readDefaultInterface() -> String? {
        let result = runner.run("/sbin/route", arguments: ["-n", "get", "default"])
        guard result.succeeded else { return nil }
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "interface" {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func parseKeyValueOutput(_ output: String) -> [String: String] {
        output.split(whereSeparator: \.isNewline).reduce(into: [:]) { values, line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    private func parseBoolean(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["yes", "true", "1", "on"].contains(value.lowercased())
    }

    private func vpnState(from value: String) -> VPNConnectionState {
        if value.contains("connected") && !value.contains("disconnected") { return .connected }
        if value.contains("connecting") { return .connecting }
        if value.contains("disconnecting") { return .disconnecting }
        if value.contains("disconnected") { return .disconnected }
        return .unknown
    }

    private func providerIdentifier(in value: String) -> String? {
        guard let start = value.range(of: "VPN ("),
              let end = value[start.upperBound...].firstIndex(of: ")") else { return nil }
        return String(value[start.upperBound..<end])
    }

    private func quotedName(in value: String) -> String? {
        guard let start = value.firstIndex(of: "\""),
              let end = value[value.index(after: start)...].firstIndex(of: "\"") else { return nil }
        return String(value[value.index(after: start)..<end])
    }

    private func stableServiceID(for name: String) -> String {
        "service:\(stableIdentifier(for: name))"
    }

    private func stableIdentifier(for value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .map { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" ? String(scalar) : "-"
            }
            .joined()
            .split(separator: "-")
            .joined(separator: "-")
    }
}
