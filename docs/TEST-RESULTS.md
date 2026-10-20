# Pickup Pilot test results

Recorded on **October 17, 2026** for the retained Safari release archive: **476 tests in 37 suites passed in Debug (49.248 seconds) and Release (44.424 seconds)**. Whole-production Swift coverage was **6468/6859 (94.30%)** for the suite and **6541/6859 (95.36%)** including the asserted disarmed app launch. Coverage remained below 100%; embedded JavaScript coverage was unmeasured. These are historical results, not a new test or GitHub CI run.

## Passed scope

Both completed summaries covered the original frozen release source manifest. The suite combines mocked Safari commands/pages, actual isolated WebKit execution, synthetic coordinator/rehearsal flows, native SwiftUI rendering and isolated synthetic Keychain integration. No default test drives Apple, opens a user Safari tab or submits a real order. Review-only submission is rejected before transport; setup failures stop without account authentication or retries; post-submission Safari failures lock uncertainty across restart.

The retained Release ZIP has separate strict-signature and visible disarmed-launch evidence. The [coverage report](COVERAGE.md) lists every production Swift file and an explicitly unmeasured JavaScript asset. Local raw logs and generated coverage JSON are excluded from Git.

## Actual Safari probe

The opt-in actual Safari check is not verified. Recorded result: javascriptDisabled. Default mocks do not prove Automation permission or Safari JavaScript execution.

## Skipped tests

- `publicTorontoLandmarksResolveAndReturnLiveDrivingETA()` (live Apple Maps).
- `productionCheckoutTimingBenchmark()` (optional local benchmark).

## Unverified

Current Apple guest acceptance, live final review, paid purchase, bank verification, competitive success and production Safari checkout latency remain unverified. Historical browser and timing reports are not current-revision results. Whole-app coverage remains below 100%; JavaScript coverage is unmeasured.
