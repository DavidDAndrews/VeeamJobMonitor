import XCTest
@testable import VeeamMonitor

// NOTE: These tests require a unit-test target wired into the Xcode project.
// They are intentionally written against pure / lightly-exposed logic so they
// can be run once a `VeeamMonitorTests` target is added in Xcode and this
// file is included in that target's Sources build phase.

final class StringFormattingTests: XCTestCase {
    func testHTMLEscapedEscapesReservedCharacters() {
        XCTAssertEqual("a & b".htmlEscaped, "a &amp; b")
        XCTAssertEqual("<tag>".htmlEscaped, "&lt;tag&gt;")
        XCTAssertEqual("\"quote\"".htmlEscaped, "&quot;quote&quot;")
        XCTAssertEqual("it's".htmlEscaped, "it&#39;s")
        // Ampersand must be escaped first so existing entities are not double-escaped incorrectly.
        XCTAssertEqual("<a href=\"x\">&".htmlEscaped, "&lt;a href=&quot;x&quot;&gt;&amp;")
    }

    func testURLFormEncodedEncodesUnsafeCharacters() {
        XCTAssertEqual("a b".urlFormEncoded, "a%20b")
        XCTAssertEqual("a+b".urlFormEncoded, "a%2Bb")
        XCTAssertEqual("a=b&c".urlFormEncoded, "a%3Db%26c")
        XCTAssertEqual("DOMAIN\\user".urlFormEncoded, "DOMAIN%5Cuser")
        // Unreserved characters are preserved verbatim.
        XCTAssertEqual("Aa0-_.~".urlFormEncoded, "Aa0-_.~")
    }
}

final class ServerURLNormalizationTests: XCTestCase {
    @MainActor
    func testNormalisedServerURLAddsSchemeAndTrimsTrailingSlash() {
        let api = VeeamAPIService()
        XCTAssertEqual(api.normalisedServerURL("example.com"), "https://example.com")
        XCTAssertEqual(api.normalisedServerURL("  example.com  "), "https://example.com")
        XCTAssertEqual(api.normalisedServerURL("https://example.com/"), "https://example.com")
        XCTAssertEqual(api.normalisedServerURL("https://example.com///"), "https://example.com")
        XCTAssertEqual(api.normalisedServerURL("http://1.2.3.4:9419"), "http://1.2.3.4:9419")
    }
}

final class TextScalePreferenceTests: XCTestCase {
    func testScaledFactorDoesNotRecursivelyNormalize() {
        for index in -20...20 {
            let factor = TextScalePreference.testing_scaledFactor(forStepIndex: index)
            XCTAssertGreaterThanOrEqual(factor, 0.75)
            XCTAssertLessThanOrEqual(factor, 1.5)
        }
    }

    func testNormalizedFactorSnapsToStepWithoutStackOverflow() {
        let samples = [0.5, 0.75, 0.88, 1.0, 1.07, 1.25, 1.5, 2.0]
        for sample in samples {
            let normalized = TextScalePreference.testing_normalizedFactor(sample)
            XCTAssertGreaterThanOrEqual(normalized, 0.75)
            XCTAssertLessThanOrEqual(normalized, 1.5)
        }
    }

    func testIncreaseDecreaseStepsWithoutStackOverflow() {
        var factor = TextScalePreference.defaultFactor
        for _ in 0..<20 {
            factor = TextScalePreference.increased(from: factor)
        }
        XCTAssertEqual(factor, 1.5, accuracy: 0.001)
        for _ in 0..<20 {
            factor = TextScalePreference.decreased(from: factor)
        }
        XCTAssertEqual(factor, 0.75, accuracy: 0.001)
    }

    func testMigrationDoesNotRecursivelyNormalize() {
        let defaults = UserDefaults.standard
        let storageKey = TextScalePreference.storageKey
        let legacyKey = TextScalePreference.legacyStorageKey
        let priorStorage = defaults.object(forKey: storageKey)
        let priorLegacy = defaults.object(forKey: legacyKey)

        defaults.removeObject(forKey: storageKey)
        defaults.set(2, forKey: legacyKey)
        TextScalePreference.migrateLegacyScaleIfNeeded()
        XCTAssertNotNil(defaults.object(forKey: storageKey))

        if let priorStorage {
            defaults.set(priorStorage, forKey: storageKey)
        } else {
            defaults.removeObject(forKey: storageKey)
        }
        if let priorLegacy {
            defaults.set(priorLegacy, forKey: legacyKey)
        } else {
            defaults.removeObject(forKey: legacyKey)
        }
    }
}

