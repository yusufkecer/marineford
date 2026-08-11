/// Code push for Flutter, without forking the engine.
///
/// Mark the functions you want to be able to fix later with `@patchable` or
/// `@PatchableService`, ship a signed patch to any CDN, and repair broken logic
/// on installed apps without a store release.
///
/// The constraint worth knowing before you start: **code that was not marked
/// before it shipped can never be patched.** There is no compiler fork here, so
/// there is no way to add a branch to machine code that is already compiled.
/// `@patchable` inserts that branch at build time and nowhere else.
///
/// Three things make that livable:
///
/// * A patch rewrites the marked function's whole body, so it can also repair
///   bugs in the unmarked helpers that function calls — it simply stops calling
///   them. Mark above the bug, not on it.
/// * Marking costs a few nanoseconds per call when no patch is active. Mark
///   categories, not individual suspects.
/// * A single marked normalizer on your HTTP client's output absorbs almost any
///   backend contract change on its own.
///
/// Never mark hot loops or per-frame code: crossing into the interpreter costs
/// microseconds, which is nothing for a screen's worth of logic and ruinous per
/// list item.
library;

export 'package:marineford_core/marineford_core.dart'
    show
        AbiFingerprint,
        ApplyPatch,
        MarinefordFormatException,
        PatchDecision,
        PatchEntry,
        PatchManifest,
        PatchRejection,
        RollBackToBase,
        StayOnCurrent;

export 'src/client.dart' show Marineford, MarinefordClient;
export 'src/config.dart' show MarinefordConfig, PatchActivation;
export 'src/dispatch.dart'
    show Patch, PatchFailureHandler, patchedNull, resolveSlots;
export 'src/json_bridge.dart' show MarinefordJson;
export 'src/observer.dart';
export 'src/store.dart' show PatchState, PatchStore;
export 'src/transport.dart'
    show
        HttpPatchTransport,
        PatchTransport,
        PatchTransportException,
        TransportResponse;
