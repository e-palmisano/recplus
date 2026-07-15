# Transcription Model Preload Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preload only the normalized, selected SpeechTranscriber model asynchronously, reuse its prepared analyzer during recording and across stop/start, and preserve the existing download/start fallback without blocking the UI.

**Architecture:** `TranscriptionEngine` becomes the sole owner of the prepared model/analyzer lifecycle. It exposes asynchronous preload, selection invalidation, and final release operations, deduplicates equivalent requests, and hands the prepared resource to `start` instead of constructing a second one. `RecordingSession` remains the `@MainActor` coordinator for selection normalization and explicit downloads; `AudioRecorderApp` wires application termination to release the engine's resident resources. A narrow injectable preparation/installation seam keeps lifecycle tests deterministic and independent of Speech framework availability, model files, network, and real analyzer timing.

**Tech Stack:** Swift 6, macOS 26, Swift Concurrency (`Task`, `AsyncStream`, cancellation), Apple Speech framework (`SpeechTranscriber`, `SpeechAnalyzer`, `AssetInventory`), XCTest, XcodeGen, `Scripts/ci.sh`.

## Global Constraints

- Preload esclusivamente il modello selezionato dall'utente; non precaricare modelli non selezionati o più lingue contemporaneamente.
- Preload asincrono dopo la normalizzazione della lingua e soltanto quando il modello selezionato è già installato.
- Preload immediato al completamento di ogni download esplicito riuscito; un download esplicito fallito conserva il comportamento attuale.
- Il preload non deve bloccare il main thread, l'avvio dell'app, la UI o i comandi della registrazione.
- `TranscriptionEngine` possiede un solo ciclo di vita riutilizzabile per modello preparato/analyzer, una sola risorsa residente e una singola operazione di preload attiva.
- Richieste simultanee equivalenti confluiscono in una sola operazione effettiva; una richiesta duplicata attende o riusa il risultato della prima.
- Il task di preload è cancellabile e verifica l'identità del modello prima di pubblicare il risultato.
- Il completamento di un download esplicito cattura una `NormalizedSelectionIdentity` prima del lavoro asincrono e programma/pubblica preload solo se l'identità coincide ancora con la selezione normalizzata corrente; un completamento obsoleto non prepara né pubblica risorse.
- Il marker condiviso del preload in corso viene pulito atomicamente su successo, errore e cancellazione solo se operazione e generazione corrispondono ancora; un completamento obsoleto non può cancellare il marker di un'operazione più recente.
- I chiamanti deduplicati non conservano né attendono un task fallito o cancellato diventato obsoleto; dopo tale esito una nuova richiesta può partire e `start` continua attraverso il fallback esistente.
- Un cambio di modello o lingua invalida e cancella il preload precedente, rilascia le risorse precedenti e prepara il nuovo modello una sola volta non appena installato.
- Il modello preparato resta residente tra `stop` e `start`; modello e risorse dell'analyzer vengono rilasciati al cambio di selezione e all'uscita dall'app.
- Un errore di preload è non bloccante e silenzioso; il percorso esistente di `start` continua a preparare o scaricare il modello quando il preload non è disponibile.
- La suite esistente deve restare invariata e verde; non modificare UI, formato transcript, mixaggio audio o flusso di registrazione oltre all'uso del modello preparato.
- Usare dipendenze sostituibili o stub per download e preparazione, verificando conteggi, ordine, cancellazione e rilascio senza rete, modelli installati reali o tempi reali dell'analyzer.
- Ogni task termina con un test mirato e un commit separato; la verifica completa è sempre `Scripts/ci.sh`.

---

## File Map

- Modify `AudioRecorder/TranscriptionEngine.swift:5-291`: add the injectable preparation boundary, resident-resource state, deduplicated preload task, selection invalidation/release, prepared-resource reuse in `start`, and cleanup that preserves the prepared resource across `stop`.
- Modify `AudioRecorder/RecordingSession.swift:27-159,168-264`: trigger preload only after normalized selection, trigger it after successful explicit download, pass the selected normalized locale into engine lifecycle methods, and expose a termination-only release hook.
- Modify `AudioRecorder/AudioRecorderApp.swift:4-37`: wire `NSApplication.willTerminateNotification` to the session release hook without introducing a UI control or startup wait.
- Create `AudioRecorderTests/TranscriptionModelPreloadTests.swift`: deterministic lifecycle tests using a stub preparation/install client; keep all existing test files unchanged.
- Do not modify `project.yml`, `Scripts/ci.sh`, or any other application/test file. `project.yml` already includes all files under `AudioRecorder` and `AudioRecorderTests`.

## Shared Interfaces and Test Seams

Use these exact internal types and signatures so later tasks compose without renaming:

