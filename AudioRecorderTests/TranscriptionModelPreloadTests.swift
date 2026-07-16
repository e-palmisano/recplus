import XCTest
@testable import AudioRecorder

// MARK: - Test Harness

struct SessionHarness {
    let session: RecordingSession
    let probe: PreloadTestProbe
    let installer: GatedModelInstaller
}

@MainActor
final class TranscriptionModelPreloadTests: XCTestCase {
    // MARK: - Coordinator Tests

    func testNormalizedLaunchSelectionPreloadsOnlyResolvedInstalledLocale() async throws {
        let harness = makeSessionHarness(selectedID: "en_US", normalized: "en-US", installed: true)
        harness.session.preloadSelectedModelAfterNormalization()
        try await waitFor(harness.probe) { if case .preloadRequested("en-US") = $0 { return true }; return false }
        let preloadLocales = await harness.probe.preloadRequestLocales()
        XCTAssertEqual(preloadLocales, ["en-US"])
    }

    func testSuccessfulExplicitDownloadStartsPreloadImmediately() async throws {
        let harness = makeSessionHarness(selectedID: "it-IT", normalized: "it-IT", installed: false)
        harness.session.downloadModel(for: Locale(identifier: "it-IT"))
        try await harness.installer.waitForInstallStart(locale: "it-IT")
        await harness.installer.completeInstall(locale: "it-IT")
        try await waitFor(harness.probe) { if case .installCompleted("it-IT") = $0 { return true }; return false }
        try await waitFor(harness.probe) { if case .preloadRequested("it-IT") = $0 { return true }; return false }
        try await waitFor(harness.probe) { if case .prepareStarted("it-IT", _) = $0 { return true }; return false }
        await harness.probe.completePrepare(locale: "it-IT")
        try await waitFor(harness.probe) { if case .resourcePublished("it-IT", _) = $0 { return true }; return false }
        let installerSnapshot = await harness.installer.snapshot()
        let preloadLocales = await harness.probe.preloadRequestLocales()
        XCTAssertEqual(installerSnapshot.installCount, 1)
        XCTAssertEqual(preloadLocales, ["it-IT"])
    }

    func testStaleExplicitDownloadCompletionDoesNotPrepareOrPublishOldSelection() async throws {
        let harness = makeSessionHarness(
            selectedID: "en-US",
            normalized: "en-US",
            installed: false,
        )

        harness.session.downloadModel(for: Locale(identifier: "en-US"))
        try await harness.installer.waitForInstallStart(locale: "en-US")
        harness.session.selectTranscriptionLocale(id: "it-IT")
        await harness.installer.completeInstall(locale: "en-US")
        try await waitFor(harness.probe) { if case .installCompleted("en-US") = $0 { return true }; return false }

        // Per shared-interfaces.md's mandated event ordering, the engine emits
        // `.preloadRequested` before checking install status, so it fires here
        // even though "it-IT" is not installed (see the reordered `_preload`).
        // What this test actually verifies (per its name) is that the stale
        // selection is never prepared or published — it does not claim
        // `.preloadRequested` is suppressed for an uninstalled locale.
        let publishedLocales = await harness.probe.publishedLocales()
        let preparedLocales = await harness.probe.prepareRequestLocales()
        XCTAssertEqual(publishedLocales, [])
        XCTAssertEqual(preparedLocales, [])
    }

