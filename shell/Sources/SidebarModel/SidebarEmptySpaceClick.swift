import Foundation

public enum SidebarEmptySpaceClick {
    public static func opensNewTab(clickCount: Int, rowIndex: Int, y: Double, rowsBottom: Double) -> Bool {
        clickCount == 2 && rowIndex == -1 && y >= rowsBottom
    }

    /// A right-click under the last row opens the sidebar's own menu; on a
    /// row, the row's menu is the one that opens.
    public static func opensMenu(rowIndex: Int, y: Double, rowsBottom: Double) -> Bool {
        rowIndex == -1 && y >= rowsBottom
    }
}
