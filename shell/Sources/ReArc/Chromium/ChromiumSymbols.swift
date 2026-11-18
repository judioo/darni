#if REARC_CHROMIUM
import Darwin

/// Engine calls newer than the header this shell builds against, looked up by
/// name in the loaded framework. A feature with several such calls uses all
/// of them or none (`resolve`), and names the ones an engine lacks for the
/// log and the self-test's ABI-GAP line (`missing`).
enum ChromiumSymbols {
    /// The symbol's address; nil when this engine does not export it.
    static func address(_ name: String) -> UnsafeMutableRawPointer? {
        // RTLD_DEFAULT: every image the process has loaded.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    /// Every address, in the order of `names`; nil when one is missing: half an interface is not used.
    static func resolve(_ names: [String]) -> [UnsafeMutableRawPointer]? {
        let found = names.compactMap(address)
        return found.count == names.count ? found : nil
    }

    static func missing(_ names: [String]) -> [String] {
        names.filter { address($0) == nil }
    }
}
#endif
