#if canImport(ARKit) && !targetEnvironment(simulator)
    import Foundation
    import MoqomCore
    import MoqomKit
    import RealityKit
    import UIKit

    @MainActor
    final class BubbleScene {
        static let tilePlacement = SpaceAnchor(
            origin: SpaceVector(x: 0, y: -0.30, z: -0.55),
            rotation: .identity,
            scale: 0.5
        )

        static let screenPlacement = SpaceAnchor(
            origin: SpaceVector(x: 0, y: -0.70, z: 0),
            rotation: .identity,
            scale: 1.0
        )

        enum OverlayCamera {
            static let distance: Float = 1.35
            static let fieldOfView: Float = 50
        }

        var placement = tilePlacement

        private static let grace = Duration.seconds(1)

        let root = Entity()

        let cameraAnchor = AnchorEntity(.camera)

        func lockToCamera() {
            if root.parent !== cameraAnchor {
                root.removeFromParent()
                cameraAnchor.addChild(root)
            }
        }

        func lockToWorld() {
            root.removeFromParent()
            cameraAnchor.removeFromParent()
            root.components.set(InputTargetComponent())
        }

        var onPop: (@MainActor (SpaceEntityID) -> Void)?

        private var nodes: [SpaceEntityID: ModelEntity] = [:]

        private var guessed: [SpaceEntityID: ContinuousClock.Instant] = [:]

        private var lastPopAt: ContinuousClock.Instant?

        private var leaving: Set<SpaceEntityID> = []

        private var appearing: [SpaceEntityID: ContinuousClock.Instant] = [:]
        private var pulse: FramePulse?
        private var link: CADisplayLink?

        private static let fadeIn: Double = 0.32

        init() {}

        func startPresenting(in _: Scene? = nil) {
            guard link == nil else { return }
            let pulse = FramePulse(scene: self)
            let link = CADisplayLink(target: pulse, selector: #selector(FramePulse.fire))
            let hertz = Float(UIScreen.main.maximumFramesPerSecond)
            if hertz > 0 {
                link.preferredFrameRateRange = CAFrameRateRange(
                    minimum: min(60, hertz),
                    maximum: hertz,
                    preferred: hertz
                )
            }
            link.add(to: .main, forMode: .common)
            self.pulse = pulse
            self.link = link
        }

        func stopPresenting() {
            link?.invalidate()
            link = nil
            pulse = nil
        }

        private final class FramePulse: NSObject, @unchecked Sendable {
            weak var scene: BubbleScene?
            init(scene: BubbleScene) { self.scene = scene }
            @objc func fire(_ link: CADisplayLink) {
                let scene = scene
                MainActor.assumeIsolated { scene?.present() }
            }
        }

        func apply(_ state: SpaceSnapshot, _ delta: SpaceDelta, at time: Timecode) {
            for (id, facts) in delta.entityFacts where facts[BubbleField.leaving] != nil {
                leaving.insert(id)
            }
            for entity in delta.spawned where entity.kind == BubbleField.kind {
                add(entity, at: time)
            }
            for id in delta.removed {
                remove(id)
                leaving.remove(id)
                guessed.removeValue(forKey: id)
            }

            reconcile(with: state, at: time)
        }

        func forget() {
            for node in nodes.values { node.removeFromParent() }
            nodes.removeAll()
            appearing.removeAll()
            guessed.removeAll()
            leaving.removeAll()
        }

        func clear() {
            stopPresenting()
            for node in nodes.values { node.removeFromParent() }
            nodes.removeAll()
            appearing.removeAll()
            guessed.removeAll()
            leaving.removeAll()
        }

        @discardableResult
        func pop(at point: CGPoint, in view: ARView) -> Bool {
            guard let hit = view.entity(at: point) else { return false }
            return pop(hitting: hit)
        }

        @discardableResult
        func pop(at point: CGPoint, in size: CGSize) -> Bool {
            let depthToPlane = OverlayCamera.distance
            let halfHeight = tan(OverlayCamera.fieldOfView * .pi / 360)
            let aspect = Float(size.width / max(size.height, 1))
            let halfWidth = halfHeight * aspect
            let finger = max(44 as CGFloat, 1)

            var best: (SpaceEntityID, CGFloat)?
            for (id, node) in nodes {
                let world = node.position(relativeTo: nil)
                let depth = depthToPlane - world.z
                guard depth > 0.05 else { continue }
                let screen = CGPoint(
                    x: CGFloat(world.x / (depth * halfWidth) * 0.5 + 0.5) * size.width,
                    y: CGFloat(-world.y / (depth * halfHeight) * 0.5 + 0.5) * size.height
                )
                let radius = CGFloat(
                    BubbleField.Field.radius * placement.scale / depth
                        * Float(size.height) / (2 * halfHeight)
                )
                let dx = point.x - screen.x
                let dy = point.y - screen.y
                let distance = (dx * dx + dy * dy).squareRoot()
                guard distance <= max(radius * 1.8, finger) else { continue }
                if best == nil || distance < best!.1 {
                    best = (id, distance)
                }
            }
            guard let id = best?.0 else { return false }
            return commitPop(id)
        }

        @discardableResult
        func pop(hitting entity: Entity) -> Bool {
            var candidate: Entity? = entity
            while let current = candidate {
                let id = SpaceEntityID(current.name)
                if nodes[id] != nil {
                    return commitPop(id)
                }
                candidate = current.parent
            }
            return false
        }

        private func add(_ entity: SpaceEntity, at time: Timecode) {
            if entity.facts[BubbleField.leaving] != nil { leaving.insert(entity.id) }
            guard nodes[entity.id] == nil else { return }
            let hue: Double = if case let .decimal(value) = entity.facts[BubbleField.hue] {
                value
            } else {
                0.5
            }
            let node = ModelEntity(
                mesh: .generateSphere(radius: BubbleField.Field.radius),
                materials: [
                    SimpleMaterial(
                        color: UIColor(
                            hue: CGFloat(hue),
                            saturation: 0.75,
                            brightness: 1,
                            alpha: 1
                        ),
                        roughness: 0.08,
                        isMetallic: false
                    ),
                ]
            )
            node.name = entity.id.rawValue
            let age = min(
                BubbleField.age(of: entity, at: time),
                BubbleField.climbTime(spawnedAt: entity.pose.position, as: entity.id)
            )
            var placed = entity.pose
            placed.position = BubbleField.position(
                spawnedAt: entity.pose.position, as: entity.id, after: age
            )
            node.transform = transform(for: placed)
            var collision = CollisionComponent(
                shapes: [.generateSphere(radius: BubbleField.Field.radius * 1.8)]
            )
            collision.filter = CollisionFilter(group: [], mask: [])
            node.components.set(collision)
            node.components.set(InputTargetComponent())
            root.addChild(node)
            nodes[entity.id] = node
            appearing[entity.id] = .now
            node.components.set(OpacityComponent(opacity: 0))
            climb(node, entity, from: age)
        }

        private func climb(_ node: ModelEntity, _ entity: SpaceEntity, from age: Float) {
            let spawn = entity.pose.position
            let remaining = BubbleField.lifetime(spawnedAt: spawn, as: entity.id) - age
            guard remaining > 0.05 else { return }

            let interval: Float = 1.0 / 30
            let steps = max(2, Int(ceil(remaining / interval)))
            var frames: [Transform] = []
            frames.reserveCapacity(steps + 1)
            for step in 0 ... steps {
                var pose = entity.pose
                pose.position = BubbleField.position(
                    spawnedAt: spawn, as: entity.id, after: age + Float(step) * interval
                )
                frames.append(transform(for: pose))
            }

            let animation = SampledAnimation(
                frames: frames,
                name: "climb",
                tweenMode: .linear,
                frameInterval: interval,
                bindTarget: .transform
            )
            guard let resource = try? AnimationResource.generate(with: animation) else { return }
            node.playAnimation(resource)
        }

        private func remove(_ id: SpaceEntityID) {
            appearing.removeValue(forKey: id)
            guard let node = nodes.removeValue(forKey: id) else { return }
            if leaving.remove(id) != nil {
                node.removeFromParent()
            } else {
                vanish(node)
            }
        }

        private func vanish(_ node: ModelEntity) {
            let parent = node.parent
            node.transform = Transform(
                scale: node.scale(relativeTo: parent),
                rotation: node.orientation(relativeTo: parent),
                translation: node.position(relativeTo: parent)
            )
            node.stopAllAnimations()
            var swollen = node.transform
            swollen.scale *= 3.2
            node.move(to: swollen, relativeTo: parent, duration: 0.18)
            thin(node)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(190))
                node.removeFromParent()
            }
        }

        private func thin(_ node: ModelEntity) {
            guard var model = node.model else { return }
            model.materials = model.materials.map { material in
                guard let simple = material as? SimpleMaterial else { return material }
                var faded = simple
                faded.color = .init(tint: simple.color.tint.withAlphaComponent(0.22))
                return faded
            }
            node.model = model
        }

        private func commitPop(_ id: SpaceEntityID) -> Bool {
            let now = ContinuousClock.now
            if let last = lastPopAt, now - last < .milliseconds(80) { return false }
            lastPopAt = now
            burst(id)
            onPop?(id)
            return true
        }

        private func burst(_ id: SpaceEntityID) {
            appearing.removeValue(forKey: id)
            guard let node = nodes.removeValue(forKey: id) else { return }
            guessed[id] = ContinuousClock.now
            vanish(node)
        }

        private func reconcile(with state: SpaceSnapshot, at time: Timecode) {
            let now = ContinuousClock.now
            for entity in BubbleField.bubbles(in: state) {
                if let guessedAt = guessed[entity.id] {
                    guard now - guessedAt > Self.grace else { continue }
                    guessed.removeValue(forKey: entity.id)
                }
                add(entity, at: time)
            }

            for id in nodes.keys where state.entities[id] == nil {
                remove(id)
            }
        }

        private func present() {
            for (id, node) in nodes {
                guard let born = appearing[id] else { continue }
                let elapsed = Double((ContinuousClock.now - born).wholeNanoseconds)
                    / 1_000_000_000
                let fade = Float(min(1, elapsed / Self.fadeIn))
                let eased = 1 - (1 - fade) * (1 - fade)
                node.components.set(OpacityComponent(opacity: eased))
                if fade >= 1 { appearing.removeValue(forKey: id) }
            }
        }

        private func transform(for pose: SpacePose) -> Transform {
            let placed = placement.world(from: pose)
            return Transform(
                scale: SIMD3(repeating: placed.scale),
                rotation: simd_quatf(
                    ix: placed.rotation.x,
                    iy: placed.rotation.y,
                    iz: placed.rotation.z,
                    r: placed.rotation.w
                ),
                translation: SIMD3(placed.position.x, placed.position.y, placed.position.z)
            )
        }

    }
#endif
