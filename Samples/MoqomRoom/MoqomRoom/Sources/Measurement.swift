import Foundation
import MoqomCore
import MoqomKit

struct TimedSource: FrameSource {
    static let slewLimit = 200.0 / 1_000_000.0

    static let windowSeconds = 4.0
    private let wrapped: any FrameSource
    private let stamp: @Sendable () -> Timecode
    private let floor: @Sendable () -> Double?

    init(
        _ wrapped: any FrameSource,
        stamp: @escaping @Sendable () -> Timecode,
        floor: @escaping @Sendable () -> Double? = { nil }
    ) {
        self.wrapped = wrapped
        self.stamp = stamp
        self.floor = floor
    }

    var captureFormat: CaptureFormat { wrapped.captureFormat }

    func frames() -> AsyncStream<VideoFrame> {
        let upstream = wrapped.frames()
        let stamp = stamp
        return AsyncStream { continuation in
            let pump = Task {
                var offset: Int64?
                var settling = 0
                var tracker = OffsetTracker()

                var floorNanoseconds: Int64 = 0
                var floorTaken = false

                for await frame in upstream {
                    let captured = Int64(bitPattern: frame.timestamp.nanoseconds)
                    let now = stamp().nanoseconds

                    if captured > 0 {
                        let candidate = now - captured
                        switch offset {
                        case .none:
                            offset = candidate

                        case let .some(current) where settling < 60:
                            offset = min(current, candidate)
                            tracker.observe(candidate, at: captured)

                        case let .some(current):
                            if abs(candidate - current) > 250_000_000 {
                                offset = candidate
                                tracker.reset()
                            } else {
                                tracker.observe(candidate, at: captured)
                                offset = tracker.slewed(current, to: captured)
                            }
                        }
                        settling += 1

                        if !floorTaken, settling >= 60 {
                            floorTaken = true
                            floorNanoseconds = floor().map { Int64($0 * 1_000_000) } ?? 0
                        }
                    }

                    let shared = offset.map { captured + $0 - floorNanoseconds } ?? now

                    continuation.yield(
                        VideoFrame(
                            timestamp: FrameTimestamp(nanoseconds: UInt64(max(0, shared))),
                            size: frame.size,
                            surface: frame.surface
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func stop() { wrapped.stop() }

    func suspend() { wrapped.suspend() }
    func resume() { wrapped.resume() }
}

struct OffsetTracker {
    private var buckets: [(second: Int64, minimum: Int64)] = []
    private var last: Int64?

    mutating func observe(_ candidate: Int64, at captured: Int64) {
        let second = captured / 1_000_000_000
        if let latest = buckets.last, latest.second == second {
            buckets[buckets.count - 1].minimum = min(latest.minimum, candidate)
        } else {
            buckets.append((second: second, minimum: candidate))
        }
        let oldest = second - Int64(TimedSource.windowSeconds)
        buckets.removeAll { $0.second < oldest }
    }

    mutating func slewed(_ current: Int64, to captured: Int64) -> Int64 {
        defer { last = captured }
        guard let target = buckets.map(\.minimum).min(), let previous = last else { return current }

        let elapsed = Double(max(0, captured - previous)) / 1_000_000_000
        let limit = Int64(elapsed * TimedSource.slewLimit * 1_000_000_000)
        return min(max(target, current - limit), current + limit)
    }

    mutating func reset() {
        buckets.removeAll()
        last = nil
    }
}

struct TimedAudioSource: AudioSource {
    private let wrapped: any AudioSource
    private let stamp: @Sendable () -> Timecode

    init(_ wrapped: any AudioSource, stamp: @escaping @Sendable () -> Timecode) {
        self.wrapped = wrapped
        self.stamp = stamp
    }

    var format: AudioFormat { wrapped.format }

    func frames() -> AsyncStream<AudioFrame> {
        let upstream = wrapped.frames()
        let stamp = stamp
        return AsyncStream { continuation in
            let pump = Task {
                var offset: Int64?
                var settling = 0
                var tracker = OffsetTracker()

                for await frame in upstream {
                    let captured = Int64(bitPattern: frame.timestamp.nanoseconds)
                    let now = stamp().nanoseconds

                    if captured > 0 {
                        let candidate = now - captured
                        tracker.observe(candidate, at: captured)
                        if let current = offset, settling >= 50 {
                            offset = tracker.slewed(current, to: captured)
                        } else if let current = offset {
                            offset = min(current, candidate)
                        } else {
                            offset = candidate
                        }
                        settling += 1
                    }

                    let shared = offset.map { captured + $0 } ?? now
                    continuation.yield(
                        AudioFrame(
                            timestamp: FrameTimestamp(nanoseconds: UInt64(max(0, shared))),
                            format: frame.format,
                            samples: frame.samples
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in pump.cancel() }
        }
    }

    func stop() { wrapped.stop() }
    func suspend() { wrapped.suspend() }
    func resume() { wrapped.resume() }
}

final class LatencyMeter: @unchecked Sendable {
    private let lock = NSLock()

    private var samples: [Double] = []
    private var cursor = 0
    private static let window = 900

    private var worstEver = 0.0

    private var frames = 0

    private var uncertainty = 0.0

    private var latest = 0.0

    private var impossible = 0

    private var beyondBelief = 0

    private static let believable = 10_000.0

    func record(capturedAt captured: FrameTimestamp, receivedAt received: Timecode) {
        let milliseconds =
            (Double(received.nanoseconds) - Double(captured.nanoseconds)) / 1_000_000
        let bound = Double(received.uncertainty.components.attoseconds) / 1e15
            + Double(received.uncertainty.components.seconds) * 1000

        lock.withLock {
            frames += 1
            uncertainty = max(uncertainty, bound)
            latest = bound
            if milliseconds < 0 {
                impossible += 1
            } else if milliseconds > Self.believable {
                beyondBelief += 1
            } else {
                worstEver = max(worstEver, milliseconds)
                if samples.count < Self.window {
                    samples.append(milliseconds)
                } else {
                    samples[cursor] = milliseconds
                    cursor = (cursor + 1) % Self.window
                }
            }
        }
    }

    struct Reading: Sendable {
        var frames: Int

        var median: Double
        var p95: Double
        var p99: Double
        var worst: Double

        var uncertainty: Double

        var currentUncertainty: Double

        var impossible: Int

        var beyondBelief: Int

        var isUsable: Bool { frames > 0 && impossible == 0 && beyondBelief == 0 }
    }

    func reading() -> Reading? {
        let (sorted, frames, uncertainty, latest, impossible, beyondBelief, worstEver) = lock
            .withLock {
                (
                    samples.sorted(), self.frames, self.uncertainty, self.latest,
                    self.impossible, self.beyondBelief, self.worstEver
                )
            }
        guard !sorted.isEmpty else {
            guard frames > 0 else { return nil }
            return Reading(
                frames: frames,
                median: 0, p95: 0, p99: 0, worst: 0,
                uncertainty: uncertainty,
                currentUncertainty: latest,
                impossible: impossible,
                beyondBelief: beyondBelief
            )
        }

        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        return Reading(
            frames: frames,
            median: percentile(0.5),
            p95: percentile(0.95),
            p99: percentile(0.99),
            worst: worstEver,
            uncertainty: uncertainty,
            currentUncertainty: latest,
            impossible: impossible,
            beyondBelief: beyondBelief
        )
    }

    func report() -> String {
        guard let reading = reading(), reading.median > 0 || reading.frames > 0 else {
            return "latency frames=0 no usable samples"
        }

        guard reading.worst > 0 else {
            return "latency frames=\(reading.frames) no usable samples"
                + (reading.impossible > 0
                    ? ", \(reading.impossible) before capture — clocks disagree" : "")
        }

        var line = String(
            format: "latency frames=%d p50=%.1f p95=%.1f p99=%.1f max=%.1f ms ±%.1f now±%.1f",
            reading.frames,
            reading.median,
            reading.p95,
            reading.p99,
            reading.worst,
            reading.uncertainty,
            reading.currentUncertainty
        )
        if reading.impossible > 0 { line += " (\(reading.impossible) before capture)" }
        if reading.beyondBelief > 0 {
            line += " (\(reading.beyondBelief) discarded, publisher's clock stepped)"
        }
        return line
    }
}

final class TimelineMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var gaps: [Double] = []
    private var cursor = 0
    private static let window = 900
    private var previous: UInt64?

    func record(stamp: UInt64) {
        lock.withLock {
            defer { previous = stamp }
            guard let previous, stamp > previous else { return }
            let milliseconds = Double(stamp - previous) / 1_000_000
            if gaps.count < Self.window {
                gaps.append(milliseconds)
            } else {
                gaps[cursor] = milliseconds
                cursor = (cursor + 1) % Self.window
            }
        }
    }

    func report() -> String? {
        let sorted = lock.withLock { gaps.sorted() }
        guard !sorted.isEmpty else { return nil }

        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        let median = percentile(0.5)
        return String(
            format: "stamp p50=%.1f p95=%.1f max=%.1f ms uneven=%.1fx",
            median,
            percentile(0.95),
            sorted[sorted.count - 1],
            median > 0 ? percentile(0.95) / median : 0
        )
    }
}

final class CadenceMeter: @unchecked Sendable {
    private let lock = NSLock()

    private var gaps: [Double] = []
    private var cursor = 0
    private static let window = 900

    private var frames = 0
    private var previous: ContinuousClock.Instant?
    private var first: ContinuousClock.Instant?
    private var last: ContinuousClock.Instant?

    private var freezes = 0
    private var frozen = 0.0

    private var freezesOnKeyFrame = 0
    private var stallPeriods: [Double] = []
    private var previousStall: ContinuousClock.Instant?

    private static let freezeThreshold = 150.0

    private static let clump = 5.0

    private static let settle = Duration.seconds(1)

    private var pictured: ContinuousClock.Instant?

    private var flowing = false

    func restart() {
        lock.withLock {
            previous = nil
            pictured = nil
            flowing = false
        }
    }

    func record(at instant: ContinuousClock.Instant = .now, keyFrame: Bool = false) {
        lock.withLock {
            frames += 1
            if first == nil { first = instant }
            if pictured == nil { pictured = instant }
            last = instant
            defer { previous = instant }

            guard let previous else { return }
            let milliseconds = Double(
                (instant - previous).components.attoseconds
            ) / 1e15 + Double((instant - previous).components.seconds) * 1000

            if milliseconds >= Self.clump, milliseconds < Self.freezeThreshold {
                flowing = true
            }

            if milliseconds >= Self.freezeThreshold {
                let settled = pictured.map { instant - $0 >= Self.settle } ?? false
                if flowing, settled {
                    freezes += 1
                    frozen += milliseconds
                    if keyFrame { freezesOnKeyFrame += 1 }
                    if let previousStall {
                        let apart = Double((instant - previousStall).components.seconds)
                            + Double((instant - previousStall).components.attoseconds) / 1e18
                        stallPeriods.append(apart)
                    }
                    previousStall = instant
                } else {
                    return
                }
            }

            if gaps.count < Self.window {
                gaps.append(milliseconds)
            } else {
                gaps[cursor] = milliseconds
                cursor = (cursor + 1) % Self.window
            }
        }
    }

    struct Reading: Sendable {
        var frames: Int

        var rate: Double

        var median: Double
        var p95: Double
        var worst: Double

        var freezes: Int

        var frozen: Double

        var onKeyFrame: Int

        var period: Double

        var since: Double

        var unevenness: Double { median > 0 ? p95 / median : 0 }
    }

    func reading() -> Reading? {
        let snapshot = lock.withLock {
            () -> (
                gaps: [Double], frames: Int, rate: Double, freezes: Int, frozen: Double,
                onKey: Int, period: Double, since: Double
            ) in
            let periods = stallPeriods.sorted()
            let typical = periods.isEmpty
                ? 0
                : periods[periods.count / 2]
            let waiting = last.map { seconds(since: $0) } ?? 0
            guard let first, let last, frames > 1 else {
                return (gaps.sorted(), frames, 0, freezes, 0, freezesOnKeyFrame, typical, waiting)
            }
            let span = Double((last - first).components.seconds)
                + Double((last - first).components.attoseconds) / 1e18

            let elapsed = gaps.reduce(0, +) / 1000
            return (
                gaps.sorted(),
                frames,
                elapsed > 0 ? Double(gaps.count) / elapsed : 0,
                freezes,
                span > 0 ? (frozen / 1000) / span : 0,
                freezesOnKeyFrame,
                typical,
                waiting
            )
        }
        let sorted = snapshot.gaps

        guard !sorted.isEmpty else { return nil }

        func percentile(_ fraction: Double) -> Double {
            sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
        }

        return Reading(
            frames: snapshot.frames,
            rate: snapshot.rate,
            median: percentile(0.5),
            p95: percentile(0.95),
            worst: sorted[sorted.count - 1],
            freezes: snapshot.freezes,
            frozen: snapshot.frozen,
            onKeyFrame: snapshot.onKey,
            period: snapshot.period,
            since: snapshot.since
        )
    }

    func report() -> String {
        guard let reading = reading() else { return "cadence frames=0" }
        return String(
            format: "cadence fps=%.1f gap p50=%.1f p95=%.1f max=%.1f ms uneven=%.1fx"
                + " freezes=%d frozen=%.1f%% onkey=%d every=%.1fs",
            reading.rate,
            reading.median,
            reading.p95,
            reading.worst,
            reading.unevenness,
            reading.freezes,
            reading.frozen * 100,
            reading.onKeyFrame,
            reading.period
        )
            + (reading.since > 1
                ? String(format: " · NOTHING FOR %.1fs", reading.since)
                : "")
    }

    private func seconds(since instant: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - instant
        return Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
    }
}

final class BurstMeter: @unchecked Sendable {
    private let lock = NSLock()

    private var wire: [Double] = []

    private var trips: [Double] = []

    private var outstanding: [SpaceEntityID: ContinuousClock.Instant] = [:]

    private var bubbles: [SpaceEntityID: Bool] = [:]

    private var bursts = 0
    private var departures = 0

    private var untimed = 0

    private var impossible = 0

    func askedFor(_ id: SpaceEntityID, at instant: ContinuousClock.Instant = .now) {
        lock.withLock { outstanding[id] = instant }
    }

    func observe(
        _ delta: SpaceDelta,
        in state: SpaceSnapshot,
        simulated: Timecode,
        now: Timecode,
        arrived: ContinuousClock.Instant = .now
    ) {
        lock.withLock {
            for id in delta.removed {
                guard let wasLeaving = bubbles[id] else { continue }
                guard !wasLeaving else {
                    departures += 1
                    continue
                }
                bursts += 1

                if let asked = outstanding.removeValue(forKey: id) {
                    trips.append(Self.milliseconds(from: asked, to: arrived))
                }

                guard simulated.isTrusted, now.isTrusted else {
                    untimed += 1
                    continue
                }
                let lag = Double(now.nanoseconds - simulated.nanoseconds) / 1_000_000
                guard lag >= 0 else {
                    impossible += 1
                    continue
                }
                wire.append(lag)
            }

            bubbles = state.entities.reduce(into: [:]) { known, entry in
                guard entry.value.kind == BubbleField.kind else { return }
                known[entry.key] = entry.value.facts[BubbleField.leaving] != nil
            }
        }
    }

    func report() -> String? {
        let (wire, trips, bursts, departures, untimed, impossible, awaiting) = lock
            .withLock {
                (
                    self.wire.sorted(), self.trips.sorted(), self.bursts, self.departures,
                    self.untimed, self.impossible, self.outstanding.count
                )
            }
        guard bursts > 0 || departures > 0 || awaiting > 0 else { return nil }

        func quote(_ name: String, _ sorted: [Double]) -> String {
            guard !sorted.isEmpty else { return "" }
            func percentile(_ fraction: Double) -> Double {
                sorted[Int((Double(sorted.count - 1) * fraction).rounded())]
            }
            return String(
                format: " %@ p50=%.1f p95=%.1f max=%.1f ms",
                name,
                percentile(0.5),
                percentile(0.95),
                sorted[sorted.count - 1]
            )
        }

        return "bursts=\(bursts)"
            + quote("wire", wire)
            + " · mine=\(trips.count)"
            + quote("trip", trips)
            + " · away=\(departures)"
            + (awaiting > 0 ? " awaiting=\(awaiting)" : "")
            + (untimed > 0 ? " · untimed=\(untimed)" : "")
            + (impossible > 0 ? " · before-they-happened=\(impossible)" : "")
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let elapsed = end - start
        return Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
    }
}
