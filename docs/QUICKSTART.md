# Pickup Pilot inventory quickstart

**Apple Store inventory** is the main and only app window. Saved selected items start observation automatically on every launch. There are no Start or Stop controls. Checkout remains temporarily disabled.

1. Open **Pickup Pilot** from Applications. The inventory map appears immediately.
2. Choose a country, enter a postcode or city and choose **Find stores**, or use **Use my location**.
3. Open **Configurations** and check each iPhone configuration you want. Multiple checkboxes can stay selected; use **Select all** or **Clear selection** as needed. The headphone adapter option is temporarily removed. Observation automatically follows the selected set. With no configurations selected, the app waits quietly.
4. Allow notifications when macOS prompts. The observer continues while the permission prompt is open. Refresh defaults to **1 second**, adjustable from **1–3,600 seconds**.

Selected-item edits automatically switch observation to the new set, draining the previous request before making another. Apply a new location with **Find stores**. Country changes may require finding stores again to load regional iPhone configurations, then selecting the items to observe. Up to 20 selected configurations share one stock check. There is no separate activation step.

All stores returned by Apple's nearby-store feed are observed. Badges show pickup-eligible configurations, not physical quantities. Stores without map coordinates remain listed. Distances and approximate driving times are calculated during discovery, not on each stock poll.

Initially available stock and later availability or pickup-message changes update the Dock badge, request Dock attention, and post a local notification with sound. Clicking a notification opens the same inventory window. **Acknowledge** clears unread alerts. Check **System Settings → Notifications → Pickup Pilot** if alerts, sounds or badges are disabled; Focus can also limit delivery.

Checks never overlap. One second is the healthy requested cadence; slow responses and server backoff can make checks slower. Errors retain previous results with a warning, and missing or ambiguous rows remain unverified. **Refresh now** respects server backoff. Launch reuses the discovery response before scheduling the next check, including the appropriate backoff if that response failed.

Closing the window leaves observation running in the menu bar. Reopening the app or clicking a notification brings back the same window. Quit Pickup Pilot to end observation. Every launch automatically resumes the saved selection after loading its regional catalog.

Inventory mode does not require Safari permissions or saved payment data. Existing checkout data is preserved in Keychain and is not read by observation.
