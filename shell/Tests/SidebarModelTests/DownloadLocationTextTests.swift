import XCTest
@testable import SidebarModel

final class DownloadLocationTextTests: XCTestCase {
    /// A download row's tooltip: the file and its folder by name, never the
    /// folder's path (it showed the person's folder names on screen).
    func testATooltipNamesTheFileAndItsFolderAndNeverThePath() {
        let tip = DownloadLocationText.tooltip(fileName: "report.pdf", targetPath: "/Users/someone/Private Clients/Acme/report.pdf")
        XCTAssertEqual(tip, "report.pdf in Acme")
        XCTAssertFalse(tip.contains("/"))
        XCTAssertFalse(tip.contains("someone"))
        XCTAssertFalse(tip.contains("Private Clients"))
        XCTAssertEqual(DownloadLocationText.tooltip(fileName: "photo.png", targetPath: "/Users/someone/Downloads/photo.png"), "photo.png in Downloads")
        // The row's own name, as shown (Tidy Downloads may have renamed the file on disk).
        XCTAssertEqual(DownloadLocationText.tooltip(fileName: "Invoice March.pdf", targetPath: "/Users/someone/Downloads/inv_0331.pdf"),
                       "Invoice March.pdf in Downloads")
        XCTAssertEqual(DownloadLocationText.tooltip(fileName: "a.zip", targetPath: ""), "a.zip", "no file yet")
        XCTAssertEqual(DownloadLocationText.tooltip(fileName: "a.zip", targetPath: "/a.zip"), "a.zip", "the volume's root has no name")
    }

    func testTheDownloadFolderIsNamedNotLocated() {
        let folder = URL(fileURLWithPath: "/Users/someone/Work Files/Incoming", isDirectory: true)
        XCTAssertEqual(DownloadLocationText.folderName(folder), "Incoming")
        XCTAssertEqual(DownloadLocationText.savedTo(folder), "Downloads are saved to Incoming")
        XCTAssertFalse(DownloadLocationText.savedTo(folder).contains("/"))
        XCTAssertEqual(DownloadLocationText.folderName(URL(fileURLWithPath: "/", isDirectory: true)), "")
        XCTAssertEqual(DownloadLocationText.savedTo(URL(fileURLWithPath: "/", isDirectory: true)), "Where downloads are saved")
    }
}
