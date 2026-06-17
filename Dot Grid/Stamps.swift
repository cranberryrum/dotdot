//
//  Stamps.swift
//  Dot Grid
//
//  Curated starting patterns the user can drop onto the board and then edit.
//  A stamp is a base, not a finished message — applying one never sends.
//

import Foundation

/// A curated 8x8 starting pattern. Authored as string art for legibility;
/// `points` exposes the filled cell coordinates that map straight onto the grid.
struct Stamp: Identifiable {
    var id: String { name }
    let name: String
    let rows: [String]

    /// Filled (row, column) coordinates, in row-major reading order.
    var points: [(row: Int, col: Int)] {
        var result: [(row: Int, col: Int)] = []
        for (r, line) in rows.enumerated() {
            for (c, character) in line.enumerated() where character == "X" {
                result.append((row: r, col: c))
            }
        }
        return result
    }

    /// A full `Grid` for this stamp, used to render the tray thumbnails.
    func grid(colorIndex: Int, size: ChipSize) -> Grid {
        var g = Grid.empty
        for point in points {
            g[point.row, point.col] = Cell(colorIndex: colorIndex, size: size)
        }
        return g
    }
}

enum Stamps {
    /// Hand-tuned to read clearly at 8x8. `X` = filled, `.` = empty.
    static let all: [Stamp] = [
        Stamp(name: "Heart", rows: [
            ".XX..XX.",
            "XXXXXXXX",
            "XXXXXXXX",
            ".XXXXXX.",
            "..XXXX..",
            "...XX...",
            "........",
            "........",
        ]),
        Stamp(name: "Smiley", rows: [
            ".XXXXXX.",
            "XXXXXXXX",
            "XX.XX.XX",
            "XXXXXXXX",
            "X......X",
            "XX....XX",
            "XXX..XXX",
            ".XXXXXX.",
        ]),
        Stamp(name: "Star", rows: [
            "...XX...",
            "...XX...",
            ".XXXXXX.",
            "XXXXXXXX",
            ".XXXXXX.",
            "..XXXX..",
            ".XX..XX.",
            "XX....XX",
        ]),
        Stamp(name: "Sun", rows: [
            "...XX...",
            "X..XX..X",
            ".XXXXXX.",
            "XXXXXXXX",
            "XXXXXXXX",
            ".XXXXXX.",
            "X..XX..X",
            "...XX...",
        ]),
        Stamp(name: "Arrow", rows: [
            "...XX...",
            "..XXXX..",
            ".XXXXXX.",
            "XXXXXXXX",
            "...XX...",
            "...XX...",
            "...XX...",
            "...XX...",
        ]),
        Stamp(name: "Hi", rows: [
            "X.X.XXX.",
            "X.X..X..",
            "X.X..X..",
            "XXX..X..",
            "X.X..X..",
            "X.X..X..",
            "X.X.XXX.",
            "........",
        ]),
        Stamp(name: "Check", rows: [
            ".......X",
            "......XX",
            ".....XX.",
            "X...XX..",
            "XX.XX...",
            ".XXXX...",
            "..XX....",
            "........",
        ]),
        Stamp(name: "Diamond", rows: [
            "...XX...",
            "..XXXX..",
            ".XXXXXX.",
            "XXXXXXXX",
            ".XXXXXX.",
            "..XXXX..",
            "...XX...",
            "........",
        ]),
    ]
}
