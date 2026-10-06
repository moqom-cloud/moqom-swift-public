import MoqomCore
import MoqomKit
import SwiftUI

#if canImport(Metal)
    import Metal
#endif

enum SceneEffect: String, CaseIterable, Identifiable {
    case none
    case smoothing
    case backgroundBlur
    case colourGrade

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No effect"
        case .smoothing: "Skin smoothing"
        case .backgroundBlur: "Background blur"
        case .colourGrade: "Colour grade"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.slash"
        case .smoothing: "wand.and.stars"
        case .backgroundBlur: "person.and.background.dotted"
        case .colourGrade: "camera.filters"
        }
    }
}

@MainActor
@Observable
final class SceneEffectsModel {
    var active: SceneEffect = .none

    #if canImport(Metal)
        func apply(
            _ effect: SceneEffect,
            to texture: any MTLTexture,
            on commandBuffer: any MTLCommandBuffer
        ) {
            guard effect != .none else { return }
            _ = texture
            _ = commandBuffer
        }
    #endif
}

struct SceneEffectsMenu: View {
    @State private var effects = SceneEffectsModel()

    var body: some View {
        Menu {
            Picker("Effect", selection: $effects.active) {
                ForEach(SceneEffect.allCases) { effect in
                    Label(effect.label, systemImage: effect.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .tag(effect)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("Effects", systemImage: effects.active.symbol)
        }
        .menuStyle(.borderlessButton)
    }
}
