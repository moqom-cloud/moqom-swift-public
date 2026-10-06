import Foundation
import MoqomCore
import MoqomKit
import Testing

@testable import MoqomRoom

@Suite("Burst meter")
struct BurstMeterTests {

    @Test("a bubble that vanishes without warning is a burst")
    func aPopIsABurst() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(140)
        )

        #expect(meter.report()?.contains("bursts=1") == true)
    }

    @Test("a bubble flagged as leaving got away, and is not a burst")
    func aDepartureIsNotABurst() {
        let meter = BurstMeter()
        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1", leaving: true)),
            simulated: at(0),
            now: at(0)
        )

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(140)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=0") == true)
        #expect(report?.contains("away=1") == true)
    }

    @Test("the final whistle clears the field without bursting any of it")
    func theWhistleIsNotAFlurryOfScoring() {
        let meter = BurstMeter()
        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1"), bubble("b-2"), bubble("b-3")),
            simulated: at(0),
            now: at(0)
        )
        meter.observe(
            SpaceDelta(),
            in: field(
                bubble("b-1", leaving: true),
                bubble("b-2", leaving: true),
                bubble("b-3", leaving: true)
            ),
            simulated: at(50),
            now: at(60)
        )

        meter.observe(
            SpaceDelta(removed: ["b-1", "b-2", "b-3"]),
            in: field(),
            simulated: at(100),
            now: at(110)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=0") == true)
        #expect(report?.contains("away=3") == true)
    }

    @Test("a removal of something that was never a bubble is not a burst")
    func onlyBubblesCount() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["something-else"]),
            in: field(),
            simulated: at(100),
            now: at(140)
        )

        #expect(meter.report() == nil)
    }

    @Test("a run with no field says nothing at all")
    func silentUntilSomethingHappens() {
        #expect(BurstMeter().report() == nil)
    }

    @Test("the wire figure is the gap between simulating a burst and applying it")
    func wireIsTheArrivalLag() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(1000),
            now: at(1042)
        )

        #expect(meter.report()?.contains("wire p50=42.0") == true)
    }

    @Test("a pop this device asked for is timed from the asking to the bubble being gone")
    func ownPopIsARoundTrip() {
        let meter = BurstMeter()
        let tapped = ContinuousClock.now
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))
        meter.askedFor("b-1", at: tapped)

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(140),
            arrived: tapped.advanced(by: .milliseconds(180))
        )

        let report = meter.report()
        #expect(report?.contains("mine=1") == true)
        #expect(report?.contains("trip p50=180.0") == true)
    }

    @Test("without two clocks worth comparing there is still a trip but no wire figure")
    func anUntrustedClockLosesOnlyTheWireFigure() {
        let meter = BurstMeter()
        let tapped = ContinuousClock.now
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: .fallback(), now: .fallback())
        meter.askedFor("b-1", at: tapped)

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: .fallback(),
            now: .fallback(),
            arrived: tapped.advanced(by: .milliseconds(90))
        )

        let report = meter.report()
        #expect(report?.contains("bursts=1") == true)
        #expect(report?.contains("trip p50=90.0") == true)
        #expect(report?.contains("wire") == false)
        #expect(report?.contains("untimed=1") == true)
    }

    @Test("a burst that arrived before it was simulated is reported as the clocks disagreeing")
    func anImpossibleArrivalIsCalledOut() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))

        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(1000),
            now: at(900)
        )

        let report = meter.report()
        #expect(report?.contains("before-they-happened=1") == true)
        #expect(report?.contains("wire") == false)
    }

    @Test("a pop whose bubble got away is still awaited rather than counted as a trip")
    func aPopThatMissedIsNotATrip() {
        let meter = BurstMeter()
        meter.observe(SpaceDelta(), in: field(bubble("b-1")), simulated: at(0), now: at(0))
        meter.askedFor("b-1")

        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1", leaving: true)),
            simulated: at(50),
            now: at(60)
        )
        meter.observe(
            SpaceDelta(removed: ["b-1"]),
            in: field(),
            simulated: at(100),
            now: at(120)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=0") == true)
        #expect(report?.contains("away=1") == true)
        #expect(report?.contains("awaiting=1") == true)
    }

    @Test("somebody else's burst is counted without being credited to this device")
    func anotherPhonesPopIsNotMine() {
        let meter = BurstMeter()
        meter.observe(
            SpaceDelta(),
            in: field(bubble("b-1"), bubble("b-2")),
            simulated: at(0),
            now: at(0)
        )
        meter.askedFor("b-1")

        meter.observe(
            SpaceDelta(removed: ["b-2"]),
            in: field(bubble("b-1")),
            simulated: at(100),
            now: at(150)
        )

        let report = meter.report()
        #expect(report?.contains("bursts=1") == true)
        #expect(report?.contains("mine=0") == true)
        #expect(report?.contains("awaiting=1") == true)
    }

    private func bubble(_ name: String, leaving: Bool = false) -> SpaceEntity {
        SpaceEntity(
            id: SpaceEntityID(name),
            kind: BubbleField.kind,
            facts: leaving ? [BubbleField.leaving: .flag(true)] : [:]
        )
    }

    private func field(_ entities: SpaceEntity...) -> SpaceSnapshot {
        SpaceSnapshot(entities: Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) }))
    }

    private func at(_ milliseconds: Int64) -> Timecode {
        Timecode(
            nanoseconds: milliseconds * 1_000_000,
            uncertainty: .milliseconds(1),
            trust: .synchronised
        )
    }
}