final class JobResultBucketTests: XCTestCase {
    private func makeJob(
        status: String? = nil,
        lastResult: String? = nil,
        isEnabled: Bool? = true,
        progressPercent: Int? = nil
    ) -> VeeamJob {
        VeeamJob(
            id: "job-1",
            name: "Job 1",
            jobDescription: nil,
            type: "Backup",
            status: status,
            lastResult: lastResult,
            lastRun: nil,
            nextRun: nil,
            isEnabled: isEnabled,
            scheduleDescription: nil,
            vmStorageSize: nil,
            repositoryName: nil,
            objectsCount: nil,
            progressPercent: progressPercent,
            processingRateBytesPerSecond: nil,
            processedSizeBytes: nil,
            readSizeBytes: nil,
            transferredSizeBytes: nil,
            driveSummary: nil,
            backupPoints: []
        )
    }

    func testRunningJobIsRunningBucket() {
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Running", progressPercent: 42)), .running)
    }

    func testStartingJobIsRunningBucket() {
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Starting", progressPercent: 0)), .running)
    }

    func testActiveJobStatusIncludesStartingAndStopping() {
        XCTAssertTrue(VeeamJob.isActiveJobStatus("Starting"))
        XCTAssertTrue(VeeamJob.isActiveJobStatus("Running"))
        XCTAssertTrue(VeeamJob.isActiveJobStatus("Stopping"))
        XCTAssertFalse(VeeamJob.isActiveJobStatus("Stopped"))
    }

    func testActiveSessionStateIncludesWorking() {
        XCTAssertTrue(VeeamJob.isActiveSessionState("Working"))
        XCTAssertFalse(VeeamJob.isActiveSessionState("Stopped"))
    }

    func testDisabledJobIsDisabledBucket() {
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Disabled", isEnabled: false)), .disabled)
        XCTAssertEqual(jobResultBucket(for: makeJob(lastResult: "Success", isEnabled: false)), .disabled)
    }

    func testSuccessWarningFailedBuckets() {
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Inactive", lastResult: "Success")), .success)
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Inactive", lastResult: "Warning")), .warning)
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Inactive", lastResult: "Failed")), .failed)
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Inactive", lastResult: "Error")), .failed)
    }

    func testUnknownBucket() {
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Inactive", lastResult: nil)), .unknown)
        XCTAssertEqual(jobResultBucket(for: makeJob(status: "Inactive", lastResult: "None")), .unknown)
    }
}

