# Pickup Pilot performance

Healthy monitoring retains a selectable 1-second minimum and 5-second default, one batched request for selected configurations, no overlap/catch-up bursts, monotonic start-to-start cadence and full error/Retry-After backoff. Arming review and live observation add no inventory requests. Scheduling regression results are included in the final suites.

Production Safari uses bounded Apple Events snapshots and verifies the current owned document before action. Its end-to-end checkout speed and competitive ordering success have not been measured. No artificial human timing, identity spoofing or security-response bypass is implemented.

## Historical measurements

Earlier local benchmark records and an Instruments trace described an older synthetic embedded WebKit build. They are not published with this repository. Those measurements excluded real Apple latency, network contention and user payment review and must not be presented as Safari speed measurements.

## Recorded regression and launch evidence

Recorded on **October 17, 2026** for the retained Safari release archive: **476 tests in 37 suites passed in Debug (49.248 seconds) and Release (44.424 seconds)**. Whole-production Swift coverage was **6468/6859 (94.30%)** for the suite and **6541/6859 (95.36%)** including the asserted disarmed app launch. Coverage remained below 100%; embedded JavaScript coverage was unmeasured. These are historical results, not a new test or GitHub CI run.

The opt-in actual Safari check is not verified. Recorded result: javascriptDisabled. Default mocks do not prove Automation permission or Safari JavaScript execution.