```swift
protocol TranscriptionModelClient: Sendable {
    func normalizedLocale(for preferredLocale: Locale) async -> Locale?
    func isInstalled(locale: Locale) async -> Bool
    func prepare(locale: Locale) async throws -> PreparedTranscriptionModel
    func install(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws
    func release(_ model: PreparedTranscriptionModel) async
}

final class PreparedTranscriptionModel: @unchecked Sendable {
    let locale: Locale
    let identity: UUID
    let transcriber: SpeechTranscriber?
    let analyzer: SpeechAnalyzer?
    let format: AVAudioFormat?
    let reservedLocale: Locale?

    init(
        locale: Locale,
        identity: UUID = UUID(),
        transcriber: SpeechTranscriber? = nil,
        analyzer: SpeechAnalyzer? = nil,
        format: AVAudioFormat? = nil,
        reservedLocale: Locale? = nil
    ) {
        self.locale = locale
        self.identity = identity
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        self.reservedLocale = reservedLocale
    }
}
```

```swift
struct NormalizedSelectionIdentity: Equatable, Sendable {
    let generation: Int
    let localeIdentifier: String
}

struct PreloadOperationMarker: Equatable, Sendable {
    let operationID: UUID
    let generation: Int
    let localeIdentifier: String
}
```

The production client wraps `SpeechTranscriber.supportedLocale(equivalentTo:)`, `SpeechTranscriber.installedLocales`, `AssetInventory.assetInstallationRequest`, `SpeechAnalyzer.bestAvailableAudioFormat`, `SpeechAnalyzer.prepareToAnalyze`, and `AssetInventory.release`. The prepared value must contain the real `SpeechTranscriber`, `SpeechAnalyzer`, and `AVAudioFormat` behind an `@unchecked Sendable` reference box in production; the test client returns the lightweight value above. The engine owns the box and is already `@unchecked Sendable`, so no non-Sendable Speech object crosses an unchecked boundary unowned.

The engine initializer becomes:

```swift
init(
    modelClient: any TranscriptionModelClient = SpeechTranscriptionModelClient(),
    onLineFinalized: @escaping (TranscriptLine) -> Void,
    onPendingTextChanged: @escaping (String) -> Void,
    onSetupFailed: @escaping (String) -> Void
)
```

The lifecycle API is:

```swift
func preload(preferredLocale: Locale)
func invalidateSelection(preferredLocale: Locale)
func releasePreparedResources()
func start(preferredLocale: Locale, onDownloadProgress: @escaping @Sendable (Double) -> Void)
@discardableResult func stop() -> [TranscriptLine]
```

`preload` and `invalidateSelection` return immediately and launch/replace a cancellable task. `start` remains synchronous to its caller and retains the current fallback behavior inside its task. `stop` cancels only recording/feed/results work; it does not release the resident prepared resource.

`downloadModel(for:)` captures `NormalizedSelectionIdentity` before awaiting
installation and checks it again after successful installation; only a matching
current identity may call `preload`. The shared in-flight state stores a
`PreloadOperationMarker` and its task. Every terminal path (success, thrown
failure, or cancellation) clears both atomically only when the stored marker
still equals the completing operation's marker. A duplicate request obtains the
current task only while that marker is live; it never awaits a task that has
already failed or been cancelled.

### Task 1: Add the deterministic preparation seam and lifecycle state

**Files:**
- Modify: `AudioRecorder/TranscriptionEngine.swift:5-70`
- Create: `AudioRecorderTests/TranscriptionModelPreloadTests.swift`

**Interfaces:**
- Consumes: existing `TranscriptionEngine` callbacks and `TranscriptionSetupError`.
- Produces: `TranscriptionModelClient`, `PreparedTranscriptionModel`, the injectable initializer, and private state for `preparedModel`, `preloadTask`, `selectionGeneration`, and the active normalized locale.

- [ ] **Step 1: Write the failing test for installed-model preload ownership.**

```swift
import XCTest
@testable import AudioRecorder

final class TranscriptionModelPreloadTests: XCTestCase {
    func testPreloadOfInstalledSelectedLocalePreparesExactlyOneResidentModel() async throws {
        let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
        let engine = makeEngine(client: client)

        engine.preload(preferredLocale: Locale(identifier: "en_US"))
        try await client.waitForPrepareCount(1)

        XCTAssertEqual(client.normalizedLocales, ["en-US"])
        XCTAssertEqual(client.prepareLocales, ["en-US"])
        XCTAssertEqual(client.releaseCount, 0)
        XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
    }
}
```

Add test-only helpers in the same new file before running this test: `makeEngine(client:)`, an actor-backed `StubTranscriptionModelClient`, and an async `waitForPrepareCount(_:)` that polls an actor counter with `Task.sleep(nanoseconds: 1_000_000)` and throws `XCTSkip` only if the timeout is exceeded. Do not use real Speech APIs.

- [ ] **Step 2: Run the focused test to verify the new seam is absent.**

Run:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests/testPreloadOfInstalledSelectedLocalePreparesExactlyOneResidentModel
```

Expected: FAIL during compilation because `TranscriptionModelClient`, the injectable initializer, and `preload` do not yet exist.

- [ ] **Step 3: Add the production/test preparation contracts and state only.**

Implement the exact shared interfaces above. Add private state with these types and invariants:

```swift
private var preparedModel: PreparedTranscriptionModel?
private var preloadTask: Task<Void, Never>?
private var selectionGeneration = 0
private var activePreparedLocale: Locale?