final class JobRuntimeEstimationTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testFormatHumanReadableDurationMinutesOnly() {
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(60), "1 Minute")
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(5 * 60), "5 Minutes")
    }

    func testFormatHumanReadableDurationHoursAndMinutes() {
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(3_600), "1 Hour and 0 Minutes")
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(5_400), "1 Hour and 30 Minutes")
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(6_540), "1 Hour and 49 Minutes")
    }

    func testFormatHumanReadableDurationDays() {
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(90_000), "1 Day and 1 Hour and 0 Minutes")
        XCTAssertEqual(JobRuntimeEstimation.formatHumanReadableDuration(86_400), "1 Day and 0 Minutes")
    }

    func testFormatEstimatedCompletionUsesRelativeWithinThreshold() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let completionDate = now.addingTimeInterval(45 * 60)

        XCTAssertEqual(
            JobRuntimeEstimation.formatEstimatedCompletion(
                remaining: 45 * 60,
                completionDate: completionDate,
                now: now,
                calendar: utcCalendar
            ),
            "in 45 Minutes"
        )
    }

    func testFormatEstimatedCompletionUsesTodayAtForSameDayBeyondThreshold() {
        var calendar = utcCalendar
        let now = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 28,
            hour: 9,
            minute: 0
        ))!
        let completionDate = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 28,
            hour: 21,
            minute: 16
        ))!

        let formatted = JobRuntimeEstimation.formatEstimatedCompletion(
            remaining: 12 * 3600,
            completionDate: completionDate,
            now: now,
            calendar: calendar
        )
        let expectedTime = DetailTimeFormatter.shared.string(from: completionDate)

        XCTAssertEqual(formatted, "Today at \(expectedTime)")
    }

    func testFormatEstimatedCompletionUsesTomorrowAt() {
        var calendar = utcCalendar
        let now = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 28,
            hour: 20,
            minute: 0
        ))!
        let completionDate = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 29,
            hour: 9,
            minute: 16
        ))!

        let formatted = JobRuntimeEstimation.formatEstimatedCompletion(
            remaining: 13 * 3600,
            completionDate: completionDate,
            now: now,
            calendar: calendar
        )
        let expectedTime = DetailTimeFormatter.shared.string(from: completionDate)

        XCTAssertEqual(formatted, "Tomorrow at \(expectedTime)")
    }

    func testFormatEstimatedCompletionUsesFullDateForLaterDates() {
        var calendar = utcCalendar
        let now = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 28,
            hour: 9,
            minute: 0
        ))!
        let completionDate = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 30,
            hour: 15,
            minute: 30
        ))!

        let formatted = JobRuntimeEstimation.formatEstimatedCompletion(
            remaining: 54 * 3600,
            completionDate: completionDate,
            now: now,
            calendar: calendar
        )

        XCTAssertTrue(formatted.contains("May"))
        XCTAssertTrue(formatted.contains("30"))
        XCTAssertTrue(formatted.contains("2026"))
    }

    func testRunningJobWithProgressShowsEstimatedTotal() {
        let elapsed: TimeInterval = 7 * 60
        let info = JobRuntimeEstimation.displayInfo(
            elapsedSeconds: elapsed,
            isRunning: true,
            progressPercent: 7,
            now: Date(timeIntervalSince1970: 1_000_000)
        )

        XCTAssertEqual(info.valueText, "7 Minutes of 1 Hour and 40 Minutes Estimated Total")
        XCTAssertEqual(info.subtitleText, "Est Completion: in 1 Hour and 33 Minutes")
        XCTAssertEqual(info.progressPercent, 7)
    }

    func testRunningJobWithZeroProgressShowsElapsedOnly() {
        let info = JobRuntimeEstimation.displayInfo(
            elapsedSeconds: 420,
            isRunning: true,
            progressPercent: 0
        )

        XCTAssertEqual(info.valueText, "7 Minutes (7 Mins)")
        XCTAssertEqual(info.subtitleText, "Waiting for progress update")
        XCTAssertEqual(info.progressPercent, 0)
    }

    func testRunningJobWithNilProgressShowsElapsedOnly() {
        let info = JobRuntimeEstimation.displayInfo(
            elapsedSeconds: 420,
            isRunning: true,
            progressPercent: nil
        )

        XCTAssertEqual(info.valueText, "7 Minutes (7 Mins)")
        XCTAssertEqual(info.progressPercent, 0)
    }

    func testCompletedProgressShowsCompleteMessaging() {
        let info = JobRuntimeEstimation.displayInfo(
            elapsedSeconds: 420,
            isRunning: true,
            progressPercent: 100
        )

        XCTAssertEqual(info.valueText, "7 Minutes (7 Mins)")
        XCTAssertEqual(info.subtitleText, "Run complete")
        XCTAssertEqual(info.progressPercent, 100)
    }

    func testInactiveJobUsesStaticRuntimeDisplay() {
        let info = JobRuntimeEstimation.displayInfo(
            elapsedSeconds: 3_600,
            isRunning: false,
            progressPercent: 42
        )

        XCTAssertEqual(info.valueText, "1 Hour and 0 Minutes (60 Mins)")
        XCTAssertNil(info.subtitleText)
        XCTAssertNil(info.progressPercent)
    }

    func testEstimatedTotalCapsLowProgress() {
        let elapsed: TimeInterval = 600
        let uncapped = elapsed / 0.01
        let capped = JobRuntimeEstimation.estimatedTotalSeconds(elapsed: elapsed, progressPercent: 1)

        XCTAssertLessThan(capped, uncapped)
        XCTAssertEqual(capped, elapsed * JobRuntimeEstimation.maxEstimatedTotalMultiplier)
    }

    func testEstimatedTotalAvoidsDivideByZero() {
        XCTAssertEqual(JobRuntimeEstimation.estimatedTotalSeconds(elapsed: 0, progressPercent: 50), 0)
        XCTAssertEqual(JobRuntimeEstimation.estimatedTotalSeconds(elapsed: 600, progressPercent: 0), 600)
    }
}

final class LiquidGlassTests: XCTestCase {
    func testPrefersSystemGlassWhenTransparencyAllowed() {
        if #available(macOS 26, *) {
            XCTAssertTrue(LiquidGlass.testing_prefersSystemGlass(reduceTransparency: false))
        } else {
            XCTAssertFalse(LiquidGlass.testing_prefersSystemGlass(reduceTransparency: false))
        }
    }

    func testFallsBackWhenReduceTransparencyEnabled() {
        XCTAssertFalse(LiquidGlass.testing_prefersSystemGlass(reduceTransparency: true))
    }

    func testFallsBackWhenIncreaseContrastEnabled() {
        if #available(macOS 26, *) {
            XCTAssertFalse(LiquidGlass.testing_prefersSystemGlass(reduceTransparency: false, contrast: .increased))
        } else {
            XCTAssertFalse(LiquidGlass.testing_prefersSystemGlass(reduceTransparency: false, contrast: .increased))
        }
    }
}
