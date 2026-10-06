// A grid of tiles that reports its own geometry.
//
// Every tile is wrapped in ``moqomRenderBox(for:reportingTo:)``, so a grid built
// with this view cannot forget to report a tile's size to the room.
//
// The tile content is the caller's. What is opinionated here is the arrangement
// and the reporting; what a participant looks like is a product decision, and an
// SDK that shipped an avatar with a name label would be wrong in every app that
// used it.

import Foundation
import MoqomCore
import MoqomKit

#if canImport(SwiftUI)
    import SwiftUI

    /// Lays a gallery's occupants out and reports each tile's size to a ``LayoutObserver``.
    ///
    /// ```swift
    /// MoqomGalleryView(gallery: room.gallery, reportingTo: room.layout) { slot in
    ///     ParticipantTile(slot: slot)
    /// }
    /// ```
    public struct MoqomGalleryView<Tile: View>: View {
        private let slots: [Gallery.Slot]
        private let observer: LayoutObserver
        private let aspect: Double
        private let spacing: Double
        private let columns: Int?
        private let tile: (Gallery.Slot) -> Tile

        /// - Parameters:
        ///   - aspect: Tile shape. `16/9` for camera video, `1` for the avatar
        ///     seats of an audio room.
        ///   - columns: How many across, or `nil` to let the arrangement be chosen.
        ///     Naming it is for the layouts a product has decided on: a two-up call, a
        ///     single speaker with everyone else beneath.
        public init(
            slots: [Gallery.Slot],
            reportingTo observer: LayoutObserver,
            aspect: Double = 16.0 / 9.0,
            spacing: Double = 8,
            columns: Int? = nil,
            @ViewBuilder tile: @escaping (Gallery.Slot) -> Tile
        ) {
            self.slots = slots
            self.observer = observer
            self.aspect = aspect
            self.spacing = spacing
            self.columns = columns
            self.tile = tile
        }

        public init(
            gallery: Gallery,
            reportingTo observer: LayoutObserver,
            aspect: Double = 16.0 / 9.0,
            spacing: Double = 8,
            columns: Int? = nil,
            @ViewBuilder tile: @escaping (Gallery.Slot) -> Tile
        ) {
            self.init(
                slots: gallery.slots,
                reportingTo: observer,
                aspect: aspect,
                spacing: spacing,
                columns: columns,
                tile: tile
            )
        }

        public var body: some View {
            GeometryReader { proxy in
                let grid = arrangement(
                    in: (width: proxy.size.width, height: proxy.size.height)
                )
                let size = grid.tile(
                    in: (width: proxy.size.width, height: proxy.size.height),
                    spacing: spacing
                )

                VStack(spacing: spacing) {
                    ForEach(Array(grid.rows(of: slots).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: spacing) {
                            ForEach(row) { slot in
                                tile(slot)
                                    .frame(width: size.width, height: size.height)
                                    .moqomRenderBox(for: slot.identity, reportingTo: observer)
                            }
                        }
                    }
                }
                // A partly filled last row centres rather than stretching: the
                // alternative is a final tile several times the size of the
                // others, which reads as a spotlight nobody asked for.
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }

        /// The grid to lay out in, chosen or given.
        ///
        /// A given column count still derives its rows, and still cannot be fewer than one of
        /// either: a caller asking for three columns in a room of two gets one row of two, not
        /// a row with a hole in it.
        private func arrangement(in size: (width: Double, height: Double)) -> GalleryGrid {
            guard let columns, columns > 0 else {
                return GalleryGrid.fitting(
                    count: slots.count,
                    in: size,
                    aspect: aspect,
                    spacing: spacing
                )
            }
            let across = min(columns, max(1, slots.count))
            return GalleryGrid(
                columns: across,
                rows: Int((Double(slots.count) / Double(across)).rounded(.up))
            )
        }
    }
#endif