#if DEBUG
var preparedLocaleForTesting: Locale? { preparedModel?.locale }
#endif
```

Keep the real Speech fields (`analyzer`, `transcriber`, `targetFormat`, and `reservedLocale`) intact until Task 3; the seam is introduced without changing recording behavior yet. Make the stub actor record normalized locale, installed checks, prepare calls, release calls, and cancellation.

- [ ] **Step 4: Run the focused test to verify the contract compiles and the behavior still fails.**

Run the same `xcodebuild ... -only-testing` command.

Expected: PASS for compilation, then FAIL because `preload` has no implementation and `prepareLocales` remains empty.

- [ ] **Step 5: Commit the seam and state.**

```bash
git add AudioRecorder/TranscriptionEngine.swift AudioRecorderTests/TranscriptionModelPreloadTests.swift
git commit -m "test: add transcription model lifecycle seam"
```

### Task 2: Implement installed-only asynchronous preload and deduplication

**Files:**
- Modify: `AudioRecorder/TranscriptionEngine.swift:53-70,72-159`
- Modify: `AudioRecorderTests/TranscriptionModelPreloadTests.swift:1-end`

**Interfaces:**
- Consumes: `TranscriptionModelClient`, `PreparedTranscriptionModel`, and generation state from Task 1.
- Produces: `preload(preferredLocale:)` with one in-flight task per equivalent locale, silent failure, installed-only behavior, and stale-result protection.

- [ ] **Step 1: Add failing tests for non-installed selection and concurrent deduplication.**

```swift
func testPreloadDoesNotPrepareAnUninstalledSelectedLocale() async throws {
    let client = StubTranscriptionModelClient(installed: [])
    let engine = makeEngine(client: client)

    engine.preload(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForInstalledCheck()
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertTrue(client.prepareLocales.isEmpty)
    XCTAssertNil(engine.preparedLocaleForTesting)
}

func testEquivalentConcurrentPreloadsShareOnePreparationOperation() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")], prepareDelay: 50_000_000)
    let engine = makeEngine(client: client)

    engine.preload(preferredLocale: Locale(identifier: "en_US"))
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    try await Task.sleep(nanoseconds: 75_000_000)

    XCTAssertEqual(client.prepareLocales, ["en-US"])
    XCTAssertEqual(client.prepareCount, 1)
}

func testEquivalentRequestAfterFailedPreloadDoesNotAwaitStaleTask() async throws {
    let client = StubTranscriptionModelClient(
        installed: [Locale(identifier: "en-US")],
        prepareErrors: [.prepare, nil]
    )
    let engine = makeEngine(client: client)

    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    try await client.waitForPreloadFailure()
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(2)

    XCTAssertEqual(client.prepareLocales, ["en-US", "en-US"])
    XCTAssertEqual(client.prepareCount, 2)
    XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
}

func testEquivalentRequestAfterCancelledPreloadDoesNotAwaitStaleTask() async throws {
    let client = StubTranscriptionModelClient(
        installed: [Locale(identifier: "en-US")],
        prepareDelay: 200_000_000,
        ignoreCancellation: false
    )
    let engine = makeEngine(client: client)

    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareStart(locale: "en-US")
    engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(2)

    XCTAssertEqual(client.prepareCount, 2)
}
```

- [ ] **Step 2: Run the two focused tests to verify they fail.**

Run:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests
```

Expected: the tests compile and fail because no preload task performs installation checks, preparation, or stale-operation cleanup.

- [ ] **Step 3: Implement the minimal cancellable preload state machine.**

Resolve the preferred locale before creating the operation marker. Under the
serialized preload state, compare the normalized locale identifier with the
resident model and the live marker. An equivalent request returns the live task
without incrementing the generation or creating another task. A request after a
failure or cancellation observes no live marker and creates a fresh operation.
Each new operation receives a unique `operationID`, captures the current
selection generation and normalized locale identifier, and publishes the marker
and task together.

The operation must perform, in this order: installed check; cancellation check;
preparation; cancellation check; atomic marker/generation/locale validation;
publication of the prepared model. On every terminal path—successful
publication, `CancellationError`, cancellation detected after preparation, or
any other thrown error—run one serialized cleanup that clears the shared marker
and task only if both still match the completing `PreloadOperationMarker` and
generation. A late completion that no longer matches must release its prepared
value and must not overwrite resident state or a newer marker. Cleanup and
publication are one atomic state transition from the point of view of other
preload callers. Keep all preload errors and selection-cancellation errors
silent.

- [ ] **Step 4: Run the focused tests to verify installed-only preload and deduplication.**

Run the same focused-suite command.

Expected: PASS, with one `prepare` call for the installed equivalent locale, zero calls for the uninstalled locale, and a second operation after each stale failed/cancelled operation.

- [ ] **Step 5: Commit the preload state machine.**

```bash
git add AudioRecorder/TranscriptionEngine.swift AudioRecorderTests/TranscriptionModelPreloadTests.swift
git commit -m "feat: preload selected transcription model asynchronously"
```

### Task 3: Connect production Speech preparation and reuse it at recording start

**Files:**
- Modify: `AudioRecorder/TranscriptionEngine.swift:53-159,180-195,250-290`
- Modify: `AudioRecorderTests/TranscriptionModelPreloadTests.swift:1-end`

