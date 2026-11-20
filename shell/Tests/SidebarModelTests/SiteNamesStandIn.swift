import Foundation
@testable import SidebarModel

extension SiteNames {
    /// A stand-in for Chromium's public suffix list in tests: the engine's answers for a
    /// few names, as its JSON, read through the same decoding as the real call
    /// (`SiteNames.decode`). A test passes it as `names:`.
    ///
    /// - `suffixes`: public suffixes. A suffix itself is not one site. Any other name
    ///   under one is the suffix and one label more.
    /// - `sites`: registrable domains named outright, with every host under them: a site
    ///   whose suffix is not listed, or one that must win over a listed suffix.
    /// - `unsuffixed`: names with no suffix (`localhost`): neither one site nor a suffix.
    /// - `addresses`: an IPv4 address is one site.
    ///
    /// Any other name has no answer, as from an engine that refuses it, and the caller's
    /// own rule holds.
    static func standIn(suffixes: [String], sites: [String] = [], unsuffixed: [String] = [], addresses: Bool = false) -> SiteNames {
        SiteNames { host in
            func reply(_ name: some StringProtocol, oneSite: Bool, suffix: Bool = false) -> String {
                #"{"host":"\#(name)","registrable":\#(oneSite),"suffix":\#(suffix)}"#
            }
            if suffixes.contains(host) { return reply(host, oneSite: false, suffix: true) }
            if unsuffixed.contains(host) { return reply(host, oneSite: false) }
            if addresses, host.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) { return reply(host, oneSite: true) }
            if let site = sites.first(where: { host == $0 || host.hasSuffix("." + $0) }) { return reply(site, oneSite: true) }
            guard let suffix = suffixes.first(where: { host.hasSuffix("." + $0) }) else { return nil }
            let label = host.dropLast(suffix.count + 1).split(separator: ".").last ?? ""
            return reply("\(label).\(suffix)", oneSite: true)
        }
    }
}
