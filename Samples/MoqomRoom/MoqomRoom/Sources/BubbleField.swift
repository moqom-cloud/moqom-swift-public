import Foundation
import MoqomCore
import MoqomKit

final class BubbleField: SpaceSimulation, @unchecked Sendable {
    enum Field {
        static let reach: Float = 0.55

        static let floor: Float = 0.05
        static let ceiling: Float = 1.35

        static let departure: Float = 2.4

        static let radius: Float = 0.075
    }

    struct Rules: Sendable {
        var capacity = 12

        var spawnEvery = Duration.milliseconds(650)

        var rise: Float = 0.19

        var flight: Float = 0.6

        static let `default` = Rules()
    }

    static let roundLength = Duration.seconds(30)

    private let rules: Rules
    private var sinceSpawn = Duration.zero

    private var stem = ""
    private var minted = 0

    init(rules: Rules = .default) {
        self.rules = rules
    }

    func opening(_ state: inout SpaceSnapshot, at _: Timecode) {
        stem = String(UInt32.random(in: 0 ..< 1_000_000), radix: 36)
        minted = 0
        sinceSpawn = .zero

    }

    func step(_ state: inout SpaceSnapshot, at now: Timecode, since elapsed: Duration) {
        let seconds = Float(elapsed.wholeNanoseconds) / 1_000_000_000
        guard seconds > 0, seconds < 1 else { return }

        let round = Self.round(in: state) ?? begin(1, in: &state, at: now)
        let playing = now.nanoseconds < round.ends

        var gone: [SpaceEntityID] = []
        for (id, entity) in state.entities where entity.kind == Self.kind {
            let leaving = entity.facts[Self.leaving] != nil

            guard playing else {
                if leaving {
                    gone.append(id)
                } else {
                    state.entities[id]?.facts[Self.leaving] = .flag(true)
                }
                continue
            }

            let height = Self.position(of: entity, as: id, at: now).y
            if height > Field.departure, leaving {
                gone.append(id)
                continue
            }

            if height > Field.ceiling, !leaving {
                state.entities[id]?.facts[Self.leaving] = .flag(true)
            }
        }
        for id in gone {
            state.entities.removeValue(forKey: id)
        }

        sinceSpawn += elapsed
        let catchable = state.entities.values.count {
            $0.kind == Self.kind && $0.facts[Self.leaving] == nil
        }
        if playing, sinceSpawn >= rules.spawnEvery, catchable < rules.capacity {
            sinceSpawn = .zero
            release(into: &state, at: now)
        }
    }

    @discardableResult
    private func begin(_ number: Int, in state: inout SpaceSnapshot, at now: Timecode) -> Round {
        for key in state.facts.keys where key.hasPrefix(Self.scorePrefix) {
            state.facts.removeValue(forKey: key)
        }
        let round = Round(
            number: number,
            ends: now.nanoseconds &+ Self.roundLength.wholeNanoseconds
        )
        state.facts[Self.roundNumber] = .number(Int64(number))
        state.facts[Self.roundEnds] = .number(round.ends)
        sinceSpawn = .zero
        return round
    }

    func apply(
        _ intent: SpaceIntent,
        from who: ParticipantIdentity,
        to state: inout SpaceSnapshot,
        at now: Timecode
    ) {
        switch intent.verb {
        case Self.rematch:
            guard
                let round = Self.round(in: state),
                now.nanoseconds >= round.ends
            else { return }
            begin(round.number + 1, in: &state, at: now)
        case Self.pop:
            guard
                let subject = intent.subject,
                state.entities[subject]?.kind == Self.kind
            else {
                return
            }
            state.entities.removeValue(forKey: subject)
            score(who, in: &state)
        default:
            break
        }
    }

    private func release(into state: inout SpaceSnapshot, at now: Timecode) {
        minted += 1
        let id = SpaceEntityID("b-\(stem)-\(minted)")
        let position = SpaceVector(
            x: Float.random(in: -Field.reach ... Field.reach),
            y: Field.floor,
            z: Float.random(in: -Field.reach ... Field.reach)
        )
        state.entities[id] = SpaceEntity(
            id: id,
            kind: Self.kind,
            pose: SpacePose(
                position: position,
                rotation: .identity,
                scale: Float.random(in: 0.75 ... 1.3)
            ),
            facts: [
                Self.hue: .decimal(Double.random(in: 0 ... 1)),
                Self.born: .number(now.nanoseconds),
            ]
        )
    }