**Interfaces:**
- Consumes: the deduplicated preload result from Task 2.
- Produces: `SpeechTranscriptionModelClient`, a prepared resource containing the real transcriber/analyzer/format/reservation, and `start` logic that reuses it without a second preparation operation.

- [ ] **Step 1: Add the failing reuse and stop/start retention tests.**

```swift
func testStartReusesPreparedModelInsteadOfPreparingAgain() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)

    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    XCTAssertEqual(client.prepareCount, 1)
    XCTAssertEqual(engine.activePreparedIdentityForTesting, client.preparedIdentity)
    _ = engine.stop()
    XCTAssertEqual(client.releaseCount, 0)

    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    try await client.waitForActiveIdentity(client.preparedIdentity)
    XCTAssertEqual(client.prepareCount, 1)
    XCTAssertEqual(engine.activePreparedIdentityForTesting, client.preparedIdentity)
    _ = engine.stop()
}

func testPreloadFailureIsSilentAndStartStillUsesDownloadFallback() async throws {
    let client = StubTranscriptionModelClient(installed: [], prepareError: StubError.prepare)
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForInstalledCheck()
    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    try await client.waitForInstallCount(1)

    XCTAssertEqual(client.installCount, 1)
    XCTAssertEqual(client.setupFailureCount, 0)
}
```

The stub's `start` counter represents the engine consuming the prepared resource; the production client implements the equivalent analyzer input sequence internally. Remove the unused local `setupFailures` if the chosen stub does not expose a setup callback; the assertion must instead verify no `onSetupFailed` callback occurred during preload.

- [ ] **Step 2: Run the focused reuse/fallback tests to verify they fail.**

Run:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests/testStartReusesPreparedModelInsteadOfPreparingAgain -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests/testPreloadFailureIsSilentAndStartStillUsesDownloadFallback
```

Expected: FAIL because `start` still creates a fresh transcriber/analyzer and `stop` currently releases its active resources without a reusable prepared-resource path.

- [ ] **Step 3: Implement `SpeechTranscriptionModelClient` and prepared-resource reuse.**

Move the current Speech setup sequence into the production client while preserving the required order: normalize locale, create transcriber, install if needed for recording fallback, resolve `bestAvailableAudioFormat`, create analyzer, call `prepareToAnalyze`, and reserve/release the locale. A prepared resource must carry the `SpeechTranscriber`, `SpeechAnalyzer`, `AVAudioFormat`, normalized locale, and reservation token/reference. `TranscriptionEngine.start` first checks for a prepared resource with the normalized requested locale; if present it assigns the existing analyzer/transcriber/format and starts the existing results/feed pipeline. If absent, it runs the unchanged current setup path through the client, including download progress and fallback errors.

Do not call `prepare` from `start` when a matching resident resource exists. `stop` must cancel `feedTask`, finish the input stream, finalize pending text, detach results, and finalize/release only the per-recording analyzer resource. If the resource is the resident prepared resource, retain it and its reservation; the next `start` must reuse the same identity. Keep the existing `onDownloadProgress(1.0)` behavior on every terminal setup path.

- [ ] **Step 4: Run the focused tests and inspect preparation counts.**

Run the focused suite command from Task 2.

Expected: PASS; cached start uses the same prepared identity, stop does not release it, and a preload failure causes no user-facing setup callback while start still performs the existing install fallback.

- [ ] **Step 5: Commit production preparation and reuse.**

```bash
git add AudioRecorder/TranscriptionEngine.swift AudioRecorderTests/TranscriptionModelPreloadTests.swift
git commit -m "feat: reuse prepared transcription analyzer during recording"
```

### Task 4: Wire normalized selection and explicit download completion

**Files:**
- Modify: `AudioRecorder/RecordingSession.swift:27-41,83-159,168-264`
- Modify: `AudioRecorderTests/TranscriptionModelPreloadTests.swift:1-end`

**Interfaces:**
- Consumes: `TranscriptionEngine.preload`, `invalidateSelection`, and the existing explicit download path.
- Produces: preload after normalized launch selection, no preload for uninstalled selections, and immediate preload after successful explicit download.

- [ ] **Step 1: Add failing coordinator tests for launch normalization and download completion.**

Because `RecordingSession` currently constructs its engine lazily and reads real Speech inventories, add an internal initializer used only by tests:

```swift
init(
    transcriptionEngine: TranscriptionEngine,
    localeResolver: any TranscriptionLocaleResolving,
    modelInstaller: any TranscriptionModelInstalling
)
```

Define the exact test-facing interfaces:

```swift
protocol TranscriptionLocaleResolving: Sendable {
    func normalizedLocale(for identifier: String) async -> Locale?
}

protocol TranscriptionModelInstalling: Sendable {
    func install(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void) async throws
}
```

Test the coordinator with a stub engine/client and assert:

```swift
func testNormalizedLaunchSelectionPreloadsOnlyResolvedInstalledLocale() async throws {
    let harness = makeSessionHarness(selectedID: "en_US", normalized: "en-US", installed: true)
    harness.session.preloadSelectedModelAfterNormalization()
    try await harness.engine.waitForPreload(locale: "en-US")
    XCTAssertEqual(harness.engine.preloadRequests, ["en-US"])
}

