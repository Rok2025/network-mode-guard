import Foundation

enum NetworkMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case direct
    case clashProxy
    case surgeVPN
    case palantirVPN
    case conflict
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: "直连"
        case .clashProxy: "Clash 代理"
        case .surgeVPN: "Surge VPN"
        case .palantirVPN: "Palantir VPN"
        case .conflict: "冲突"
        case .unknown: "未知"
        }
    }

    var systemImage: String {
        switch self {
        case .direct: "arrow.up.right"
        case .clashProxy: "point.3.connected.trianglepath.dotted"
        case .surgeVPN, .palantirVPN: "lock.shield"
        case .conflict: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }
}

enum ProxyKind: String, Codable, Sendable {
    case http
    case https
    case socks
    case pac
}

struct ProxyEndpoint: Codable, Equatable, Hashable, Sendable {
    var kind: ProxyKind
    var enabled: Bool
    var server: String?
    var port: Int?
    var url: String?

    var isActive: Bool {
        enabled && (kind == .pac || (server?.isEmpty == false && port != nil))
    }
}

struct NetworkServiceSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let proxies: [ProxyEndpoint]
    let dnsServers: [String]

    var activeProxyCount: Int {
        proxies.filter(\.isActive).count
    }
}

enum VPNConnectionState: String, Codable, Sendable {
    case connected
    case disconnected
    case connecting
    case disconnecting
    case unknown

    var isActive: Bool { self == .connected || self == .connecting }
}

struct VPNServiceSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let state: VPNConnectionState

    var isActive: Bool { state.isActive }
}

struct PortObservation: Codable, Equatable, Hashable, Sendable, Identifiable {
    let host: String
    let port: Int
    let isListening: Bool

    var id: String { "\(host):\(port)" }
}

enum CheckResult: Codable, Equatable, Sendable {
    case passed
    case failed(String)
    case notChecked

    var shortDescription: String {
        switch self {
        case .passed: "正常"
        case .failed(let reason): reason
        case .notChecked: "未检查"
        }
    }
}

struct NetworkSnapshot: Codable, Equatable, Sendable {
    let collectedAt: Date
    let services: [NetworkServiceSnapshot]
    let vpnServices: [VPNServiceSnapshot]
    let defaultInterface: String?
    let portObservations: [PortObservation]
    let dnsCheck: CheckResult
    let httpsCheck: CheckResult

    var activeProxies: [ProxyEndpoint] {
        services.flatMap(\.proxies).filter(\.isActive)
    }

    var activeVPNServices: [VPNServiceSnapshot] {
        vpnServices.filter(\.isActive)
    }

    static let empty = NetworkSnapshot(
        collectedAt: .now,
        services: [],
        vpnServices: [],
        defaultInterface: nil,
        portObservations: [],
        dnsCheck: .notChecked,
        httpsCheck: .notChecked
    )
}

struct ModeProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: String
    var mode: NetworkMode
    var displayName: String
    var networkServiceID: String?
    var proxyHost: String?
    var proxyPort: Int?
    var vpnServiceName: String?
    var isOperationallyVerified: Bool

    var isConfigured: Bool {
        switch mode {
        case .direct: true
        case .clashProxy: networkServiceID != nil && proxyHost != nil && proxyPort != nil
        case .surgeVPN, .palantirVPN: vpnServiceName != nil
        case .conflict, .unknown: false
        }
    }

    var capabilityDescription: String {
        if !isConfigured { return "未登记" }
        if !isOperationallyVerified { return "只读，待真实机验证" }
        return "可切换"
    }

    static let defaults: [ModeProfile] = [
        ModeProfile(
            id: "direct",
            mode: .direct,
            displayName: "直连",
            networkServiceID: nil,
            proxyHost: nil,
            proxyPort: nil,
            vpnServiceName: nil,
            isOperationallyVerified: true
        ),
        ModeProfile(
            id: "clash",
            mode: .clashProxy,
            displayName: "Clash 代理",
            networkServiceID: nil,
            proxyHost: "127.0.0.1",
            proxyPort: 7890,
            vpnServiceName: nil,
            isOperationallyVerified: false
        ),
        ModeProfile(
            id: "surge",
            mode: .surgeVPN,
            displayName: "Surge VPN",
            networkServiceID: nil,
            proxyHost: nil,
            proxyPort: nil,
            vpnServiceName: nil,
            isOperationallyVerified: false
        ),
        ModeProfile(
            id: "palantir",
            mode: .palantirVPN,
            displayName: "Palantir VPN",
            networkServiceID: nil,
            proxyHost: nil,
            proxyPort: nil,
            vpnServiceName: nil,
            isOperationallyVerified: false
        )
    ]
}

struct ModeAssessment: Equatable, Sendable {
    let mode: NetworkMode
    let confidence: Int
    let summary: String
    let evidence: [String]
    let blockers: [String]

    var isHealthy: Bool { blockers.isEmpty && mode != .conflict && mode != .unknown }
}

struct TransitionPlan: Equatable, Sendable {
    let source: ModeAssessment
    let target: ModeProfile
    let willDisable: [String]
    let willEnable: [String]
    let willNotTouch: [String]
    let blockers: [String]

    var canProceed: Bool { blockers.isEmpty && target.isConfigured && target.isOperationallyVerified }
}