    private func score(_ who: ParticipantIdentity, in state: inout SpaceSnapshot) {
        let key = Self.scoreKey(for: who)
        let current: Int64 = if case let .number(value) = state.facts[key] { value } else { 0 }
        state.facts[key] = .number(current + 1)
    }
}

extension BubbleField {
    static let kind = "bubble"

    static let pop = "pop"
    static let rematch = "rematch"

    static let leaving = "leaving"

    static let hue = "hue"
    static let born = "born"

    static let roundNumber = "round"
    static let roundEnds = "round/ends"

    static let scorePrefix = "score/"

    static func scoreKey(for who: ParticipantIdentity) -> String {
        "\(scorePrefix)\(who.username.value)/\(who.device.value)"
    }

    static func standings(in state: SpaceSnapshot) -> [(who: String, score: Int)] {
        state.facts
            .compactMap { key, value -> (String, Int)? in
                guard key.hasPrefix(scorePrefix), case let .number(count) = value else {
                    return nil
                }
                let name = key.dropFirst(scorePrefix.count).prefix { $0 != "/" }
                return (String(name), Int(count))
            }
            .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
            .map { (who: $0.0, score: $0.1) }
    }

    static func bubbles(in state: SpaceSnapshot) -> [SpaceEntity] {
        state.entities.values.filter { $0.kind == kind }
    }

    struct Round: Sendable, Hashable {
        var number: Int

        var ends: Int64
    }

    static func round(in state: SpaceSnapshot) -> Round? {
        guard
            case let .number(number) = state.facts[roundNumber],
            case let .number(ends) = state.facts[roundEnds]
        else { return nil }
        return Round(number: Int(number), ends: ends)
    }

    struct Course: Sendable, Hashable {
        var speed: Float
        var sway: Float
        var phase: Float
    }

    static func course(for id: SpaceEntityID) -> Course {
        let hash = id.rawValue.unicodeScalars.reduce(UInt64(5381)) { $0 &* 33 &+ UInt64($1.value) }
        func unit(_ shift: UInt64) -> Float { Float((hash >> shift) % 1024) / 1024 }
        return Course(
            speed: Rules.default.rise * (0.75 + 0.5 * unit(0)),
            sway: 0.4 + 0.8 * unit(10),
            phase: unit(20) * 2 * .pi
        )
    }

    static func position(
        spawnedAt spawn: SpaceVector,
        as id: SpaceEntityID,
        after seconds: Float
    ) -> SpaceVector {
        let course = course(for: id)
        let age = max(0, seconds)

        let toCeiling = max(0, (Field.ceiling - spawn.y) / course.speed)
        let height: Float
        if age <= toCeiling {
            height = spawn.y + course.speed * age
        } else {
            let over = age - toCeiling
            height = Field.ceiling + course.speed * over
                + 0.5 * Rules.default.flight * over * over
        }

        let phase = course.phase
        return SpaceVector(
            x: spawn.x + course.sway / 1.7 * (cos(1.7 * phase) - cos(1.7 * (phase + age))),
            y: height,
            z: spawn.z + course.sway / 1.1 * (sin(1.1 * (phase + age)) - sin(1.1 * phase))
        )
    }

    static func position(of entity: SpaceEntity, as id: SpaceEntityID, at now: Timecode) -> SpaceVector {
        position(spawnedAt: entity.pose.position, as: id, after: age(of: entity, at: now))
    }

    static func age(of entity: SpaceEntity, at now: Timecode) -> Float {
        guard case let .number(born) = entity.facts[Self.born] else { return 0 }
        let seconds = Float(now.nanoseconds &- born) / 1_000_000_000
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    static func climbTime(spawnedAt spawn: SpaceVector, as id: SpaceEntityID) -> Float {
        max(0, (Field.ceiling - spawn.y) / course(for: id).speed)
    }

    static func lifetime(spawnedAt spawn: SpaceVector, as id: SpaceEntityID) -> Float {
        let course = course(for: id)
        let over = Field.departure - Field.ceiling
        let flight = Rules.default.flight
        let escape = (-course.speed + (course.speed * course.speed + 2 * flight * over).squareRoot())
            / flight
        return climbTime(spawnedAt: spawn, as: id) + escape
    }
}