func testSuccessfulExplicitDownloadStartsPreloadImmediately() async throws {
    let harness = makeSessionHarness(selectedID: "it-IT", normalized: "it-IT", installed: false)
    harness.session.downloadModel(for: Locale(identifier: "it-IT"))
    try await harness.engine.waitForDownloadAndPreload()
    XCTAssertEqual(harness.installer.installCount, 1)
    XCTAssertEqual(harness.engine.preloadRequests, ["it-IT"])
}

func testStaleExplicitDownloadCompletionDoesNotPrepareOrPublishOldSelection() async throws {
    let harness = makeSessionHarness(
        selectedID: "en-US",
        normalized: "en-US",
        installed: false,
        installDelay: 200_000_000
    )

    harness.session.downloadModel(for: Locale(identifier: "en-US"))
    try await harness.installer.waitForInstallStart(locale: "en-US")
    harness.session.selectTranscriptionLocale(id: "it-IT")
    try await harness.installer.completeInstall(locale: "en-US")
    try await harness.engine.waitForDownloadCompletion(locale: "en-US")
    try await Task.sleep(nanoseconds: 50_000_000)

    XCTAssertEqual(harness.engine.preloadRequests, [])
    XCTAssertEqual(harness.engine.publishedPreparedLocales, [])
    XCTAssertEqual(harness.engine.prepareRequests, [])
}
```

- [ ] **Step 2: Run the coordinator tests to verify the hooks are absent.**

Run:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests/testNormalizedLaunchSelectionPreloadsOnlyResolvedInstalledLocale -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests/testSuccessfulExplicitDownloadStartsPreloadImmediately
```

Expected: FAIL during compilation because the injected coordinator initializer, selection identity capture, and preload hook do not exist.

- [ ] **Step 3: Wire selection changes and post-normalization launch preload.**

Keep `selectedTranscriptionLocaleID` as the persisted source of truth. In `init`'s existing supported-locale task, after resolving the persisted/system identifier to the framework-supported identifier, call `preloadSelectedModelAfterNormalization()` exactly once. In `didSet`, call `transcriptionEngine.invalidateSelection(preferredLocale:)` immediately, then run the existing installed check; if installed, call `preloadSelectedModelAfterNormalization()`, otherwise preserve `modelDownloadPromptLocale` and do not preload. The method must resolve the identifier through the injected resolver/framework before asking the engine to preload, so `en_US` and `en-US` become one request.

Maintain one monotonic selection generation in the coordinator. Increment it
when the selected identifier changes, and derive the current
`NormalizedSelectionIdentity` only after normalization. The identity captured
by `downloadModel(for:)` must include that generation and the normalized locale
identifier; comparing only the raw requested string is insufficient.

- [ ] **Step 4: Start preload only after an explicit download succeeds.**

In `downloadModel(for:)`, first resolve and capture the current
`NormalizedSelectionIdentity` (generation plus normalized locale identifier)
before the first `await` that installs the requested locale. Leave progress,
`isDownloadingModel`, and the existing error string unchanged. After
`downloadAndInstall()` returns successfully, re-resolve/read the current
normalized selection identity in the coordinator's serialized state. Invoke
`transcriptionEngine.preload(preferredLocale:)` only when the captured identity
still equals the current identity. If it differs, record the successful
installation if the existing UI state requires it, but do not call preload,
do not ask the engine to prepare the old locale, and do not publish a prepared
resource for it. Do not invoke preload in the `catch` block or before
installation completes. Ensure concurrent explicit downloads remain guarded by
`isDownloadingModel`.

The stale-completion test must hold installation at an explicit gate, change
the selected locale while installation is suspended, release the gate, and
assert zero old-locale preload requests, zero prepare calls, and zero published
old-locale resources. It must not rely on a timing race or an unbounded sleep.

- [ ] **Step 5: Run the coordinator tests and the existing download-related build.**

Run the two focused tests, then:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

Expected: all three coordinator tests PASS—including the deterministic stale-download completion test—and the application build succeeds without UI or transcript changes.

- [ ] **Step 6: Commit selection/download wiring.**

```bash
git add AudioRecorder/RecordingSession.swift AudioRecorderTests/TranscriptionModelPreloadTests.swift
git commit -m "feat: preload normalized model after selection and download"
```

### Task 5: Implement selection swap cancellation, stale-result rejection, and release

**Files:**
- Modify: `AudioRecorder/TranscriptionEngine.swift:53-159,250-290`
- Modify: `AudioRecorder/RecordingSession.swift:27-41,83-159`
- Modify: `AudioRecorderTests/TranscriptionModelPreloadTests.swift:1-end`

**Interfaces:**
- Consumes: normalized selection and preload wiring from Task 4.
- Produces: `invalidateSelection(preferredLocale:)` that cancels/release/switches resources, ignores late cancelled results, and `releasePreparedResources()` for app termination.

- [ ] **Step 1: Add failing race, swap, and release tests.**

