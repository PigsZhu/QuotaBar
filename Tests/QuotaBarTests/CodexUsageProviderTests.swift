import Foundation
import XCTest
@testable import QuotaBar

final class CodexUsageProviderTests: XCTestCase {
    private func window(_ minutes: Int, usedPercent: Int = 25) -> [String: Any] {
        ["usedPercent": usedPercent, "windowDurationMins": minutes, "resetsAt": 1_800_000_000]
    }

    private func limits(primary: Any, secondary: Any = NSNull(),
                        limitID: String = "codex") -> [String: Any] {
        ["limitId": limitID, "primary": primary, "secondary": secondary, "planType": "pro"]
    }

    func testFiveHourPrimaryIsDecoded() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(300))
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 300)
        XCTAssertEqual(snapshot.primary?.remainingPercent, 75)
        XCTAssertEqual(snapshot.primary?.resetDate, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(snapshot.planName, "pro")
    }

    func testFiveHourSecondaryIsChosenAfterWeeklyPrimary() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(10_080, usedPercent: 2),
                                 secondary: window(300, usedPercent: 17))
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 300)
        XCTAssertEqual(snapshot.primary?.usedPercent, 17)
    }

    func testFiveHourPrimaryIsChosenBeforeWeeklySecondary() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(300, usedPercent: 17),
                                 secondary: window(10_080, usedPercent: 2))
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 300)
        XCTAssertEqual(snapshot.primary?.usedPercent, 17)
    }

    func testWeeklyOnlyIsDisplayedWithoutFiveHourWindow() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(10_080, usedPercent: 2))
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.primary?.remainingPercent, 98)
        XCTAssertEqual(snapshot.primary?.title, "每周额度")
        XCTAssertEqual(snapshot.providerName, "Codex")
    }

    func testSparkFiveHourWindowDoesNotReplaceCodexWeeklyWindow() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(10_080)),
            "rateLimitsByLimitId": [
                "codex": limits(primary: window(10_080)),
                "codex_bengalfox": limits(primary: window(300), limitID: "codex_bengalfox")
            ]
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 10_080)
    }

    func testCodexMapEntryTakesPriorityOverLegacy() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(300, usedPercent: 80)),
            "rateLimitsByLimitId": ["codex": limits(primary: window(300, usedPercent: 12))]
        ])

        XCTAssertEqual(snapshot.primary?.usedPercent, 12)
    }

    func testWeeklyCodexMapDoesNotFallBackToLegacyFiveHourWindow() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(300)),
            "rateLimitsByLimitId": ["codex": limits(primary: window(10_080))]
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 10_080)
    }

    func testLegacyIsUsedWhenMapHasNoCodexEntry() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(300, usedPercent: 34)),
            "rateLimitsByLimitId": [
                "codex_bengalfox": limits(primary: window(300, usedPercent: 90), limitID: "codex_bengalfox")
            ]
        ])

        XCTAssertEqual(snapshot.primary?.usedPercent, 34)
    }

    func testMissingDurationIsNotAssumedToBeDisplayable() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: ["usedPercent": 20, "resetsAt": 1_800_000_000])
        ])

        XCTAssertNil(snapshot.primary)
    }

    func testUnknownAndNullDurationsAreNotAssumedToBeDisplayable() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(60), secondary: [
                "usedPercent": 20, "windowDurationMins": NSNull(), "resetsAt": 1_800_000_000
            ])
        ])

        XCTAssertNil(snapshot.primary)
    }

    func testNullWindowsAreSuccessfulWithoutDisplayableQuota() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: NSNull(), secondary: NSNull())
        ])

        XCTAssertNil(snapshot.primary)
    }

    func testWeeklySecondaryIsDisplayedWhenPrimaryHasUnknownDuration() throws {
        let snapshot = try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(60), secondary: window(10_080, usedPercent: 8))
        ])

        XCTAssertEqual(snapshot.primary?.durationMinutes, 10_080)
        XCTAssertEqual(snapshot.primary?.usedPercent, 8)
    }

    func testMissingCodexDataThrowsInsteadOfReportingNoWindow() {
        XCTAssertThrowsError(try CodexAppServerUsageProvider.decodeUsage(from: [:]))
        XCTAssertThrowsError(try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimitsByLimitId": [
                "codex_bengalfox": limits(primary: window(300), limitID: "codex_bengalfox")
            ]
        ]))
        XCTAssertThrowsError(try CodexAppServerUsageProvider.decodeUsage(from: [
            "rateLimits": limits(primary: window(300), limitID: "codex_bengalfox")
        ]))
    }

    func testMalformedWindowThrowsInsteadOfReportingNoWindow() {
        let malformed: [Any] = [
            "invalid window",
            ["windowDurationMins": 300],
            ["usedPercent": "25", "windowDurationMins": 300],
            ["usedPercent": true, "windowDurationMins": 300],
            ["usedPercent": 25, "windowDurationMins": "300"],
            ["usedPercent": 25, "windowDurationMins": 300.5]
        ]

        for value in malformed {
            XCTAssertThrowsError(try CodexAppServerUsageProvider.decodeUsage(from: [
                "rateLimits": limits(primary: value)
            ]))
        }
    }
}