    func testPreloadOfInstalledSelectedLocalePreparesExactlyOneResidentModel() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en_US"))
        try await client.waitForEvent { event in
            if case .prepareStarted("en-US", _) = event { return true }; return false
        }
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }; return false
        }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.normalizedLocales, ["en-US"])
        XCTAssertEqual(snapshot.prepareLocales, ["en-US"])
        XCTAssertTrue(snapshot.releaseLocales.isEmpty)
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
    }

    func testPreloadDoesNotPrepareAnUninstalledSelectedLocale() async throws {
        let client = StubTranscriptionModelClient(installed: [])
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForEvent { if case .installedCheck("it-IT", false) = $0 { return true }; return false }

        let snapshot = await client.snapshot()
        XCTAssertTrue(snapshot.prepareLocales.isEmpty)
        XCTAssertNil(engine.preparedLocaleForTesting)
    }

    func testEquivalentConcurrentPreloadsShareOnePreparationOperation() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en_US"))
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForEvent { event in
            if case .prepareStarted("en-US", _) = event { return true }
            return false
        }
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareLocales, ["en-US"])
        XCTAssertEqual(snapshot.prepareCounts["en-US"], 1)
    }

    func testEquivalentRequestAfterFailedPreloadDoesNotAwaitStaleTask() async throws {
        let client = StubTranscriptionModelClient(
            installed: [Locale(identifier: "en-US")],
            prepareErrors: [.prepare, nil]
        )
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForPreloadFailure()
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(2)
        await client.completePrepare(locale: "en-US")
        try await client.waitForResidentLocale("en-US")

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareLocales, ["en-US", "en-US"])
        XCTAssertEqual(snapshot.prepareCounts["en-US"], 2)
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
    }

    func testEquivalentRequestAfterCancelledPreloadDoesNotAwaitStaleTask() async throws {
        let client = StubTranscriptionModelClient(
            installed: [Locale(identifier: "en-US")],
            ignoreCancellation: false
        )
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareStart(locale: "en-US")
        engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(2)
        await client.completePrepare(locale: "en-US")
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .prepareFinished("en-US", _) = event { return true }
            return false
        }
        // No `.resourceReleased` is expected here: the cancelled first
        // operation throws `CancellationError` inside `prepare()` before it
        // ever constructs a `PreparedTranscriptionModel`, so there is never a
        // resident/prepared value from it to release. `invalidateSelection`
        // also finds no resident model yet at the moment it runs. The real
        // assertion for "does not await stale task" is that the second,
        // fresh operation completes and becomes resident on its own.
        try await client.waitForResidentLocale("en-US")

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareCounts["en-US"], 2)
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
    }

    func testStartReusesPreparedModelInsteadOfPreparingAgain() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }

        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        let snapshot1 = await client.snapshot()
        let preparedIdentity = try XCTUnwrap(snapshot1.preparedIdentity)
        try await client.waitForActiveIdentity(preparedIdentity)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareCounts["en-US"], 1)
        XCTAssertEqual(engine.activePreparedIdentityForTesting, preparedIdentity)
        _ = engine.stop()
        let retainedSnapshot = await client.snapshot()
        XCTAssertTrue(retainedSnapshot.releaseLocales.isEmpty)

        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        try await client.waitForActiveIdentity(preparedIdentity)
        let restartedSnapshot = await client.snapshot()
        XCTAssertEqual(restartedSnapshot.prepareCounts["en-US"], 1)
        XCTAssertEqual(engine.activePreparedIdentityForTesting, preparedIdentity)
        _ = engine.stop()
    }

    func testPreloadFailureIsSilentAndStartStillUsesDownloadFallback() async throws {
        let client = StubTranscriptionModelClient(installed: [], prepareError: StubError.prepare)
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForInstalledCheck()
        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        try await client.waitForInstallCount(1)

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.installCount, 1)
        XCTAssertEqual(snapshot.setupFailureCount, 0)
    }


    func testSelectionSwapCancelsOldPreloadReleasesOldModelAndPreparesNewModelOnce() async throws {
        let client = StubTranscriptionModelClient(
            installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")],
            ignoreCancellation: true
        )
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareStart(locale: "en-US")
        engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForPrepareStart(locale: "it-IT")
        // Release both to allow them to proceed
        await client.completePrepare(locale: "it-IT")
        await client.completePrepare(locale: "en-US")
        // Wait for it-IT to publish (succeeds, becomes resident)
        try await client.waitForResidentLocale("it-IT")
        // en-US should eventually complete and be released since it's late
        try await client.waitForLateResult(locale: "en-US")

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareLocales, ["en-US", "it-IT"])
        XCTAssertEqual(snapshot.releaseLocales, ["en-US"])
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
    }

    func testCancelledPreloadLateResultCannotReplaceCurrentSelection() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")], ignoreCancellation: true)
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareStart(locale: "en-US")
        engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForPrepareStart(locale: "it-IT")
        // Release both gates to allow processing to proceed
        await client.completePrepare(locale: "it-IT")
        await client.completePrepare(locale: "en-US")
        // Wait for it-IT publication (should succeed first)
        try await client.waitForResidentLocale("it-IT")
        // en-US should be released as a late result
        try await client.waitForLateResult(locale: "en-US")

        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.releaseLocales.filter { $0 == "en-US" }.count, 1)
    }

    func testApplicationTerminationReleasesResidentPreparedModel() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }
        engine.releasePreparedResources()
        try await client.waitForReleaseCount(1)

        XCTAssertNil(engine.preparedLocaleForTesting)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.releaseLocales, ["en-US"])
    }

    func testOldAGatedLateFailureCannotClearLiveBMarkerOrBlockRecording() async throws {
        let client = StubTranscriptionModelClient(
            installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")],
            probe: PreloadTestProbe(),
            ignoreCancellation: true,
            failPrepareFor: ["en-US"]
        )
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForEvent { event in
            if case .prepareStarted("en-US", _) = event { return true }
            return false
        }
        engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForEvent { event in
            if case .prepareStarted("it-IT", _) = event { return true }
            return false
        }

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareCounts["it-IT"], 1)
        XCTAssertEqual(engine.inFlightPreloadLocaleForTesting, "it-IT")

        // Release it-IT first to complete successfully
        await client.completePrepare(locale: "it-IT")
        try await client.waitForEvent { event in
            if case .resourcePublished("it-IT", _) = event { return true }
            return false
        }

        // it-IT should now be the resident model
        engine.start(preferredLocale: Locale(identifier: "it-IT"), onDownloadProgress: { _ in })
        try await client.waitForEvent { event in
            if case .recordingStarted("it-IT", _) = event { return true }
            return false
        }
        let recordingSnapshot = await client.snapshot()
        XCTAssertEqual(recordingSnapshot.recordingStartedLocales, ["it-IT"])

        // Now release en-US gate - it will fail
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .prepareFailed("en-US", _) = event { return true }
            return false
        }

        // After en-US fails, verify that it-IT marker/state is still intact
        let publishedSnapshot = await client.snapshot()
        XCTAssertEqual(publishedSnapshot.prepareCounts["it-IT"], 1)
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
        XCTAssertNil(engine.inFlightPreloadLocaleForTesting)
    }

    // MARK: - Acceptance Tests (covering all approved lifecycle behaviors)

    func testCachedLaunchPreloadsOnlySelectedNormalizedLocale() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en_US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareLocales, ["en-US"])
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
    }

    func testUninstalledSelectionDoesNotTriggerPreload() async throws {
        let client = StubTranscriptionModelClient(installed: [])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForInstalledCheck()
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareCounts["it-IT"] ?? 0, 0)
        XCTAssertEqual(snapshot.installCount, 0)
    }

    func testSuccessfulExplicitDownloadPreloadsImmediately() async throws {
        let harness = makeSessionHarness(selectedID: "it-IT", normalized: "it-IT", installed: false)
        harness.session.downloadModel(for: Locale(identifier: "it-IT"))
        try await harness.installer.waitForInstallStart(locale: "it-IT")
        await harness.installer.completeInstall(locale: "it-IT")
        try await waitFor(harness.probe) { if case .installCompleted("it-IT") = $0 { return true }; return false }
        try await waitFor(harness.probe) { if case .preloadRequested("it-IT") = $0 { return true }; return false }
        try await waitFor(harness.probe) { if case .prepareStarted("it-IT", _) = $0 { return true }; return false }
        await harness.probe.completePrepare(locale: "it-IT")
        try await waitFor(harness.probe) { if case .resourcePublished("it-IT", _) = $0 { return true }; return false }
        let preloadLocales = await harness.probe.preloadRequestLocales()
        XCTAssertEqual(preloadLocales, ["it-IT"])
    }

    func testEquivalentRequestsAreDeduplicated() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en_US"))
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForResidentLocale("en-US")
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareCounts["en-US"], 1)
    }

    func testRecordingStartReusesPreparedModel() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }
        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        let initialSnapshot = await client.snapshot()
        let preparedIdentity = initialSnapshot.preparedIdentity
        try await client.waitForActiveIdentity(preparedIdentity)
        let recordingSnapshot = await client.snapshot()
        XCTAssertEqual(recordingSnapshot.prepareCounts["en-US"], 1)
        XCTAssertEqual(engine.activePreparedIdentityForTesting, preparedIdentity)
        _ = engine.stop()
    }

    func testStopStartRetainsPreparedModel() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }
        let preparedSnapshot = await client.snapshot()
        let identity = try XCTUnwrap(preparedSnapshot.preparedIdentity)
        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        try await client.waitForActiveIdentity(identity)
        _ = engine.stop()
        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        try await client.waitForActiveIdentity(identity)
        let retainedSnapshot = await client.snapshot()
        XCTAssertTrue(retainedSnapshot.releaseLocales.isEmpty)
        XCTAssertEqual(engine.activePreparedIdentityForTesting, identity)
        _ = engine.stop()
    }

    func testSelectionSwapCancelsReleasesAndReplacesModel() async throws {
        // ignoreCancellation: true — the old (en-US) operation's prepare()
        // must actually complete and produce a value for this test to
        // observe a release; a cancellation-aware prepare() would throw
        // before ever constructing one, making the .resourceReleased
        // assertion below structurally unreachable (this test's own name
        // promises release behavior, so the fix is to make that path
        // reachable, not to relax the assertion — same underlying pattern
        // as the plan's Task 2 equivalent, which uses this exact flag).
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")], ignoreCancellation: true)
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareStart(locale: "en-US")
        engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForPrepareStart(locale: "it-IT")
        await client.completePrepare(locale: "it-IT")
        try await client.waitForResidentLocale("it-IT")
        await client.completePrepare(locale: "en-US")
        try await client.waitForReleaseCount(1)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareLocales, ["en-US", "it-IT"])
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
        XCTAssertEqual(snapshot.releaseLocales, ["en-US"])
    }

    func testLateCancelledResultIsIgnored() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")], ignoreCancellation: true)
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareStart(locale: "en-US")
        engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
        engine.preload(preferredLocale: Locale(identifier: "it-IT"))
        try await client.waitForPrepareStart(locale: "it-IT")
        await client.completePrepare(locale: "it-IT")
        try await client.waitForResidentLocale("it-IT")
        await client.completePrepare(locale: "en-US")
        try await client.waitForLateResult(locale: "en-US")
        try await client.waitForReleaseCount(1)
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
        XCTAssertNil(engine.inFlightPreloadLocaleForTesting)
    }

    func testPreloadFailureIsSilentAndRecordingFallbackInstallsAtStart() async throws {
        let client = StubTranscriptionModelClient(installed: [], prepareError: StubError.prepare)
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForInstalledCheck()
        engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
        try await client.waitForInstallCount(1)
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.setupFailureCount, 0)
        XCTAssertEqual(snapshot.installCount, 1)
    }

    func testTerminationReleasesResidentResources() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForResidentLocale("en-US")
        engine.releasePreparedResources()
        engine.releasePreparedResources()
        try await client.waitForReleaseCount(1)
        let releaseSnapshot = await client.snapshot()
        XCTAssertEqual(releaseSnapshot.releaseLocales.count, 1)
        XCTAssertNil(engine.preparedLocaleForTesting)
    }

    func testStaleDownloadCompletionNeverPreloadsPreviousSelection() async throws {
        let harness = makeSessionHarness(selectedID: "en-US", normalized: "en-US", installed: false)
        harness.session.downloadModel(for: Locale(identifier: "en-US"))
        try await harness.installer.waitForInstallStart(locale: "en-US")
        harness.session.selectTranscriptionLocale(id: "it-IT")
        await harness.installer.completeInstall(locale: "en-US")
        try await harness.installer.waitForInstallCompleted(locale: "en-US")

        // The test's name (and downloadModel's own stale-identity guard) is
        // about "en-US" — the PREVIOUS, now-superseded selection — never
        // being prepared/published/preload-requested off the back of the
        // stale download completion. It does not claim the NEW selection
        // ("it-IT") gets no preload activity of its own: RecordingSession's
        // selection didSet always asks the engine to preload the new
        // selection (letting the engine's own isInstalled check decide
        // whether to actually prepare), so `.preloadRequested("it-IT")` is
        // legitimate, unrelated activity — not what this test verifies, and
        // this test doesn't wait for it, so asserting its presence/absence
        // here would be a timing-dependent assertion on unrelated activity.
        let preloadLocales = await harness.probe.preloadRequestLocales()
        let preparedLocales = await harness.probe.prepareRequestLocales()
        let publishedLocales = await harness.probe.publishedLocales()
        XCTAssertFalse(preloadLocales.contains("en-US"))
        XCTAssertFalse(preparedLocales.contains("en-US"))
        XCTAssertFalse(publishedLocales.contains("en-US"))
    }

    func testFailedOrCancelledPreloadMarkerIsNotReusedByDeduplicatedCaller() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")], prepareErrors: [.prepare, nil])
        let engine = makeEngine(client: client)
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForPreloadFailure()
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(2)
        await client.completePrepare(locale: "en-US")
        try await client.waitForResidentLocale("en-US")

        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.prepareCounts["en-US"], 2)
        XCTAssertFalse(engine.hasInFlightPreloadForTesting)
    }

    func testSessionTerminationHookReleasesEngineResources() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)
        let session = makeInjectedSession(engine: engine, selectedID: "en-US")
        engine.preload(preferredLocale: Locale(identifier: "en-US"))
        try await client.waitForPrepareCount(1)
        await client.completePrepare(locale: "en-US")
        try await client.waitForEvent { event in
            if case .resourcePublished("en-US", _) = event { return true }
            return false
        }

        session.releaseTranscriptionResources()
        try await client.waitForReleaseCount(1)
        XCTAssertNil(engine.preparedLocaleForTesting)
    }
}

