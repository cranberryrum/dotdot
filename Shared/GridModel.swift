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
    static let side = 8

    /// Row-major, exactly `side * side` entries. `nil` means an empty cell.
    var cells: [Cell?]

    static let empty = Grid(cells: Array(repeating: nil, count: side * side))

    var isEmpty: Bool { cells.allSatisfy { $0 == nil } }

    subscript(row: Int, column: Int) -> Cell? {
        get { cells[row * Self.side + column] }
        set { cells[row * Self.side + column] = newValue }
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
        var grid = Grid.empty
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
