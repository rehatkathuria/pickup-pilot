# Pickup Pilot

Pickup Pilot is a native macOS app for nearby Apple Store inventory monitoring. The current app temporarily disables automatic checkout and its checkout test pathway. It does not open Safari or read a saved checkout profile.

[Download the Apple Silicon macOS app](https://github.com/rehatkathuria/pickup-pilot/releases/latest/download/Pickup-Pilot-macOS-arm64.zip) · [Releases](https://github.com/rehatkathuria/pickup-pilot/releases) · [Quickstart](docs/QUICKSTART.md)

The downloadable app requires **Apple Silicon and macOS 15 or later**. Extract the ZIP outside a synced Documents folder, move **Pickup Pilot.app** into **Applications**, and open it. It is ad hoc signed. Inventory monitoring does not need Safari Automation permissions. Allow notifications when prompted to receive stock alerts. The GitHub release link above is the previous published version; these inventory-mode changes are local until a new release is published.

The source is a **Swift 6.2 package with no third-party dependencies**. Open `Package.swift` in Xcode, or build from the repository root:

```sh
./scripts/build-app.sh
```

The build generates `outputs/Pickup Pilot.app` and `outputs/Pickup Pilot.app.zip` locally. Generated outputs, build caches and private diagnostic files are excluded from Git. Development scripts use Swift/Xcode command-line tools, and Python 3 on macOS. The retained release was built with Xcode 27.1 / Swift 6.4 on Apple Silicon.

## Inventory map and immediate alerts

The **Apple Store inventory** map is the main and only app window. Saved selected configurations begin observation automatically on launch. Choose your country, enter a postcode or city (or use your location), choose **Find stores**, and check any combination of iPhone configurations in **Configurations**. Observation starts as soon as the search and selection are valid; no Start or Stop action is required. Every nearby store returned by Apple is monitored; old preferred-store selections do not restrict the map. Stores without coordinates remain visible in the list. Distances and rough driving times are calculated during discovery, not on each stock poll.

Refresh defaults to **1 second** and can be changed in whole seconds from **1 to 3,600**, including while watching. All selected configurations share one request. Requests never overlap, and the healthy cadence measures request start to request start; slow responses and Apple's error/rate-limit backoff can make actual checks slower. The persistent configuration popover supports multiple independent checkboxes, Select all and Clear selection, with up to 20 configurations in one check. The headphone adapter option is temporarily removed. Selected-item changes automatically replace the observed set. Apply a new location with **Find stores**; country changes load their regional catalog before observation resumes. An empty selection waits quietly for items to be selected.

Map badges show the number of selected configurations eligible for pickup, **not a count of physical units**. Per-product details include Apple's pickup message. Missing or duplicate rows remain unverified. Failed requests keep the last successful results with a visible warning. Available inventory in the initial discovery response triggers an alert without an immediate duplicate stock request; later changes to pickup availability or the pickup message also trigger alerts. Unchanged stock stays quiet. The recent-changes list retains up to 200 changes for the session.

Automatic observation requests macOS notification permission for alerts, sounds and badges without waiting for the prompt to finish before observing. Changes immediately update the Dock badge and request Dock attention, then post a local notification with default sound; simultaneous changes are grouped into one notification per response. Notifications also appear while the app is in the foreground. Clicking a notification brings the single inventory window forward and acknowledges unread changes. **Acknowledge** clears the badge and attention request. Alerts observed during the initial permission prompt are queued until permission is granted. macOS notification settings and Focus determine whether banners, sound and Time Sensitive delivery are permitted; the map displays the actual settings. No remote push service is required. Closing the inventory window keeps observation running in the menu bar. Quit the app to end observation.

Inventory refresh and search location are saved as ordinary preferences. Existing checkout profiles and order records are preserved in Keychain but are not read in inventory mode. Monitoring never arms or places an order. Source-level checkout regression coverage is retained for a later re-enable.

Read the [quickstart](docs/QUICKSTART.md) and [inventory-mode validation](docs/INVENTORY-MODE-VALIDATION.md) for the current app. Other validation documents and checkout notes below describe earlier builds unless explicitly updated. Synthetic tests do not establish live Apple availability, real notification delivery or merchant acceptance.

<details>
<summary>Retained checkout documentation (disabled in the current app)</summary>

## Low-cost purchase test in the app

In **Stores & products**, choose **Canada** and **USB-C to 3.5 mm Headphone Jack Adapter**, then find stores and select the adapter and a pickup store. The app verifies the Canadian product page, SKU `MW2Q3AM/A`, currency and current price before listing it. Apple listed it at C$10 before tax on October 16, 2026. Changing products clears the old configuration selection, budget and one-order authorization.

Set a new maximum final total including tax, save your contact/payment profile in the app, authorize one order and choose **Review and arm…**. Review the exact plan, then choose **Confirm and arm**. This uses the same native inventory coordinator, dedicated Safari checkout window, profile filling and durable purchase lock as phone checkout. The adapter uses pickup when Apple confirms it is ready, without a reserved pickup time; the Schedule page explains that its pickup date/hour limits do not apply. Phone orders retain their reserved-slot requirements. Checkout uses Apple's guest option automatically and still pauses for final payment confirmation. **Test to final review** remains a separate non-purchasing mode.

## Guest-only checkout

Pickup Pilot automatically chooses the single eligible **Continue as Guest** control on the selected country's healthy Apple checkout page. A temporarily loading page or unready control does not consume the guest attempt. Waiting is bounded, and a confirmed dispatch is never retried on an unchanged sign-in page. The app does not ask for Apple Account authentication. If guest checkout remains unavailable or a security/bank challenge is required, preparation stops and disarms without a purchase. A challenge or unknown result after final submission preserves the uncertain-order lock instead of retrying. Payment review confirmation and ordinary required contact/payment fields remain separate from account sign-in.

If Apple returns a verified empty bag before order submission, Pickup Pilot reopens the selected product, adds one item, verifies its SKU and quantity, then continues checkout. This also recovers a bag that empties later in the flow. Refills are limited to three per attempt within the existing preparation deadline, including after a manual-input pause. Repeated observations of the same empty page during navigation cannot trigger another refill. A verified replenished bag permits a fresh guest checkout; unexpected items, quantities, errors and access responses stop the flow.

## Checkout in Safari

Production checkout uses a dedicated normal Safari window controlled by Pickup Pilot through Safari’s public Apple Events interface. It uses ordinary Apple page controls and guest checkout. The window is separate from the status panel in Pickup Pilot; **Show Safari checkout** brings that owned tab forward. An opaque marker follows the checkout tab if it moves between windows or shares a window with other tabs. Unrelated tabs are never adopted or closed.

Safari navigation temporarily making a document unavailable no longer ends checkout. Pickup Pilot waits for verified page evidence before continuing. If tracking is lost before order submission, or a checkout handoff leaves the bag behind, it opens a fresh owned bag window, validates or refills the selected item, then resumes guest checkout. Reconnection is bounded within the existing preparation deadline, and never retries an uncertain order submission.

On first use, allow Pickup Pilot to control Safari in **System Settings → Privacy & Security → Automation**. In Safari, enable **Safari Settings → Developer → Automation → Allow JavaScript from Apple Events**; if Developer is hidden, enable web developer features in **Safari Settings → Advanced** first. The app does not change these settings. Missing permission, disabled JavaScript automation, a closed or changed owned window, and timed-out commands produce fixed actionable errors and stop the attempt. Keep exactly one tab in the dedicated window.

Safari manages its normal website session, including any existing Apple cookies. The app does not export, import, restore or clear Safari cookies, and it does not put them in its Keychain. Contact/payment profiles and the durable one-order journal remain app-scoped Keychain data. **Reset Safari checkout window** closes only the app’s proven checkout tab and starts a later attempt with a new window; it does not sign out of Apple or clear Safari website data.

This is a browser integration change. It does not establish why Apple returned HTTP 541 or guarantee that Safari will be accepted. The app does not disguise automation, fabricate a human identity, suppress merchant errors or bypass security challenges. Live Apple final-review and paid-order acceptance remain separate verification.

## Confirm selections and see monitoring results

Overview lists selected product names/SKUs and pickup store names/IDs in priority order, the search location, storefront, one-item limit, tax-inclusive maximum, attempt and pickup schedules, time zone, check interval and preparation failure limit. The arming sheet freezes that plan for confirmation. Canceling, changing the reviewed setup or revoking authorization prevents arming, including while Keychain validation is pending. No profile values are included in the review.

After arming, **Live observation** shows the exact confirmed product/store pairs, checks started, request start/finish times, last successful response, next check and Apple's pickup quote for each pair. Waiting for the attempt schedule or checkout input does not count as a stock check. Missing/ambiguous response rows stay unverified. Failed checks retain older successful results with an explicit warning and timestamp; a new arm clears the previous run's results. Discovery results never stand in for a successful armed check. All displayed schedule/check times use the confirmed time zone. This display uses the existing batched checks and adds no polling requests.

## Checkout error pages

**Page Not Found** is a distinct checkout failure. A verified Apple error route or the specific visible Apple missing-page heading stops preparation without claiming the session was blocked or requesting sign-in. The embedded fixture adapter also recognizes an observed main-page HTTP 404. An observed HTTP 403, 429 or 541 remains separate evidence; it can precede Apple's redirect to a missing page. Rejecting an unready session-verification page does not invent that evidence.

The checkout window shows the last attempted step, current page category and any observed access/rate-limit response. Safari’s Apple Events interface does not expose the main-document HTTP response status, so the app does not infer one from a rendered page. HTTP status evidence is shown only if the installed page observer actually records it; navigation can replace a document before that observer exists. Missing evidence is not proof of success. The bounded eight-entry in-memory history uses only fixed step/page/source classifications and numeric status codes, without URLs, query parameters, headers, cookies, page content or profile values.

While disarmed and without a pending/uncertain order, **Return to bag** opens Apple’s ordinary bag in the owned Safari window. It never loads the profile, adds an item, arms checkout or submits an order. **Verify Safari session** verifies the current working page without exporting a session or authorizing a purchase. A failed/uncertain submission keeps the one-purchase lock; a post-submit error page never permits another submission.

## Architecture

- `PilotCore`: regional catalog and inventory clients, physical/manual location resolution, proximity ranking, timing/budget policy, secure profile/Keychain vault, persistent order journal and main-actor coordinator.
- `PickupPilot`: native menu, setup/settings, dedicated Safari checkout transport/page adapter, Core Location and Apple Maps travel adapters, app lifecycle. The embedded WebKit adapter remains available for isolated fixtures and legacy regression tests.
- `Tests`: deterministic network/state-machine/security tests, mocked Safari transport/page tests, synthetic native WebKit form/slot/order-policy tests, actual offscreen screen/sheet rendering tests. An actual Safari `about:blank` fixture probe is opt-in through `--ui-preview --validate-safari` and separate from live merchant acceptance.
- `scripts`: reproducible build and coverage report. `work/` holds local build caches and diagnostics; `outputs/` holds generated app bundles and reports. Both directories are excluded from Git. Published usage and validation notes are in `docs/`.

The app starts disarmed and never restores arming. Only ordinary preferences are JSON. Contact, billing, card/CVV, location query and the order journal use separate app-scoped Keychain records. Legacy embedded-browser cookie records can be deleted separately; production Safari checkout never reads or restores those records. Safari website data remains under Safari’s control. The local ad hoc app explicitly uses nonsynchronizing login-Keychain access; Data Protection mode is available to a properly provisioned signed host. No silent storage fallback. The Secure checkout sheet shows profile values in visible editable fields.

Store searches geocode the entered postcode or city within the selected country and rank stores by straight-line distance from that approximate centre. Rows include rough Apple Maps driving times rounded up in steps of five minutes. A route failure keeps the distance and explicitly marks the drive time unavailable; it never invents a time from a speed assumption. Successful routes are cached in memory for ten minutes, and location edits immediately clear stale travel results. Geocoding and routing share the search location/coordinates with Apple and do not request location permission for manual searches.

At the first final review, the app pauses for you to confirm the payment method locally. This build cannot authoritatively identify the selected payment card from the review, so it does not perform unattended final ordering. Before final submission, a verified review must match the regional SKU, selected store, quantity one, currency and final tax-inclusive budget. Reserved phone pickups also require a continuous acceptable pickup slot; the exact Canadian adapter supports verified pickup when ready without a reserved time. The coordinator durably writes a submitting record before invoking the driver. Any uncertain post-submit state locks retries across restarts; only a user reconciliation/reset can allow another purchase. The app’s final submission uses a single-use capability bound to the current review. Safari page guards can be installed only after the document loads; the app cannot guarantee that Safari’s own manual order control is disabled at every moment.

Default development tests use mocked Safari transport or isolated WebKit documents and synthetic profiles. They do not access a real saved checkout profile, an existing Safari tab or a live order. An opt-in actual Safari fixture check necessarily uses a normal Safari window and its normal website-data policy, so it must stay on the anonymous local fixture and close only its own window. Nothing in a synthetic result proves merchant acceptance.


The review-only checkout test in Overview uses a separate owned Safari window and exposes preparation, explicit recovery and cancellation only. Native code prohibits test submission before any final-order transport command. Safari’s own manual order button may remain available: do not place an order in Safari during the test. A blocking response pauses the test with its current window and inputs retained. A verified healthy Apple page can resume only after an explicit Continue action; there is no automatic retry or sign-in fallback. **End test** clears retained app inputs and closes only the tracked test window. It does not erase Safari website data. Injected WebKit fixtures retain their document-start guard for regression coverage; that guard is not claimed for Safari.

For an access/rate-limit response or missing-page failure in normal checkout, the app disarms. Inspect **Checkout response details** first. Use **Return to bag** to navigate to a working page, then **Verify Safari session** to verify it while disarmed. This does not arm checkout, prepare an order, export cookies or submit it; review the limits and explicitly confirm a new attempt. Session recovery fixtures do not prove that Apple will accept another request.

An earlier native Safari private-window test with the **C$10 USB-C headphone adapter** passed guest checkout, selected Eaton Centre and reached required pickup contact details only. No contact/payment details were entered, and live final review was not reached. Earlier native WebKit and clean Chrome probes recorded HTTP 541 responses. These historical probes do not establish live acceptance for the current build.

## Checkout speed

New settings default to a 5-second healthy availability cadence. All selected variants share one request, requests never overlap, and the interval measures request start to request start. Saved custom intervals are preserved; choose 1 second under Schedule & limits for the fastest supported setting. Failed requests retain conservative backoff and Apple’s full Retry-After delay.

Safari checkout performs bounded snapshots of its owned window through Apple Events and validates the current document before each action. The embedded fixture adapter still wakes on native navigation and coalesced page/model changes; those hints only request a fresh validated snapshot. Historical embedded-browser timing measurements do not measure Safari performance. Pending forward controls cannot be clicked repeatedly; a validation-error retry requires an explicit local Continue action. Ordinary field handoffs resume the original request and browser without another inventory or profile fetch, while rechecking the durable order lock and attempt schedule. Account authentication never becomes a resumable handoff. Final-review payment confirmation and all final-order guards remain required.

See [performance notes](docs/PERFORMANCE.md) for the historical local benchmark and its live-checkout limits.

</details>