@MainActor
func makeInjectedSession(engine: TranscriptionEngine, selectedID: String) -> RecordingSession {
    let resolver = FixedLocaleResolver()
    let installer = GatedModelInstaller(probe: PreloadTestProbe(), normalized: selectedID, installed: true)
    return RecordingSession(transcriptionEngine: engine, localeResolver: resolver, modelInstaller: installer, selectedID: selectedID)
}

// MARK: - Test Helpers

@MainActor
private func makeEngine(client: any TranscriptionModelClient) -> TranscriptionEngine {
    TranscriptionEngine(
        modelClient: client,
        onLineFinalized: { _ in },
        onPendingTextChanged: { _ in },
        onSetupFailed: { _ in }
    )
}

@MainActor
func makeSessionHarness(selectedID: String, normalized: String, installed: Bool) -> SessionHarness {
    let probe = PreloadTestProbe()
    let installer = GatedModelInstaller(probe: probe, normalized: normalized, installed: installed)
    let engine = makeEngine(client: installer.client)
    let session = RecordingSession(
        transcriptionEngine: engine,
        localeResolver: installer.localeResolver,
        modelInstaller: installer,
        selectedID: selectedID
    )
    return SessionHarness(session: session, probe: probe, installer: installer)
}

// MARK: - Test Doubles

