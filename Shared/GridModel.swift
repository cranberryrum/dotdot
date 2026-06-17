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

    static let entries: [Entry] = [
        Entry(color: Color(red: 1.00, green: 0.31, blue: 0.04), prefersDarkText: false), // signal orange
        Entry(color: Color(red: 1.00, green: 0.49, blue: 0.70), prefersDarkText: false), // bubblegum pink
        Entry(color: Color(red: 1.00, green: 0.82, blue: 0.29), prefersDarkText: true),  // butter yellow
        Entry(color: Color(red: 0.33, green: 0.88, blue: 0.65), prefersDarkText: true),  // mint
        Entry(color: Color(red: 0.48, green: 0.61, blue: 1.00), prefersDarkText: false), // periwinkle
    ]

    static func color(at index: Int) -> Color {
        entries.indices.contains(index) ? entries[index].color : entries[0].color
    }

    static let screenBackground = Color(red: 0.043, green: 0.043, blue: 0.055)
    static let boardBackground = Color(red: 0.094, green: 0.094, blue: 0.118)
    static let emptyChip = Color.white.opacity(0.07)
}