```swift
func testSelectionSwapCancelsOldPreloadReleasesOldModelAndPreparesNewModelOnce() async throws {
    let client = StubTranscriptionModelClient(
        installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")],
        prepareDelays: ["en-US": 200_000_000, "it-IT": 10_000_000]
    )
    let engine = makeEngine(client: client)

    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareStart(locale: "en-US")
    engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForResidentLocale("it-IT")
    try await Task.sleep(nanoseconds: 250_000_000)

    XCTAssertEqual(client.prepareLocales, ["en-US", "it-IT"])
    XCTAssertEqual(client.releaseLocales, ["en-US"])
    XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
}

func testCancelledPreloadLateResultCannotReplaceCurrentSelection() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")], ignoreCancellation: true)
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareStart(locale: "en-US")
    engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForResidentLocale("it-IT")
    try await client.releaseLateResult("en-US")

    XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
    XCTAssertEqual(client.releaseLocales.filter { $0 == "en-US" }.count, 1)
}

func testApplicationTerminationReleasesResidentPreparedModel() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    engine.releasePreparedResources()
    try await client.waitForReleaseCount(1)

    XCTAssertNil(engine.preparedLocaleForTesting)
    XCTAssertEqual(client.releaseLocales, ["en-US"])
}

func testPreloadMarkerClearsOnlyForMatchingOperationOnSuccessFailureAndCancellation() async throws {
    let client = StubTranscriptionModelClient(
        installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")],
        prepareErrors: [nil, .prepare, nil],
        prepareDelays: ["it-IT": 200_000_000]
    )
    let engine = makeEngine(client: client)

    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    try await client.waitForPreloadCompletion(locale: "en-US")
    XCTAssertFalse(engine.hasInFlightPreloadForTesting)

    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(2)
    try await client.waitForPreloadFailure()
    XCTAssertFalse(engine.hasInFlightPreloadForTesting)

    engine.preload(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForPrepareStart(locale: "it-IT")
    engine.invalidateSelection(preferredLocale: Locale(identifier: "en-US"))
    XCTAssertFalse(engine.hasInFlightPreloadForTesting)
}
```

- [ ] **Step 2: Run the race/release tests to verify they fail.**

Run:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests
```

Expected: the new tests fail because selection invalidation, matching marker cleanup, and final release are not implemented.

- [ ] **Step 3: Implement generation-checked invalidation.**

Implement `invalidateSelection(preferredLocale:)` to synchronously cancel the old `preloadTask`, increment the generation, detach and asynchronously release the current resident model, clear `preparedModel`/`activePreparedLocale`, and then call `preload(preferredLocale:)` only after the caller has established that the new locale is installed. Do not treat `CancellationError` from the old task as a user-facing failure. Every completion path must compare both generation and normalized locale before publishing; a late result must be released, never assigned.

The invalidation transition must also atomically replace the shared
`PreloadOperationMarker`/task state before launching the new operation. The old
operation's cancellation cleanup may clear the marker only if its captured
operation ID and generation still match; otherwise it must leave the new
marker untouched. Apply the same matching cleanup on successful publication,
ordinary failure, and cancellation. A deduplicated caller must read the marker
and task from this serialized state; it must never retain or await an operation
after that operation has reached a failed or cancelled terminal state. If
recording starts while no live preload marker exists, it must immediately use
the existing setup/download fallback rather than await the stale task.

- [ ] **Step 4: Implement idempotent final release.**

Implement `releasePreparedResources()` to cancel the preload task, increment the generation, synchronously clear resident references, and launch exactly one asynchronous `modelClient.release` for the captured prepared model. Make repeated calls no-ops. Keep this method separate from `stop()` so stop/start retention remains explicit and testable.

- [ ] **Step 5: Run the race/release tests and the full suite.**

Run the focused suite, then:

```bash
Scripts/ci.sh
```

Expected: all lifecycle tests pass; `Scripts/ci.sh` ends with `CI OK` and no existing test regressions.

- [ ] **Step 6: Commit invalidation and release behavior.**

```bash
git add AudioRecorder/TranscriptionEngine.swift AudioRecorder/RecordingSession.swift AudioRecorderTests/TranscriptionModelPreloadTests.swift
git commit -m "fix: cancel stale transcription model preloads safely"
```

### Task 6: Wire application termination and complete lifecycle acceptance coverage

**Files:**
- Modify: `AudioRecorder/AudioRecorderApp.swift:4-37`
- Modify: `AudioRecorder/RecordingSession.swift:17-19,83-103`
- Modify: `AudioRecorderTests/TranscriptionModelPreloadTests.swift:1-end`

**Interfaces:**
- Consumes: `RecordingSession.releaseTranscriptionResources()` and the engine release API from Task 5.
- Produces: app-termination cleanup and complete acceptance tests for cached launch preload, immediate post-download preload, deduplication, recording reuse, swap race, silent failure, stop/start retention, and cleanup.

- [ ] **Step 1: Add the failing app-termination wiring test.**

```swift
func testSessionTerminationHookReleasesEngineResources() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    let session = makeInjectedSession(engine: engine, selectedID: "en-US")
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)

    session.releaseTranscriptionResources()
    try await client.waitForReleaseCount(1)
    XCTAssertNil(engine.preparedLocaleForTesting)
}
```

- [ ] **Step 2: Run the focused termination test to verify it fails.**

Run:

```bash
xcodegen generate
xcodebuild -project AudioRecorder.xcodeproj -scheme AudioRecorder -configuration Debug -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test -only-testing:AudioRecorderTests/TranscriptionModelPreloadTests/testSessionTerminationHookReleasesEngineResources
```

Expected: FAIL because `releaseTranscriptionResources()` and app termination notification wiring do not exist.

- [ ] **Step 3: Add the termination-only session hook and notification wiring.**

Add to `RecordingSession`:

```swift
func releaseTranscriptionResources() {
    transcriptionEngine.releasePreparedResources()
}
```

In `AudioRecorderApp.body`, keep the existing `WindowGroup` and commands unchanged and add a notification handler to the scene content:

```swift
WindowGroup {
    ContentView(session: session)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session.releaseTranscriptionResources()
        }
}
```

Import `Foundation` only if needed for `NotificationCenter`; do not add a visible control, await preload in `init`, or change `@State private var session = RecordingSession()`.

- [ ] **Step 4: Add explicit acceptance tests for every approved lifecycle criterion.**

Ensure `TranscriptionModelPreloadTests.swift` contains named tests for all of these behaviors, using the stub's recorded events and exact assertions rather than sleeps alone:

```swift
func testCachedLaunchPreloadsOnlySelectedNormalizedLocale() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en_US"))
    try await client.waitForPrepareCount(1)
    XCTAssertEqual(client.prepareLocales, ["en-US"])
    XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "en-US")
}

