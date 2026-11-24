import Foundation

/// The reader view's fixture pages (docs/FEATURE-SPECS/READER-VIEW.md §10),
/// served by the loopback fixture server in the self-test and by the unit
/// tests' own loopback server: an article, a page that is not one, and a
/// hostile article whose every payload asks the server for the beacon path.
/// A beacon is counted here on arrival, so "nothing ran in the reader" is
/// the server's word: the count did not move.
enum SelfTestReaderFixture {
    static let articlePath = "/reader/article"
    static let plainPath = "/reader/plain"
    static let hostilePath = "/reader/hostile"
    static let beaconPath = "/reader/beacon"
    static let picturePath = "/reader/picture.png"

    static let articleTitle = "The Keeper of Skerry Light"
    static let articleByline = "Marit Halvorsen"
    static let articleSite = "The Coastal Review"
    static let hostileTitle = "Notes on a Quiet Harbour"
    /// In the hostile article's text: the reader must still show it.
    static let hostileMarker = "harbour-text-survives"

    // MARK: Beacons

    private static let lock = NSLock()
    nonisolated(unsafe) private static var beacons: [String: Int] = [:]

    /// How often each payload's beacon arrived, by its `id`.
    static var beaconCounts: [String: Int] { lock.withLock { beacons } }
    static var beaconTotal: Int { lock.withLock { beacons.values.reduce(0, +) } }
    static func resetBeacons() { lock.withLock { beacons = [:] } }

    /// The `id` of a beacon request, nil for any other path.
    static func beaconID(_ pathAndQuery: String) -> String? {
        let parts = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.first.map(String.init) == beaconPath else { return nil }
        let query = parts.count > 1 ? parts[1] : ""
        let id = query.split(separator: "&").first { $0.hasPrefix("id=") }.map { String($0.dropFirst(3)) }
        return id ?? "unnamed"
    }

    /// The body for one of this fixture's paths, a beacon counted; nil for any other path.
    static func response(forPathAndQuery pathAndQuery: String) -> (body: Data, type: String)? {
        if let id = beaconID(pathAndQuery) {
            lock.withLock { beacons[id, default: 0] += 1 }
            return (pixelGIF, "image/gif")
        }
        switch pathAndQuery.split(separator: "?", maxSplits: 1).first.map(String.init) ?? pathAndQuery {
        case articlePath: return (Data(articleHTML.utf8), "text/html; charset=utf-8")
        case plainPath: return (Data(plainHTML.utf8), "text/html; charset=utf-8")
        case hostilePath: return (Data(hostileHTML.utf8), "text/html; charset=utf-8")
        case picturePath: return (picturePNG, "image/png")
        default: return nil
        }
    }

