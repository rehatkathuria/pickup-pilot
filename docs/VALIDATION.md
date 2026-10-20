# Pickup Pilot validation

Recorded on **October 17, 2026** for the retained Safari release archive: **476 tests in 37 suites passed in Debug (49.248 seconds) and Release (44.424 seconds)**. Whole-production Swift coverage was **6468/6859 (94.30%)** for the suite and **6541/6859 (95.36%)** including the asserted disarmed app launch. Coverage remained below 100%; embedded JavaScript coverage was unmeasured. These are historical results, not a new test or GitHub CI run.

Production checkout uses a dedicated normal Safari window through Safari’s public Apple Events interface. Safari owns the normal website session; the app never imports, exports, restores or clears Safari cookies. Profiles and the one-order journal remain app-scoped Keychain data. System Automation permission and Safari Settings → Developer → Automation → Allow JavaScript from Apple Events are required and are never enabled by the app.

Guest checkout remains mandatory. Unavailable guest controls, challenges and ambiguous results stop preparation without asking for sign-in or retrying a confirmed dispatch. Final payment confirmation, exact review/document/payment-state checks and the durable uncertain-order lock remain required. Native review-only code cannot dispatch the final order. Safari’s own manual order control may remain available; do not place the order in Safari during that test.

Safari does not expose main-document HTTP response metadata or document-start injection through this integration. Only actually observed response codes are shown. Page Not Found is distinct from a separately observed access/rate-limit response; missing evidence is not success. The earlier HTTP 541 does not establish Apple’s server-side reason, and no human-emulation or challenge-bypass mechanism is implemented.

## Recorded release evidence

The original local source manifest bound the release source, tests, scripts and root documentation to the Debug and Release build snapshot. The retained Release ZIP was extracted, strictly signature-verified and launched visibly disarmed. Repository publication changes documentation and clean-clone build setup; it does not convert the earlier tests into a new run. Generated manifests, local diagnostics and installation records are excluded from this repository.

- Mocked Safari transport/page tests cover owned-window identity, trusted documents, setup errors, cancellation and late-result cleanup. No default test opens Safari or Apple.
- Native WebKit fixtures still execute checkout JavaScript and synthetic product, bag, guest, pickup, contact, payment and review flows. They do not establish Safari or merchant acceptance.
- Rehearsal/coordinator tests verify guest-only stops, terminal Safari setup failure, fresh inputs after failure, native review-only refusal and durable uncertainty across restart.
- Rendered SwiftUI tests verify Safari status/setup guidance and absence of an embedded production browser, along with retained selection, arming, observation, payment and error states.
- Synthetic catalog, travel, cadence/backoff, no-overlap, profile and Keychain tests retain their separate scopes.

## Actual Safari integration

The opt-in actual Safari check is not verified. Recorded result: javascriptDisabled. Default mocks do not prove Automation permission or Safari JavaScript execution.

## Skipped tests

- `publicTorontoLandmarksResolveAndReturnLiveDrivingETA()` (live Apple Maps).
- `productionCheckoutTimingBenchmark()` (optional local benchmark).

## Historical evidence and limits

Local live-checkout probe reports predated the retained Safari revision and are not published in this repository. An earlier Safari private window reached blank pickup contact fields; earlier WebKit/Chrome probes recorded access errors. These do not prove current production Safari final review, paid purchase, bank acceptance or Apple latency. The original guest HTTP 541 cause remains unproven. Recorded native screen rendering was not full desktop pointer/keyboard coverage. The app remains ad hoc signed and requires a running awake Mac.

See [test results](TEST-RESULTS.md), [coverage](COVERAGE.md) and [performance notes](PERFORMANCE.md) for the corresponding scope. The [quickstart](QUICKSTART.md) describes required Safari settings and app operation.
