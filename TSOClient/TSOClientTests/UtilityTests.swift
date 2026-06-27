import Testing
import Foundation
@testable import TSOClient

@Suite("DurationFormatter")
struct DurationFormatterTests {

    @Test func minutesSecondsBelowOneHour() {
        #expect(DurationFormatter.format(0)       == "0m 00s")
        #expect(DurationFormatter.format(5)       == "0m 05s")
        #expect(DurationFormatter.format(330)     == "5m 30s")
        #expect(DurationFormatter.format(3599)    == "59m 59s")
    }

    @Test func hoursMinutesBetweenOneHourAndOneDay() {
        #expect(DurationFormatter.format(3600)    == "1h 00m")
        #expect(DurationFormatter.format(3720)    == "1h 02m")
        #expect(DurationFormatter.format(86399)   == "23h 59m")
    }

    @Test func daysHoursMinutesAboveOneDay() {
        #expect(DurationFormatter.format(86400)         == "1d 0h 00m")
        #expect(DurationFormatter.format(86400 + 7320)  == "1d 2h 02m")
    }

    @Test func truncatesFractionalSeconds() {
        // 90.9 → 90s → "1m 30s" (Int truncation, not rounding).
        #expect(DurationFormatter.format(90.9) == "1m 30s")
    }
}

@Suite("String+CamelCase")
struct StringCamelCaseTests {

    @Test func splitsBeforeEveryInternalUppercase() {
        #expect("PirateExplorer".camelCaseToWords == "Pirate Explorer")
        #expect("HiredMilitary".camelCaseToWords  == "Hired Military")
        #expect("StoneColdGeologist".camelCaseToWords == "Stone Cold Geologist")
    }

    @Test func emptyAndSingleWordPassThrough() {
        #expect("".camelCaseToWords        == "")
        #expect("Explorer".camelCaseToWords == "Explorer")
        #expect("lowercase".camelCaseToWords == "lowercase")
    }

    @Test func leadingUppercaseStaysAttached() {
        // Only uppercase chars at index > 0 get a leading space.
        #expect("A".camelCaseToWords  == "A")
        #expect("AB".camelCaseToWords == "A B")
    }
}

@Suite("BuildingSkinNormalizer")
struct BuildingSkinNormalizerTests {

    @Test func stripsTrailingNumericSuffix() {
        let n = BuildingSkinNormalizer()
        #expect(n.base(of: "Woodcutter_01") == "Woodcutter")
        #expect(n.base(of: "Mason_3")       == "Mason")
        #expect(n.base(of: "GreatHall_garrison_42") == "GreatHall_garrison")
    }

    @Test func leavesBareNamesUnchanged() {
        let n = BuildingSkinNormalizer()
        #expect(n.base(of: "Woodcutter") == "Woodcutter")
        #expect(n.base(of: "Mason")      == "Mason")
    }

    @Test func internalUnderscoreNumberNotStripped() {
        // Only the *trailing* "_NN" is a variant tag; mid-string segments stay.
        let n = BuildingSkinNormalizer()
        #expect(n.base(of: "Building_07_thing") == "Building_07_thing")
    }
}

@Suite("BulkDispatcher")
struct BulkDispatcherTests {

    @Test func runsItemsInOrder() async {
        let bulk = BulkDispatcher(interCallDelayNs: 0)
        actor Collector { var seen: [Int] = []; func push(_ i: Int) { seen.append(i) } }
        let c = Collector()
        let items = [10, 20, 30, 40]

        await bulk.run(items: items) { _, x in
            Task { await c.push(x) }
        }.value

        // Inner tasks dispatched on the main actor enqueue async pushes; give
        // them a tick to settle before reading.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let seen = await c.seen
        #expect(seen == items)
    }

    @Test func indexIsPassedToAction() async {
        let bulk = BulkDispatcher(interCallDelayNs: 0)
        actor Collector { var seen: [Int] = []; func push(_ i: Int) { seen.append(i) } }
        let c = Collector()

        await bulk.run(items: ["a", "b", "c"]) { i, _ in
            Task { await c.push(i) }
        }.value
        try? await Task.sleep(nanoseconds: 50_000_000)

        let seen = await c.seen
        #expect(seen == [0, 1, 2])
    }

    @Test func productionDefaultDelayIs80ms() {
        // Smoke-test the production constant. If this drifts, the WKWebView
        // ordering rationale in BulkDispatcher.swift needs a fresh look.
        #expect(BulkDispatcher().interCallDelayNs == 80_000_000)
    }

    @Test func emptyInputDispatchesNothingAndCompletes() async {
        let bulk = BulkDispatcher(interCallDelayNs: 0)
        var calls = 0
        await bulk.run(items: [Int]()) { _, _ in calls += 1 }.value
        #expect(calls == 0)
    }
}
