# Pickup Pilot development

The application is a Swift 6.2 package targeting macOS 15 or later, with no third-party dependencies. Build the app with `./scripts/build-app.sh`. Native UI, Vision, WebKit and Keychain tests require normal macOS service access. Documents/FileProvider can alter metadata after signing, so final packaging and validation use a local temporary build snapshot and the exact extracted app ZIP.

Production normal checkout and review-only checkout use `SafariAppleCheckoutPage` through `SafariAutomation`. The transport controls only a window it created, keeps one tab, passes scripts through private pipes, and rejects stale generation results. `AppleCheckoutDriver` retains the same guest, exact-review, payment-confirmation and durable purchase-lock policy. The embedded `WKAppleCheckoutPage` remains an injected fixture adapter, not the production browser.

## Permissions and session policy

Allow Pickup Pilot to control Safari under **System Settings → Privacy & Security → Automation**. Enable **Safari Settings → Developer → Automation → Allow JavaScript from Apple Events**; enable web developer features under **Safari Settings → Advanced** if Developer is hidden. The app reports fixed setup errors and does not enable those settings itself. Apple documents the Safari setting in [Developer settings](https://developer.apple.com/documentation/safari-developer-tools/developer-settings).

Production windows are normal Safari windows and use Safari-managed website data. They are not private-cookie sessions. The app never exports or restores Safari cookies to Keychain. Resetting a tracked window does not erase Safari data. Profiles and the one-order journal remain app-scoped Keychain records; see [SECURITY.md](SECURITY.md).

## Default tests

Run on macOS with Swift/Xcode command-line tools, Python 3. The retained release and current coverage script use Apple Silicon build paths.

```sh
PICKUP_PILOT_KEYCHAIN_INTEGRATION=1 \
PICKUP_PILOT_LIVE_TRAVEL=0 \
PICKUP_PILOT_CHECKOUT_BENCHMARK=0 \
./scripts/test.sh
```

Safari transport tests inject an executor and synthetic script results; Safari page tests inject a controller. They do not start Safari, inspect existing tabs, load Apple, read a real profile or place an order. Controller and rendered-screen tests inject Safari fixtures or retain explicit isolated WebKit documents. The synthetic Keychain suite uses its own records and verifies cleanup. A default test must not silently become a real browser or checkout test when the production default changes.

A constructor-only production assertion may verify Safari selection and absence of an embedded browser, but it must not call load or Show Safari. Review-only fixtures must prove final submission is rejected before URL reads, JavaScript evaluation or other transport operations. Cancellation tests must cover late results and old-window cleanup without closing a new or foreign window.

## Actual Safari fixture checks

Actual Safari automation is opt-in and separate from the default suite. The app provides an explicit disarmed probe:

```sh
open -n "/Applications/Pickup Pilot.app" --args --ui-preview --validate-safari
```

Launch the installed app through Launch Services so the Automation prompt belongs to Pickup Pilot. This creates only its own `about:blank` window, validates native and JavaScript URL identity, evaluates a synthetic DOM marker and closes the captured window. It does not load Apple, read a real profile or export cookies. Existing tabs and production checkout stay outside that check. A permission prompt or disabled JavaScript setting is a setup result, not a passing integration result. Record the probe’s completion and cleanup separately from unit-test results. A mock transport run does not establish that macOS permission or Safari scripting works.

Any extended local-fixture verification must remain anonymous with synthetic values and no links or requests to a merchant. Test creation, navigation, evaluation, activation and teardown only in the tracked window and record cleanup.

Safari’s Apple Events interface lacks main-document HTTP response metadata and document-start script injection. Page observers can miss an early request or redirect. Report only observed status evidence; missing evidence is not success. Native review-only submission stays disabled, but Safari’s own manually accessible order control cannot be guaranteed disabled at all times.

## Evidence and release

Keep source, build, synthetic tests, rendered UI, exact ZIP launch, installed bytes and live merchant acceptance as separate evidence tiers. Recheck canonical/build/source-archive hashes before publication. Preserve an existing user process while replacing the authorized on-disk app; a running old process remains old until reopened. The repository preserves historical release test counts, coverage and validation scope in [test results](docs/TEST-RESULTS.md), [coverage](docs/COVERAGE.md) and [validation](docs/VALIDATION.md). Build scripts generate new local artifacts under `work/` and `outputs/`; these directories are excluded from Git. Re-run validation after source changes instead of treating the retained release results as a fresh test run.

HTTP 541 and a later Page Not Found screen do not prove why Apple refused a guest request. Historical clean-browser and Safari probes are historical only. Neither switching browser nor passing all synthetic tests proves current Apple final review or purchase acceptance. Whole-production Swift coverage must retain all production files; embedded JavaScript coverage needs its own denominator or must remain explicitly unmeasured.
