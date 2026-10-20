# Pickup Pilot quickstart

## Safari setup

Pickup Pilot controls a dedicated normal Safari window. It never reuses an existing user tab. Allow **Pickup Pilot → Safari** in **System Settings → Privacy & Security → Automation** when macOS prompts. In **Safari Settings → Developer → Automation**, enable **Allow JavaScript from Apple Events**. If the Developer pane is hidden, enable web developer features in **Safari Settings → Advanced** first. Pickup Pilot does not change these settings. Keep exactly one tab in its dedicated window; **Show Safari checkout** brings that window forward.

Safari manages its normal website session, which may include existing Apple cookies. This is not a private or isolated-cookie browser. Pickup Pilot never imports, exports, restores or clears Safari cookies. Saved contact/payment profiles and the durable purchase lock remain in the app’s Keychain.

## Guest-only checkout

Pickup Pilot automatically selects one eligible Continue as Guest control on the selected country's healthy Apple checkout page. Page readiness is bounded: an explicit not-ready result does not consume the single guest dispatch; a confirmed dispatch is never repeated during the same attempt. A lost or malformed bridge result stops instead of risking a second dispatch. If guest checkout cannot continue or a security/bank challenge is required, preparation stops and disarms without requesting account sign-in. A post-submission challenge or uncertain result preserves the durable purchase lock. The app still requires ordinary contact/payment fields and explicit final payment confirmation.

## Missing checkout pages and response diagnostics

The checkout window distinguishes a Page Not Found result from an observed HTTP 403, 429 or 541. The visible missing page alone does not establish a session block. Diagnostics show the last attempted step, current page category and any actually observed access/rate-limit status/source. An earlier response can remain visible alongside a later missing-page result. Safari’s Apple Events interface does not expose main-document HTTP status; the app shows no inferred status when that evidence is unavailable. Page observers install after load and can miss a response that precedes injection. Only fixed classifications and numeric codes enter the bounded in-memory history; no URLs, query tokens, headers, cookies, page contents or profile data are retained there.

A known missing-page route or specific visible Apple missing-page heading stops preparation without auto-retry or authentication guidance. An incidental 404 response from a background request does not itself prove blocking or that the current document is missing. Guest transitions can settle briefly while scripts initialize; persistent unknown pages stop as unsupported rather than inventing a sign-in challenge. **Verify Safari session** requires a stable verified working page; rejecting an unready page does not invent an HTTP block or export cookies. Local fixtures verify that observed access/rate-limit response evidence is retained across an error redirect without changing Apple's response or bypassing its controls. This does not establish the server-side cause of an earlier error page.

While disarmed and without a pending/uncertain order, **Return to bag** opens the ordinary Apple bag in the same owned Safari window. This does not load profile/session data from Keychain, add an item, arm monitoring or submit an order. A post-submission error remains uncertain and preserves the purchase lock. The earlier HTTP 541 and missing-page redirect do not establish Apple’s server-side reason. Switching to Safari is not proof of acceptance. No real checkout or purchase was verified for the retained Safari revision.

The retained October 17, 2026 release has separate [test results](TEST-RESULTS.md) and [validation notes](VALIDATION.md). Passing synthetic tests does not prove live Apple checkout acceptance.

Production checkout now uses a dedicated normal Safari window. The default tests use mocked Safari transport, isolated WebKit fixtures, synthetic profiles and native rendering; they do not drive Apple. The opt-in about:blank probe is reported separately. No current live Apple final review or paid order is verified, and the reason for the earlier HTTP 541 remains unproven.

The opt-in actual Safari check is not verified. Recorded result: javascriptDisabled. Default mocks do not prove Automation permission or Safari JavaScript execution.

## Open the installed app