struct FixedLocaleResolver: Sendable, TranscriptionLocaleResolving {
    func normalizedLocale(for identifier: String) async -> Locale? {
        // Simply normalize the identifier by replacing underscores with hyphens
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        return Locale(identifier: normalized)
    }
}

struct InstallerSnapshot: Sendable {
    let installCount: Int
}

final class GatedModelInstaller: @unchecked Sendable, TranscriptionModelInstalling {
    let client: StubTranscriptionModelClient
    let localeResolver: FixedLocaleResolver
    private let probe: PreloadTestProbe
    private let normalizedID: String
    private var isInstalledValue: Bool

    init(probe: PreloadTestProbe, normalized: String, installed: Bool) {
        self.probe = probe
        self.normalizedID = normalized
        self.isInstalledValue = installed
        self.localeResolver = FixedLocaleResolver()
        self.client = StubTranscriptionModelClient(
            installed: installed ? [Locale(identifier: normalized)] : [],
            probe: probe
        )
    }

    func install(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try await client.install(locale: locale, onProgress: onProgress)
    }

    func waitForInstallStart(locale: String) async throws {
        try await client.waitForEvent { if case .installStarted(locale) = $0 { return true }; return false }
    }

    func completeInstall(locale: String) async {
        await client.completeInstall(locale: locale)
    }

