import XCTest

class CodexQuotaSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(_ duration: Int, used: Int = 25) -> [String: Any] {
        return ["windowDurationMins": duration, "usedPercent": used, "resetsAt": now.timeIntervalSince1970 + 7_200]
    }

    private func snapshot(_ plan: String, primary: Any, secondary: Any = NSNull()) -> CodexQuotaSnapshot {
        return CodexQuotaSnapshot(payload: ["rateLimits": [
            "planType": plan, "primary": primary, "secondary": secondary
        ]])!
    }

    func testPlusKeepsFiveHourAndWeekly() {
        let quota = snapshot("plus", primary: window(300), secondary: window(10_080, used: 60))
        XCTAssertEqual(quota.plan, .plus)
        XCTAssertEqual(quota.windows.map { $0.kind }, [.fiveHour, .weekly])
        XCTAssertEqual(quota.windows.map { $0.remaining }, [75, 40])
        XCTAssertEqual(quota.title(now: now).components(separatedBy: "\n").count, 2)
        XCTAssertTrue(quota.title(now: now).contains("CodeX Plus"))
    }

    func testProWeeklyInPrimaryIsOnlyOneLine() {
        let quota = snapshot("pro", primary: window(10_080))
        XCTAssertEqual(quota.plan, .pro)
        XCTAssertFalse(quota.hasWindow(.fiveHour))
        XCTAssertTrue(quota.hasWindow(.weekly))
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertFalse(quota.title(now: now).contains("\n"))
        XCTAssertTrue(quota.title(now: now).contains("CodeX Pro"))
    }

    func testProVariantsUseProDisplayAndSuppressFiveHour() {
        for plan in ["prolite", "promax"] {
            let quota = snapshot(plan, primary: window(300), secondary: window(10_080))
            XCTAssertEqual(quota.plan, .pro)
            XCTAssertEqual(quota.windows.map { $0.kind }, [.weekly])
            XCTAssertTrue(quota.title(now: now).contains("CodeX Pro"))
        }
    }

    func testCurrentProLiteWeeklyOnlyResponse() {
        let quota = snapshot("prolite", primary: window(10_080, used: 1))
        XCTAssertEqual(quota.plan, .pro)
        XCTAssertEqual(quota.windows.map { $0.kind }, [.weekly])
        XCTAssertTrue(quota.title(now: now).contains("99%"))
        XCTAssertFalse(quota.title(now: now).contains("\n"))
    }

    func testProSuppressesFiveHourAndKeepsWeeklyEvenWithSavedPlusSelection() {
        let quota = snapshot("pro", primary: window(300, used: 90), secondary: window(10_080, used: 10))
        XCTAssertEqual(quota.windows.map { $0.kind }, [.weekly])
        let title = quota.title(showFiveHour: true, showWeekly: false, now: now)
        XCTAssertTrue(title.contains("90%"))
        XCTAssertFalse(title.contains("10%"))
    }

    func testFreeUsesOnlyReturnedWindows() {
        let quota = snapshot("free", primary: window(10_080, used: 100))
        XCTAssertEqual(quota.plan, .free)
        XCTAssertEqual(quota.windows.map { $0.kind }, [.weekly])
        XCTAssertTrue(quota.title(now: now).contains("CodeX Free"))
        XCTAssertTrue(quota.title(now: now).contains("0%"))
    }

    func testWindowDurationOverridesPosition() {
        let quota = snapshot("plus", primary: window(10_080, used: 40), secondary: window(300, used: 10))
        XCTAssertEqual(quota.windows.map { $0.kind }, [.fiveHour, .weekly])
        XCTAssertEqual(quota.windows.map { $0.remaining }, [90, 60])
        let title = quota.title(showFiveHour: false, showWeekly: true, now: now)
        XCTAssertTrue(title.contains("60%"))
        XCTAssertFalse(title.contains("90%"))
    }

    func testMultiBucketCodexTakesPriorityOverLegacyAndOtherBuckets() {
        let quota = CodexQuotaSnapshot(payload: [
            "rateLimits": ["planType": "plus", "primary": window(300)],
            "rateLimitsByLimitId": [
                "codex": ["planType": "pro", "primary": window(10_080)],
                "codex_other": ["planType": "plus", "primary": window(300)]
            ]
        ])!
        XCTAssertEqual(quota.plan, .pro)
        XCTAssertEqual(quota.windows.map { $0.kind }, [.weekly])
    }

    func testLegacyAccountPlanFallbackAndPlusDurations() {
        let quota = CodexQuotaSnapshot(payload: ["rateLimits": [
            "primary": ["usedPercent": 15], "secondary": ["usedPercent": 25]
        ]], accountPlan: "plus")!
        XCTAssertEqual(quota.plan, .plus)
        XCTAssertEqual(quota.windows.map { $0.kind }, [.fiveHour, .weekly])
        XCTAssertTrue(quota.title(now: now).hasSuffix("↻ --"))
    }

    func testMissingDataDoesNotShowFullQuotaOrCopyAnotherWindow() {
        let quota = snapshot("plus", primary: ["windowDurationMins": 300])
        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertNil(quota.windows.first?.remaining)
        XCTAssertTrue(quota.title(now: now).contains("--%"))
        XCTAssertFalse(quota.title(now: now).contains("100%"))
        XCTAssertFalse(quota.title(now: now).contains("\n"))
    }

    func testEmptySnapshotShowsUnavailableForCurrentPlan() {
        let quota = snapshot("pro", primary: NSNull())
        XCTAssertEqual(quota.title(now: now), "✦ CodeX Pro  额度暂不可用")
        XCTAssertNil(CodexQuotaSnapshot(payload: [:]))
    }

    func testUnknownFreeDurationRemainsVisibleWithoutInventingFiveHourWindow() {
        let quota = snapshot("free", primary: window(1_440))
        XCTAssertEqual(quota.windows.map { $0.kind }, [.other])
        XCTAssertTrue(quota.title(showFiveHour: false, showWeekly: false, now: now).contains("75%"))
    }

    func testCacheRoundTripPreservesPlanSelectionAndCountdown() throws {
        let quota = snapshot("plus", primary: window(300), secondary: window(10_080, used: 70))
        let data = try JSONEncoder().encode(CodexQuotaSnapshot.Cache(title: quota.title(now: now), codexQuota: quota))
        let cached = try JSONDecoder().decode(CodexQuotaSnapshot.Cache.self, from: data)
        XCTAssertEqual(cached.codexQuota.plan, .plus)
        XCTAssertTrue(cached.codexQuota.title(showFiveHour: false, showWeekly: true, now: now).contains("30%"))
        XCTAssertTrue(cached.codexQuota.title(now: now).contains("2h 00m"))
        XCTAssertTrue(cached.codexQuota.title(now: now.addingTimeInterval(3_600)).contains("1h 00m"))
    }
}