    /// 16×16 PNG: larger than 1×1, so the reader may show it once the page has loaded it.
    static let picturePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAFklEQVR4nGMQVDImCTGMahjVMHw1AAAaNGYB4V8qqwAAAABJRU5ErkJggg=="
    )!
    static let pixelGIF = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!

    // MARK: Pages

    private static let paragraphs = [
        "For thirty-one winters the lamp on Skerry rock was lit by hand, and for most of them the hand belonged to one man. He kept a ledger of every night: the wind, the swell, the hour the wick was trimmed, and the names of the boats he could make out before the dark closed in.",
        "The ledgers survive, forty of them, in a tin trunk that smells of paraffin. Read in order they are less a record of weather than of attention. Nothing happens on most pages, and that is what the pages are for. A light that is noticed has usually failed.",
        "Visitors were rare. A supply boat came every third week when the sea allowed it, and twice a year an inspector climbed the ninety-four steps to count the spare mantles and to sign the book. The keeper wrote that he liked the inspector well enough, and liked the day after better.",
        "What he feared was not storm but fog. In a gale a ship knows where the danger lies and keeps away from it. In fog the rock makes no sound until it is under the keel, so on those nights he rang the bell himself, every two minutes, until the morning burned the grey off the water.",
        "When the lamp was made electric the ledgers stopped in the middle of a week. The last entry gives the wind as light and westerly and the visibility as good. Below it, in a different pen, someone has added the single word that every keeper hopes to write at the end of a watch: quiet.",
    ]

    static let articleHTML = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>\(articleTitle) | \(articleSite)</title>
    <meta property="og:site_name" content="\(articleSite)"><meta name="author" content="\(articleByline)">
    <meta property="og:title" content="\(articleTitle)"></head>
    <body><nav><a href="/a">Home</a> <a href="/search">Search</a> <a href="\(plainPath)">About</a></nav>
    <article><h1>\(articleTitle)</h1>
    <p>\(paragraphs[0])</p>
    <figure><img src="\(picturePath)" width="16" height="16" alt="The lamp room"><figcaption>The lamp room in winter.</figcaption></figure>
    <p>\(paragraphs[1])</p>
    <h2>The inspector</h2>
    <p>\(paragraphs[2]) More in <a href="\(plainPath)">the archive</a>.</p>
    <blockquote><p>A light that is noticed has usually failed.</p></blockquote>
    <ul><li>Wicks trimmed at dusk</li><li>The bell every two minutes in fog</li></ul>
    <p>\(paragraphs[3])</p>
    <table><thead><tr><th>Year</th><th>Nights of fog</th></tr></thead><tbody><tr><td>1931</td><td>42</td></tr></tbody></table>
    <pre><code>wind: W light\nvisibility: good</code></pre>
    <p>\(paragraphs[4])</p>
    </article><footer><p>Copyright The Coastal Review.</p></footer></body></html>
    """

    static let plainHTML = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>About</title></head>
    <body><nav><a href="/a">Home</a> <a href="/search">Search</a></nav><h1>About</h1><p>Contact us.</p>
    <ul><li><a href="\(articlePath)">An article</a></li><li><a href="/a">Page A</a></li></ul></body></html>
    """

    /// The payloads' ids, each a way a page could try to run something in the reader.
    static let hostilePayloads = [
        "body-script", "img-onerror", "p-onclick", "svg-onload", "iframe-srcdoc", "style-import", "link-sheet",
        "srcset", "background", "object", "embed", "video-poster", "details-ontoggle", "body-onload",
        "template", "noscript", "input-autofocus", "math", "external-script",
    ]

    private static func beacon(_ id: String) -> String { "\(beaconPath)?id=\(id)" }
    private static func ping(_ id: String) -> String { "new Image().src='\(beacon(id))'" }

    static let hostileHTML = """
    <!doctype html><html lang="en"><head><meta charset="utf-8"><title>\(hostileTitle)</title>
    <meta property="og:site_name" content="Harbour &lt;script&gt;\(ping("site-name"))&lt;/script&gt;">
    <link rel="stylesheet" href="\(beacon("link-sheet"))">
    <style>@import url("\(beacon("style-import"))"); article { background: url("\(beacon("background"))"); }</style>
    </head>
    <body onload="\(ping("body-onload"))">
    <article><h1>\(hostileTitle)</h1>
    <p onclick="\(ping("p-onclick"))" style="background:url(\(beacon("background")))">\(paragraphs[0]) \(hostileMarker)</p>
    <script>\(ping("body-script"));</script>
    <script src="\(beacon("external-script"))"></script>
    <p>\(paragraphs[1]) <img src="/reader/missing.png" onerror="\(ping("img-onerror"))" alt="x">
    <a href="javascript:\(ping("javascript-link"))">a javascript link</a>
    <a href="jav&#x09;ascript:\(ping("tab-javascript-link"))">a split javascript link</a>
    <a href="data:text/html,<script>\(ping("data-link"))</script>">a data link</a></p>
    <svg onload="\(ping("svg-onload"))" width="10" height="10"><script>\(ping("svg-onload"))</script><circle r="4"/></svg>
    <math><mtext><img src="x" onerror="\(ping("math"))"></mtext></math>
    <iframe srcdoc="<script>\(ping("iframe-srcdoc"))</script>"></iframe>
    <p>\(paragraphs[2]) <img src="\(picturePath)" srcset="\(beacon("srcset")) 1x, javascript:alert(1) 2x" width="16" height="16" alt="lamp"></p>
    <object data="\(beacon("object"))"></object><embed src="\(beacon("embed"))">
    <video poster="\(beacon("video-poster"))" onloadstart="\(ping("video-poster"))"></video>
    <details open ontoggle="\(ping("details-ontoggle"))"><summary>More</summary><p>\(paragraphs[3])</p></details>
    <template><img src="x" onerror="\(ping("template"))"></template>
    <noscript><img src="\(beacon("noscript"))"><p title="</noscript><img src=x onerror=\(ping("noscript"))>">x</p></noscript>
    <form action="\(beacon("form"))"><input autofocus onfocus="\(ping("input-autofocus"))"><button formaction="javascript:\(ping("form"))">Go</button></form>
    <p>\(paragraphs[4])</p>
    </article></body></html>
    """
}
