#if canImport(ARKit) && !targetEnvironment(simulator)
    import RealityKit
    import SwiftUI

    struct BubbleOverlayView: View {
        let field: BubbleScene

        var body: some View {
            GeometryReader { proxy in
                RealityView { content in
                    content.camera = .virtual
                    installCamera(in: &content)
                    field.lockToWorld()
                    content.add(field.root)
                    light(field)
                    field.startPresenting()
                } update: { content in
                    content.camera = .virtual
                    if field.root.parent == nil {
                        field.lockToWorld()
                        content.add(field.root)
                    }
                    field.startPresenting()
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .gesture(
                    SpatialTapGesture()
                        .targetedToAnyEntity()
                        .onEnded { value in
                            field.pop(hitting: value.entity)
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { event in
                            field.pop(at: event.location, in: proxy.size)
                        }
                )
            }
        }

        private func installCamera(in content: inout RealityViewCameraContent) {
            guard !content.entities.contains(where: { $0 is PerspectiveCamera }) else { return }
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = BubbleScene.OverlayCamera.fieldOfView
            camera.look(
                at: [0, 0, 0],
                from: [0, 0, BubbleScene.OverlayCamera.distance],
                relativeTo: nil
            )
            content.add(camera)
        }

        private func light(_ field: BubbleScene) {
            guard !field.root.children.contains(where: { $0 is DirectionalLight }) else { return }
            let light = DirectionalLight()
            light.light.intensity = 2600
            light.look(at: [0, 0, 0], from: [0.4, 0.6, 1.0], relativeTo: nil)
            field.root.addChild(light)
        }
    }
#endif
