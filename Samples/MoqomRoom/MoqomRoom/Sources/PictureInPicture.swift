import AVFoundation
import MoqomCore
import MoqomKit
import SwiftUI

#if os(iOS)
    struct PictureInPictureSource: UIViewRepresentable {
        let room: RoomModel

        func makeUIView(context _: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            room.pictureInPicture?.source = view
            return view
        }

        func updateUIView(_ view: UIView, context _: Context) {
            room.pictureInPicture?.source = view
        }
    }

    extension View {
        func moqomPictureInPictureSource(_ room: RoomModel) -> some View {
            background { PictureInPictureSource(room: room) }
        }
    }
#else
    extension View {
        func moqomPictureInPictureSource(_: RoomModel) -> some View { self }
    }
#endif

enum CastChoice: String, CaseIterable, Identifiable, Sendable {
    case everyone = "Everyone"
    case host = "Host only"
    case guests = "Cohosts and guests"
    case speaker = "Whoever is talking"

    var id: String { rawValue }

    var cast: PictureInPictureCast {
        switch self {
        case .everyone: .stage
        case .host: .host
        case .guests: .cohostsAndGuests
        case .speaker: .speaker
        }
    }
}