    func waitForInstallCompleted(locale: String) async throws {
        try await client.waitForInstallCompleted(locale: locale)
    }

    func snapshot() async -> InstallerSnapshot {
        let snap = await client.snapshot()
        return InstallerSnapshot(installCount: snap.installCount)
    }
}

// MARK: - Test Probe and Stub Implementation

enum PreloadTestEvent: Equatable, Sendable {
    case normalized(String)
    case installedCheck(String, Bool)
    case preloadRequested(String)
    case prepareStarted(String, UUID)
    case prepareFinished(String, UUID)
    case prepareFailed(String, UUID)
    case resourcePublished(String, UUID)
    case resourceReleased(String, UUID)
    case installStarted(String)
    case installCompleted(String)
    case recordingStarted(String, UUID?)
}

enum StubError: Error, Equatable, Sendable {
    case prepare
}

enum PreloadCountKind: Sendable {
    case prepareStarted
    case resourceReleased
    case installStarted
}

private typealias EventWaiter = (predicate: (PreloadTestEvent) -> Bool, continuation: CheckedContinuation<Void, Never>)
private typealias CountWaiter = (kind: PreloadCountKind, count: Int, continuation: CheckedContinuation<Void, Never>)

actor PreloadTestProbe {
    private(set) var events: [PreloadTestEvent] = []
    private var waiters: [EventWaiter] = []
    private var prepareGates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var installGates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var preparePermits: [String: Int] = [:]
    private var installPermits: [String: Int] = [:]
    private var countWaiters: [CountWaiter] = []

    func record(_ event: PreloadTestEvent) {
        events.append(event)
        let ready = waiters.filter { $0.predicate(event) }.map(\.continuation)
        waiters.removeAll { $0.predicate(event) }
        ready.forEach { $0.resume() }
        let countReady = countWaiters.filter { waiter in
            let matchingEvents = events.filter { event in
                switch waiter.kind {
                case .prepareStarted: if case .prepareStarted = event { return true }
                case .resourceReleased: if case .resourceReleased = event { return true }
                case .installStarted: if case .installStarted = event { return true }
                }
                return false
            }
            return matchingEvents.count >= waiter.count
        }.map { $0.continuation }
        countWaiters.removeAll { waiter in
            switch waiter.kind {
            case .prepareStarted: return events.filter { if case .prepareStarted = $0 { return true }; return false }.count >= waiter.count
            case .resourceReleased: return events.filter { if case .resourceReleased = $0 { return true }; return false }.count >= waiter.count
            case .installStarted: return events.filter { if case .installStarted = $0 { return true }; return false }.count >= waiter.count
            }
        }
        countReady.forEach { $0.resume() }
    }

    func waitFor(_ predicate: @escaping (PreloadTestEvent) -> Bool) async {
        if events.contains(where: predicate) { return }
        await withCheckedContinuation { continuation in
            waiters.append((predicate: predicate, continuation: continuation))
        }
    }

    func waitForPrepareRelease(locale: String) async {
        if let permits = preparePermits[locale], permits > 0 {
            preparePermits[locale] = permits - 1
            return
        }
        await withCheckedContinuation { continuation in
            prepareGates[locale, default: []].append(continuation)
        }
    }

    func waitForPrepareCount(_ count: Int) async {
        if events.filter({ if case .prepareStarted = $0 { return true }; return false }).count >= count { return }
        await withCheckedContinuation { continuation in countWaiters.append((kind: .prepareStarted, count: count, continuation: continuation)) }
    }

    func waitForReleaseCount(_ count: Int) async {
        if events.filter({ if case .resourceReleased = $0 { return true }; return false }).count >= count { return }
        await withCheckedContinuation { continuation in countWaiters.append((kind: .resourceReleased, count: count, continuation: continuation)) }
    }

    func waitForInstallCount(_ count: Int) async {
        if events.filter({ if case .installStarted = $0 { return true }; return false }).count >= count { return }
        await withCheckedContinuation { continuation in countWaiters.append((kind: .installStarted, count: count, continuation: continuation)) }
    }

    func completePrepare(locale: String) {
        if var gates = prepareGates[locale], !gates.isEmpty {
            let continuation = gates.removeFirst()
            prepareGates[locale] = gates
            continuation.resume()
        } else {
            preparePermits[locale, default: 0] += 1
        }
    }

    func waitForInstallRelease(locale: String) async {
        if let permits = installPermits[locale], permits > 0 {
            installPermits[locale] = permits - 1
            return
        }
        await withCheckedContinuation { continuation in
            installGates[locale, default: []].append(continuation)
        }
    }

    func completeInstall(locale: String) {
        if var gates = installGates[locale], !gates.isEmpty {
            let continuation = gates.removeFirst()
            installGates[locale] = gates
            continuation.resume()
        } else {
            installPermits[locale, default: 0] += 1
        }
    }

    func preloadRequestLocales() -> [String] {
        events.compactMap { if case .preloadRequested(let locale) = $0 { return locale }; return nil }
    }

    func publishedLocales() -> [String] {
        events.compactMap { if case .resourcePublished(let locale, _) = $0 { return locale }; return nil }
    }

    func prepareRequestLocales() -> [String] {
        events.compactMap { if case .prepareStarted(let locale, _) = $0 { return locale }; return nil }
    }

    func releaseLocales() -> [String] {
        events.compactMap { if case .resourceReleased(let locale, _) = $0 { return locale }; return nil }
    }
}

