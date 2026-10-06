import MoqomKit
import MoqomUI
import SwiftUI
import Testing

@Suite("Gallery view")
struct GalleryViewTests {
    @Test("a grid has room for every tile")
    func gridFits() {
        for count in 1...12 {
            let grid = GalleryGrid.fitting(
                count: count,
                in: (width: 1170, height: 2532),
                aspect: 16.0 / 9.0,
                spacing: 8
            )
            #expect(grid.columns * grid.rows >= count)
        }
    }

    @Test("rows hold the slots in order")
    func rowsInOrder() {
        let grid = GalleryGrid(columns: 2, rows: 2)
        #expect(grid.rows(of: [1, 2, 3]) == [[1, 2], [3]])
    }

    @MainActor
    @Test("the view builds over an empty gallery")
    func buildsEmpty() {
        let view = MoqomGalleryView(
            gallery: Gallery(),
            reportingTo: LayoutObserver()
        ) { slot in
            Text(String(describing: slot.identity))
        }
        _ = view.body
    }
}
