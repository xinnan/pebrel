import Combine
import Foundation

struct DiscoveredComputer: Identifiable, Equatable {
    let serviceName: String
    let name: String
    let address: String
    let pin: String

    var id: String { "\(serviceName)|\(pin)" }
}

/// Bonjour / mDNS discovery for `_pebrel-pair._tcp.` paired & pairable LAN desktops.
/// Security invariant: mDNS is strictly an address hint and never authorizes credentials.
final class PairingDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {
    @Published private(set) var computers: [DiscoveredComputer] = []
    @Published private(set) var searching = false

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []
    private var resolvedByKey: [String: DiscoveredComputer] = [:]
    private let maxTracked = 32

    var onDiscovered: ((DiscoveredComputer) -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        stop()
        searching = true
        browser.searchForServices(ofType: "_pebrel-pair._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        for service in resolving {
            service.stop()
            service.delegate = nil
        }
        resolving.removeAll()
        searching = false
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard resolving.count < maxTracked else { return }
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 8.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        resolvedByKey.removeValue(forKey: service.name)
        publishSorted()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in
            self?.searching = false
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let txtData = sender.txtRecordData() else { return }
        let dict = NetService.dictionary(fromTXTRecord: txtData)

        func txtString(_ key: String) -> String? {
            guard let data = dict[key], let str = String(data: data, encoding: .utf8) else { return nil }
            return str
        }

        guard txtString("version") == "2",
              let pin = txtString("pin"),
              PinnedTlsSessionDelegate.isValidPin(pin),
              sender.port >= 1, sender.port <= 65535,
              let hostAddr = selectHostAddress(sender.addresses ?? []) else {
            return
        }

        let displayName = (txtString("name")?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : String($0.prefix(80)) }
            ?? String(sender.name.prefix(80))

        let formattedHost = hostAddr.contains(":") ? "[\(hostAddr)]" : hostAddr
        let computer = DiscoveredComputer(
            serviceName: sender.name,
            name: displayName,
            address: "https://\(formattedHost):\(sender.port)",
            pin: pin
        )
        resolvedByKey[sender.name] = computer
        publishSorted()
        DispatchQueue.main.async { [weak self] in
            self?.onDiscovered?(computer)
        }
    }

    private func publishSorted() {
        let sorted = resolvedByKey.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        DispatchQueue.main.async { [weak self] in
            self?.computers = sorted
        }
    }

    private func selectHostAddress(_ addresses: [Data]) -> String? {
        var ipv4: String?
        var ipv6: String?
        for data in addresses {
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                if sa.pointee.sa_family == sa_family_t(AF_INET) {
                    var addr = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    let firstOctet = UInt8(addr.s_addr & 0xFF)
                    if ip != "0.0.0.0" && !(firstOctet >= 224 && firstOctet <= 239) && ipv4 == nil {
                        ipv4 = ip
                    }
                } else if sa.pointee.sa_family == sa_family_t(AF_INET6) {
                    var addr = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    inet_ntop(AF_INET6, &addr, &buf, socklen_t(INET6_ADDRSTRLEN))
                    let ip = String(cString: buf)
                    let lower = ip.lowercased()
                    if lower != "::" && !lower.hasPrefix("fe80:") && !lower.hasPrefix("ff") && ipv6 == nil {
                        ipv6 = ip
                    }
                }
            }
        }
        return ipv4 ?? ipv6
    }

    deinit {
        stop()
    }
}