Download [Pickup-Pilot-macOS-arm64.zip](https://github.com/rehatkathuria/pickup-pilot/releases/latest/download/Pickup-Pilot-macOS-arm64.zip), extract it, and move **Pickup Pilot.app** to **Applications**. Quit any running instance before opening an updated copy. Every launch starts disarmed. The menu bar icon reopens setup after the window is closed. Keep the app open and the Mac awake while monitoring.

The downloadable app is ad hoc signed and requires Apple Silicon and macOS 15 or later. Extract it outside synced Documents. To build from source, run `./scripts/build-app.sh` from the repository root. It generates app bundles and an archive under the local, Git-ignored `outputs/` directory. See [development instructions](../DEVELOPMENT.md) to run the synthetic suite.

## Configure and arm

1. **Stores & products:** choose a shopping country, enter a postcode/city or detect your physical location, and choose **Find stores**. Select exact product configurations and pickup stores; selection order sets priority. Store distances are straight-line kilometres from the postcode/city centre. Driving times use Apple Maps, rounded up in five-minute steps; failed routes say unavailable.
2. For the inexpensive Canadian test product, choose **USB-C to 3.5 mm Headphone Jack Adapter**, exact SKU `MW2Q3AM/A`. The native catalog verifies its official product identity, currency and current price. It uses pickup when ready, without an invented reserved date/time. Changing product or country clears previous selections and budget authorization.
3. **Schedule & limits:** set attempt dates/hours, time zone, a final tax-inclusive maximum and check interval. iPhone pickup also requires reserved pickup dates/hours. The healthy interval supports 1–3,600 seconds, default 5. Checks do not overlap; errors retain backoff and Retry-After delays.
4. **Secure checkout:** enter contact, billing and card details locally in the app and save to Keychain. Editable fields are visible. Drafts can be saved, but arming requires a complete valid profile. Never send real details in chat.
5. **Overview:** authorize one order, choose **Review and arm…**, inspect the frozen products/SKUs, stores/priorities, location, one-item limit, budget, schedules and check interval, then choose **Confirm and arm**. Canceling, changing the plan or withdrawing consent revokes confirmation, including during storage validation.
6. Pickup Pilot’s dedicated Safari window automatically uses **Continue as Guest**. It never asks you to sign in. If guest checkout remains unavailable or a challenge is required, the attempt stops. Ordinary missing contact/payment fields can still require correction. At final review, inspect the payment method locally and choose **Confirm payment and allow order** only for your intended purchase. Review changes invalidate that confirmation.
7. Live observation shows confirmed product/store pairs, check counts/timestamps, next check, eligibility quotes and stale results. It adds no inventory requests. Diagnostics show fixed checkout steps, page categories and any actually recorded HTTP codes; Safari main-document status is unavailable through Apple Events. A missing-page screen does not prove an access response. While disarmed without a pending order, **Return to bag** navigates in the same browser without adding an item or arming.
8. **Activity & order:** verify the receipt and Apple's pickup instructions. Confirmed or uncertain submission retains the one-purchase lock across restarts. Inspect Apple order history before explicitly resetting it. **Check visible confirmation** can reconcile a visible order without submitting again.

## Test without ordering

Choose **Test to final review** after selecting the product, store, location and budget. Pickup Pilot prepares guest checkout in a separate owned Safari window using the saved profile and stops at a verified final review. Native test code cannot send the final-order command. Safari’s own manual order control may still be available: **do not place an order in Safari during the test**. Correct ordinary required fields in Safari if needed, then choose **Continue to review** in Pickup Pilot. Guest/authentication requirements end the test instead of requesting sign-in. **End test** clears retained app inputs and closes only the test’s tracked Safari window; it does not erase Safari website data.

## Session controls

Safari keeps its own website session. **Verify Safari session** checks that the current owned window is a stable working Apple page while disarmed; it does not copy cookies, arm checkout or place an order. **Reset Safari checkout window** closes only the tracked normal-checkout window, without clearing Safari website data or signing out of Apple. It is unavailable during an armed attempt or while a purchase is pending/uncertain. Start a fresh authorized attempt after inspecting the previous checkout. Legacy app-saved WebKit sessions are ignored by Safari and can be deleted separately from the contact/payment profile. Returning to the bag, verifying a page or resetting a window does not establish that Apple will accept a new request.
