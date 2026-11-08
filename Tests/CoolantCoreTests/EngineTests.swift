import CoolantCore
import Foundation
import Testing

struct RampTests {
    @Test func linearTargetClampsAndInterpolates() {
        #expect(FanRamp.linearTarget(temperature: 40, start: 50, max: 80, minimum: 1000, maximum: 4000) == 1000)
        #expect(FanRamp.linearTarget(temperature: 65, start: 50, max: 80, minimum: 1000, maximum: 4000) == 2500)
        #expect(FanRamp.linearTarget(temperature: 95, start: 50, max: 80, minimum: 1000, maximum: 4000) == 4000)
    }

    @Test func degenerateRangeIsAStep() {
        #expect(FanRamp.linearTarget(temperature: 60, start: 60, max: 60, minimum: 1000, maximum: 4000) == 4000)
        #expect(FanRamp.linearTarget(temperature: 59, start: 60, max: 60, minimum: 1000, maximum: 4000) == 1000)
    }

    @Test func riseIsSlewLimited() {
        var ramp = FanRamp()
        _ = ramp.next(temperature: 50, start: 50, max: 80, minimum: 1000, maximum: 4000, seconds: 2)
        let rpm = ramp.next(temperature: 80, start: 50, max: 80, minimum: 1000, maximum: 4000, seconds: 2)
        #expect(rpm == 2000)
    }

    @Test func smallDropDoesNotLowerTheFan() {
        var ramp = FanRamp()
        let first = ramp.next(temperature: 65, start: 50, max: 80, minimum: 1000, maximum: 4000, seconds: 2)
        let second = ramp.next(temperature: 64, start: 50, max: 80, minimum: 1000, maximum: 4000, seconds: 2)
        #expect(first == second)
    }

    @Test func realDropFallsSlowly() {
        var ramp = FanRamp()
        let first = ramp.next(temperature: 80, start: 50, max: 80, minimum: 1000, maximum: 4000, seconds: 2)
        let second = ramp.next(temperature: 50, start: 50, max: 80, minimum: 1000, maximum: 4000, seconds: 2)
        #expect(first - second == 300)
    }
}

struct RuleTests {
    let t0 = Date(timeIntervalSince1970: 1000)
    func rule(hold: Double = 10) -> Rule {
        Rule(name: "t", sensorID: "s", threshold: 90, hysteresis: 10, holdSeconds: hold, presetID: "p")
    }

    @Test func mustHoldBeforeTriggering() {
        var engine = RuleEngine(); let r = rule()
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0).isEmpty)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0 + 9).isEmpty)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0 + 10).first?.kind == .triggered)
        #expect(engine.isActive(r.id))
    }

    @Test func spikeResetsTheHold() {
        var engine = RuleEngine(); let r = rule()
        _ = engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0)
        _ = engine.evaluate(rules: [r], temperatures: ["s": 70], now: t0 + 5)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0 + 11).isEmpty)
    }

    @Test func clearsOnlyPastHysteresis() {
        var engine = RuleEngine(); let r = rule(hold: 0)
        _ = engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 85], now: t0 + 1).isEmpty)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 80], now: t0 + 2).first?.kind == .cleared)
        #expect(!engine.isActive(r.id))
    }

    @Test func belowRuleTriggersOnFall() {
        var engine = RuleEngine()
        let r = Rule(name: "t", sensorID: "s", whenAbove: false, threshold: 30, hysteresis: 2, holdSeconds: 0, presetID: nil)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 29], now: t0).first?.kind == .triggered)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 31], now: t0 + 1).isEmpty)
        #expect(engine.evaluate(rules: [r], temperatures: ["s": 32], now: t0 + 2).first?.kind == .cleared)
    }

    @Test func missingSensorKeepsState() {
        var engine = RuleEngine(); let r = rule(hold: 0)
        _ = engine.evaluate(rules: [r], temperatures: ["s": 95], now: t0)
        #expect(engine.evaluate(rules: [r], temperatures: [:], now: t0 + 1).isEmpty)
        #expect(engine.isActive(r.id))
    }

    @Test func listOrderIsPriorityAndNotifyOnlyNeverWins() {
        var engine = RuleEngine()
        var a = rule(hold: 0); a.presetID = nil
        let b = rule(hold: 0), c = rule(hold: 0)
        let rules = [a, b, c]
        _ = engine.evaluate(rules: rules, temperatures: ["s": 95], now: t0)
        #expect(engine.winner(in: rules)?.id == b.id)
    }
}

struct FailsafeTests {
    @Test func singleSpikeDoesNotEngage() {
        var f = Failsafe()
        let changes = [106.0, 90, 106].map { f.update(hottest: $0, limit: 105) }
        #expect(changes == [false, false, false])
        #expect(!f.engaged)
    }

    @Test func engagesWhenSustainedAndReleasesWithMargin() {
        var f = Failsafe()
        let rising = [105.0, 105, 105].map { f.update(hottest: $0, limit: 105) }
        #expect(rising == [false, false, true])
        #expect(f.engaged)
        let held = f.update(hottest: 100, limit: 105)
        #expect(!held)
        #expect(f.engaged)
        let released = f.update(hottest: 97, limit: 105)
        #expect(released)
        #expect(!f.engaged)
    }
}

struct ConfigTests {
    @Test func roundTripsEveryControlKind() throws {
        var c = Config.starter(fanCount: 2)
        c.customControls = [0: .constant(rpm: 2000), 1: .full]
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c))
        #expect(back == c)
    }
}
