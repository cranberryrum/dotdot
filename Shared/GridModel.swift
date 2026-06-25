//
//  GridModel.swift
//  Dot Grid
//
//  Shared between the app and the widget extension.
//

import SwiftUI

enum ChipSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// Fraction of the cell the rendered chip fills.
    var scale: CGFloat {
        switch self {
        case .small: 0.45
        case .medium: 0.68
        case .large: 0.92
        }
    }
}

struct Cell: Codable, Equatable {
    var colorIndex: Int
    var size: ChipSize
}

struct Grid: Codable, Equatable {
    /// Dots per side (8 or 12). Stored on the grid so a saved/sent canvas carries
    /// its own shape — the recipient and widget render it at the right size.
    var side: Int

    /// Row-major, exactly `side * side` entries. `nil` means an empty cell.
    var cells: [Cell?]

    /// The default canvas size for a fresh grid.
    static let defaultSide = 8

    init(side: Int = defaultSide, cells: [Cell?]) {
        self.side = side
        self.cells = cells
    }

    /// An empty grid of the given size.
    static func empty(side: Int) -> Grid {
        Grid(side: side, cells: Array(repeating: nil, count: side * side))
    }

    /// A default (8×8) empty grid — fallback / placeholder.
    static let empty = Grid.empty(side: defaultSide)

    var isEmpty: Bool { cells.allSatisfy { $0 == nil } }

    subscript(row: Int, column: Int) -> Cell? {
        get { cells[row * side + column] }
        set { cells[row * side + column] = newValue }
    }

    // Tolerant decode: grids saved/sent before the size option carried no `side`,
    // so infer it from the (square) cell count and fall back to the default.
    enum CodingKeys: String, CodingKey { case side, cells }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = (try? c.decode([Cell?].self, forKey: .cells)) ?? []
        cells = decoded
        if let s = try? c.decode(Int.self, forKey: .side), s > 0 {
            side = s
        } else {
            let inferred = Int(Double(decoded.count).squareRoot().rounded())
            side = inferred > 0 ? inferred : Self.defaultSide
        }
    }

    /// Heart pattern shown in the widget gallery before anything is sent.
    static let sample: Grid = {
        let art = [
            "........",
            ".XX..XX.",
            "XXXXXXXX",
            "XXXXXXXX",
            ".XXXXXX.",
            "..XXXX..",
            "...XX...",
            "........",
        ]
        var grid = Grid.empty(side: 8)
        for (row, line) in art.enumerated() {
            for (column, character) in line.enumerated() where character == "X" {
                grid[row, column] = Cell(colorIndex: 0, size: .medium)
            }
        }
        return grid
    }()
}

enum Palette {
    struct Entry {
        let color: Color
        let prefersDarkText: Bool
    }

    /// The loud chrome palette — what dots light up in (picked in the composer).
    static let entries: [Entry] = [
        Entry(color: Theme.blue,   prefersDarkText: false),
        Entry(color: Theme.pink,   prefersDarkText: false),
        Entry(color: Theme.lime,   prefersDarkText: true),
        Entry(color: Theme.red,    prefersDarkText: false),
        Entry(color: Theme.yellow, prefersDarkText: true),
        Entry(color: Theme.mint,   prefersDarkText: true),
        Entry(color: Theme.peri,   prefersDarkText: false),
        Entry(color: Theme.cream,  prefersDarkText: true),
    ]

    static func color(at index: Int) -> Color {
        entries.indices.contains(index) ? entries[index].color : entries[0].color
    }

    static let screenBackground = Theme.ink     // app / editor background
    static let boardBackground = Theme.panel    // grid panel surface
    static let emptyChip = Theme.cellOff        // empty dot fill
    static let cellRim = Theme.cellRim          // rim around empty dots
}