func testUninstalledSelectionDoesNotTriggerPreload() async throws {
    let client = StubTranscriptionModelClient(installed: [])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForInstalledCheck()
    XCTAssertEqual(client.prepareCount, 0)
    XCTAssertEqual(client.installCount, 0)
}

func testSuccessfulExplicitDownloadPreloadsImmediately() async throws {
    let harness = makeSessionHarness(selectedID: "it-IT", normalized: "it-IT", installed: false)
    harness.session.downloadModel(for: Locale(identifier: "it-IT"))
    try await harness.engine.waitForEventSequence([.installCompleted("it-IT"), .preloadStarted("it-IT"), .preloadCompleted("it-IT")])
    XCTAssertEqual(harness.engine.preloadRequests, ["it-IT"])
}

func testEquivalentRequestsAreDeduplicated() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")], prepareDelay: 50_000_000)
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en_US"))
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    XCTAssertEqual(client.prepareCount, 1)
}

func testRecordingStartReusesPreparedModel() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    try await client.waitForActiveIdentity(client.preparedIdentity)
    XCTAssertEqual(client.prepareCount, 1)
    XCTAssertEqual(engine.activePreparedIdentityForTesting, client.preparedIdentity)
    _ = engine.stop()
}

func testStopStartRetainsPreparedModel() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    let identity = try XCTUnwrap(client.preparedIdentity)
    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    _ = engine.stop()
    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    try await client.waitForActiveIdentity(identity)
    XCTAssertEqual(client.releaseCount, 0)
    XCTAssertEqual(engine.activePreparedIdentityForTesting, identity)
    _ = engine.stop()
}

func testSelectionSwapCancelsReleasesAndReplacesModel() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")], prepareDelays: ["en-US": 200_000_000, "it-IT": 10_000_000])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareStart(locale: "en-US")
    engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForResidentLocale("it-IT")
    XCTAssertEqual(client.prepareLocales, ["en-US", "it-IT"])
    XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
    XCTAssertEqual(client.releaseLocales, ["en-US"])
}

func testLateCancelledResultIsIgnored() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US"), Locale(identifier: "it-IT")], ignoreCancellation: true)
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareStart(locale: "en-US")
    engine.invalidateSelection(preferredLocale: Locale(identifier: "it-IT"))
    try await client.waitForResidentLocale("it-IT")
    try await client.waitForLateResult(locale: "en-US")
    XCTAssertEqual(engine.preparedLocaleForTesting?.identifier, "it-IT")
}

func testPreloadFailureIsSilentAndRecordingFallbackInstallsAtStart() async throws {
    let client = StubTranscriptionModelClient(installed: [], prepareError: StubError.prepare)
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForInstalledCheck()
    engine.start(preferredLocale: Locale(identifier: "en-US"), onDownloadProgress: { _ in })
    try await client.waitForInstallCount(1)
    XCTAssertEqual(client.setupFailureCount, 0)
    XCTAssertEqual(client.installCount, 1)
}

func testTerminationReleasesResidentResources() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(1)
    engine.releasePreparedResources()
    engine.releasePreparedResources()
    try await client.waitForReleaseCount(1)
    XCTAssertEqual(client.releaseCount, 1)
    XCTAssertNil(engine.preparedLocaleForTesting)
}

func testStaleDownloadCompletionNeverPreloadsPreviousSelection() async throws {
    let harness = makeSessionHarness(selectedID: "en-US", normalized: "en-US", installed: false, installDelay: 200_000_000)
    harness.session.downloadModel(for: Locale(identifier: "en-US"))
    try await harness.installer.waitForInstallStart(locale: "en-US")
    harness.session.selectTranscriptionLocale(id: "it-IT")
    try await harness.installer.completeInstall(locale: "en-US")
    try await harness.installer.waitForInstallCompleted(locale: "en-US")

    XCTAssertEqual(harness.engine.preloadRequests, [])
    XCTAssertEqual(harness.engine.prepareRequests, [])
    XCTAssertEqual(harness.engine.publishedPreparedLocales, [])
}