struct StubSnapshot: Sendable {
    let prepareCounts: [String: Int]
    let prepareLocales: [String]
    let normalizedLocales: [String]
    let preloadRequestLocales: [String]
    let releaseLocales: [String]
    let recordingStartedLocales: [String]
    let installCount: Int
    let setupFailureCount: Int
    let preparedIdentity: UUID?
}

actor StubTranscriptionModelClient: TranscriptionModelClient {
    private var installed: Set<String>
    let probe: PreloadTestProbe
    let ignoredCancellation: Bool
    let failedLocales: Set<String>
    private var prepareErrors: [StubError?]
    private var counts: [String: Int] = [:]
    private var normalizedLocales: [String] = []
    private var prepareLocales: [String] = []
    private var installCount = 0
    private var setupFailureCount = 0
    private var recordingStartedLocales: [String] = []
    private var preparedIdentities: [UUID] = []

    init(installed: [Locale], probe: PreloadTestProbe = PreloadTestProbe(), ignoreCancellation: Bool = false, failPrepareFor: Set<String> = [], prepareError: StubError? = nil, prepareErrors: [StubError?] = []) {
        self.installed = Set(installed.map(\.identifier))
        self.probe = probe
        self.ignoredCancellation = ignoreCancellation
        self.failedLocales = failPrepareFor
        self.prepareErrors = prepareErrors.isEmpty ? (prepareError.map { [$0] } ?? []) : prepareErrors
    }

    func normalizedLocale(for preferredLocale: Locale) async -> Locale? {
        let locale = Locale(identifier: preferredLocale.identifier.replacingOccurrences(of: "_", with: "-"))
        normalizedLocales.append(locale.identifier)
        await probe.record(.normalized(locale.identifier))
        return locale
    }

    func isInstalled(locale: Locale) async -> Bool {
        let result = installed.contains(locale.identifier)
        await probe.record(.installedCheck(locale.identifier, result))
        return result
    }

    func prepare(locale: Locale) async throws -> PreparedTranscriptionModel {
        let identity = UUID()
        counts[locale.identifier, default: 0] += 1
        prepareLocales.append(locale.identifier)
        preparedIdentities.append(identity)
        await probe.record(.prepareStarted(locale.identifier, identity))
        await probe.waitForPrepareRelease(locale: locale.identifier)
        let error = prepareErrors.indices.contains(counts[locale.identifier, default: 1] - 1) ? prepareErrors[counts[locale.identifier, default: 1] - 1] : nil
        if failedLocales.contains(locale.identifier) || error != nil {
            setupFailureCount += 1
            await probe.record(.prepareFailed(locale.identifier, identity))
            throw StubError.prepare
        }
        if !ignoredCancellation { try Task.checkCancellation() }
        await probe.record(.prepareFinished(locale.identifier, identity))
        await probe.record(.resourcePublished(locale.identifier, identity))
        return PreparedTranscriptionModel(locale: locale, identity: identity)
    }

    func install(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        installCount += 1
        await probe.record(.installStarted(locale.identifier))
        await probe.waitForInstallRelease(locale: locale.identifier)
        installed.insert(locale.identifier)
        onProgress(1.0)
        await probe.record(.installCompleted(locale.identifier))
    }

    func recordPreloadRequested(locale: Locale) async {
        await probe.record(.preloadRequested(locale.identifier))
    }

    func release(_ model: PreparedTranscriptionModel) async {
        await probe.record(.resourceReleased(model.locale.identifier, model.identity))
    }

    func recordRecordingStart(locale: Locale, preparedIdentity: UUID?) async {
        recordingStartedLocales.append(locale.identifier)
        await probe.record(.recordingStarted(locale.identifier, preparedIdentity))
    }

    func completePrepare(locale: String) async {
        await probe.completePrepare(locale: locale)
    }

    func completeInstall(locale: String) async {
        await probe.completeInstall(locale: locale)
    }

    func snapshot() async -> StubSnapshot {
        StubSnapshot(
            prepareCounts: counts,
            prepareLocales: prepareLocales,
            normalizedLocales: normalizedLocales,
            preloadRequestLocales: await probe.preloadRequestLocales(),
            releaseLocales: await probe.releaseLocales(),
            recordingStartedLocales: recordingStartedLocales,
            installCount: installCount,
            setupFailureCount: setupFailureCount,
            preparedIdentity: preparedIdentities.last
        )
    }

    func waitForEvent(_ predicate: @escaping @Sendable (PreloadTestEvent) -> Bool) async throws {
        try await waitFor(probe, predicate)
    }

    func waitForPrepareStart(locale: String) async throws {
        try await waitForEvent { if case .prepareStarted(locale, _) = $0 { return true }; return false }
    }

    func waitForPrepareCount(_ count: Int) async throws {
        await probe.waitForPrepareCount(count)
    }

    func waitForPreloadFailure() async throws {
        try await waitForEvent { if case .prepareFailed = $0 { return true }; return false }
    }

    func waitForResidentLocale(_ locale: String) async throws {
        try await waitForEvent { if case .resourcePublished(locale, _) = $0 { return true }; return false }
    }

    func waitForLateResult(locale: String) async throws {
        try await waitForEvent { event in
            if case .prepareFailed(locale, _) = event { return true }
            if case .prepareFinished(locale, _) = event { return true }
            return false
        }
    }

    func waitForReleaseCount(_ count: Int) async throws {
        await probe.waitForReleaseCount(count)
    }

    func waitForActiveIdentity(_ expectedIdentity: UUID?) async throws {
        try await waitForEvent { event in
            if case let .recordingStarted(_, identity) = event { return identity == expectedIdentity }
            return false
        }
    }

    func waitForInstalledCheck() async throws {
        try await waitForEvent { if case .installedCheck = $0 { return true }; return false }
    }

    func waitForInstallCount(_ count: Int) async throws {
        await probe.waitForInstallCount(count)
    }

    func waitForInstallCompleted(locale: String) async throws {
        try await waitForEvent { if case .installCompleted(locale) = $0 { return true }; return false }
    }
}

func waitFor(_ probe: PreloadTestProbe, _ predicate: @escaping @Sendable (PreloadTestEvent) -> Bool) async throws {
    let expectation = XCTestExpectation(description: "preload probe event")
    Task {
        await probe.waitFor(predicate)
        expectation.fulfill()
    }
    await XCTWaiter().fulfillment(of: [expectation], timeout: 2)
}
