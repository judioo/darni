import CoreGraphics
import Foundation

/// The Memory map's layout (docs/TASK-MANAGER-INSIGHTS.md §4.1): a squarified
/// treemap (Bruls, Huizing and van Wijk), area for footprint. The largest
/// item comes first; equal ones in the order of their IDs, so the same
/// figures always give the same picture.
public enum TaskManagerTreemap {
    public struct Item: Equatable, Sendable {
        public var id: String
        public var value: Double

        public init(id: String, value: Double) {
            self.id = id
            self.value = value
        }
    }

    public struct Tile: Equatable, Sendable {
        public var id: String
        public var rect: CGRect
    }

    /// Tiles for the items with a value above 0, filling `rect` with no gap and no overlap.
    public static func layout(_ items: [Item], in rect: CGRect) -> [Tile] {
        let items = items.filter { $0.value > 0 && $0.value.isFinite }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.id < $1.id }
        let total = items.reduce(0) { $0 + $1.value }
        guard total > 0, rect.width > 0, rect.height > 0 else { return [] }
        let scale = Double(rect.width * rect.height) / total
        var remaining = items.map { (id: $0.id, area: $0.value * scale) }[...]
        var free = rect
        var tiles: [Tile] = []
        while !remaining.isEmpty {
            let side = Double(min(free.width, free.height))
            var row: [(id: String, area: Double)] = []
            var next = remaining.startIndex
            while next < remaining.endIndex {
                let candidate = row + [remaining[next]]
                guard row.isEmpty || worst(candidate, side: side) <= worst(row, side: side) else { break }
                row = candidate
                next += 1
            }
            remaining = remaining[next...]
            let area = row.reduce(0) { $0 + $1.area }
            // The last row takes what is left, so rounding never leaves a sliver.
            if free.width >= free.height {
                let width = remaining.isEmpty ? free.width : CGFloat(area / Double(free.height))
                var y = free.minY
                for (index, item) in row.enumerated() {
                    let height = index == row.count - 1 ? free.maxY - y : CGFloat(item.area / Double(width))
                    tiles.append(Tile(id: item.id, rect: CGRect(x: free.minX, y: y, width: width, height: height)))
                    y += height
                }
                free = CGRect(x: free.minX + width, y: free.minY, width: max(0, free.width - width), height: free.height)
            } else {
                let height = remaining.isEmpty ? free.height : CGFloat(area / Double(free.width))
                var x = free.minX
                for (index, item) in row.enumerated() {
                    let width = index == row.count - 1 ? free.maxX - x : CGFloat(item.area / Double(height))
                    tiles.append(Tile(id: item.id, rect: CGRect(x: x, y: free.minY, width: width, height: height)))
                    x += width
                }
                free = CGRect(x: free.minX, y: free.minY + height, width: free.width, height: max(0, free.height - height))
            }
        }
        return tiles
    }

    /// The worst aspect ratio in a row laid along a side of length `side`.
    static func worst(_ row: [(id: String, area: Double)], side: Double) -> Double {
        let sum = row.reduce(0) { $0 + $1.area }
        guard sum > 0, side > 0, let largest = row.map(\.area).max(), let smallest = row.map(\.area).min(), smallest > 0 else {
            return .infinity
        }
        return max(side * side * largest / (sum * sum), sum * sum / (side * side * smallest))
    }
}