func testFailedOrCancelledPreloadMarkerIsNotReusedByDeduplicatedCaller() async throws {
    let client = StubTranscriptionModelClient(installed: [Locale(identifier: "en-US")], prepareErrors: [.prepare, nil])
    let engine = makeEngine(client: client)
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPreloadFailure()
    engine.preload(preferredLocale: Locale(identifier: "en-US"))
    try await client.waitForPrepareCount(2)

    XCTAssertEqual(client.prepareCount, 2)
    XCTAssertFalse(engine.hasInFlightPreloadForTesting)
}
```

Each test must use `waitForEvent`/actor state, assert event order (`install.completed < preload.started`), use an explicit installation gate for stale-download completion, and use a bounded timeout so a deadlocked task fails deterministically. Do not change existing tests.

- [ ] **Step 5: Run the complete verification command and inspect its terminal output.**

Run:

```bash
Scripts/ci.sh
```

Expected: XcodeGen regenerates the project, the Debug build succeeds, all `AudioRecorderTests` pass including the stale-download and marker-lifecycle tests, and the final line is `CI OK`.

- [ ] **Step 6: Commit the app cleanup and complete acceptance suite.**

```bash
git add AudioRecorder/AudioRecorderApp.swift AudioRecorder/RecordingSession.swift AudioRecorderTests/TranscriptionModelPreloadTests.swift
git commit -m "test: cover transcription model preload lifecycle"
```

### Task 7: Final review and regression verification

**Files:**
- Review only: `docs/superpowers/specs/2026-07-15-transcription-model-preload-design.md`
- Review only: `AudioRecorder/TranscriptionEngine.swift`
- Review only: `AudioRecorder/RecordingSession.swift`
- Review only: `AudioRecorder/AudioRecorderApp.swift`
- Review only: `AudioRecorderTests/TranscriptionModelPreloadTests.swift`

**Interfaces:**
- Consumes: all implementation and tests from Tasks 1-6.
- Produces: a verified implementation with no scope drift, no placeholders, and consistent Swift types/signatures.

- [ ] **Step 1: Run the full verification command.**

```bash
Scripts/ci.sh
```

Expected: final output contains `CI OK`.

- [ ] **Step 2: Perform the spec coverage review.**

Check each approved requirement against the plan and implementation: selected-only preload; normalized locale; installed-only launch preload; immediate successful-download preload; stale explicit-download completion rejection with no old-locale prepare/publication; no UI/start blocking; one resident model/analyzer; one in-flight operation; matching marker cleanup on success/failure/cancellation; deduplicated-caller recovery after failed/cancelled tasks; stop/start retention; selection cancellation and release; stale-result rejection; termination release; silent preload failure; existing install/start fallback; no UI/transcript/mix changes; deterministic dependency stubs. Record no new behavior outside the three approved production files and the new lifecycle test file.

- [ ] **Step 3: Perform the placeholder and type-consistency review.**

Search the plan and implementation for unfinished markers, unresolved ellipses, undefined helper names, and mismatched signatures. Confirm the shared names remain exactly `TranscriptionModelClient`, `PreparedTranscriptionModel`, `NormalizedSelectionIdentity`, `PreloadOperationMarker`, `preload(preferredLocale:)`, `invalidateSelection(preferredLocale:)`, `releasePreparedResources()`, `TranscriptionLocaleResolving`, `TranscriptionModelInstalling`, and `releaseTranscriptionResources()`.

- [ ] **Step 4: Confirm source/test scope and report the final verification result.**

Run:

```bash
git status --short
git diff --check
```

Expected: only the three approved application files plus `AudioRecorderTests/TranscriptionModelPreloadTests.swift` are changed by implementation commits; no unrelated source, UI, audio, transcript, or existing test file is modified. Report any generated Xcode project changes separately rather than silently including them.

- [ ] **Step 5: Commit only if the review produced a correction.**

If a correction was required, run `Scripts/ci.sh` again and commit it with:

```bash
git commit -m "fix: complete transcription preload lifecycle review"
```

Otherwise, make no empty review commit.

## Self-Review Outcome

- **Spec coverage:** Every requirement in the approved design is mapped to Tasks 1-7, including stale download completion, matching marker cleanup for all terminal paths, deduplicated-caller recovery, all lifecycle test categories, and both fallback paths.
- **Placeholder scan:** The executable plan contains concrete interfaces, paths, symbols, test bodies/pseudocode, commands, expected outputs, and commit commands; no behavior is left undefined.
- **Type consistency:** The same `TranscriptionModelClient`, `PreparedTranscriptionModel`, `NormalizedSelectionIdentity`, `PreloadOperationMarker`, locale resolver, installer, engine lifecycle methods, and session termination hook are used across all tasks; operation/generation matching is explicit in every cleanup path.
- **Scope:** No UI, transcript format, mix, or unrelated application area is included. The plan modifies only the three approved integration files and adds one focused lifecycle test file.
