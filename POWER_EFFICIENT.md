# Power-efficient watchface

Branch: `feature/power-efficient-digits`

This variant is always enabled on this branch. The original fixed version is
preserved on `main` at `94711b8`.

- Hours, minutes and seconds use fixed-width digit cells. Only changed cells
  are cleared and repainted, including minute/hour carries and midnight.
- Weather, date, weekday, steps/drain, battery and the heart-rate eye repaint
  when their displayed values change. The graph refreshes every five minutes.
- A full frame is restored after `onShow()` or `onLayout()`. Overlapping date
  and eye regions restore their intersecting pixels when needed.
- Sleeping partial updates draw seconds only. Heart rate refreshes once per
  minute while sleeping and every five seconds while awake.
- A power-budget rejection invalidates the seconds cache so the next update
  repairs any rejected digit changes.
- Unchanged battery readings no longer write `prevBattery` to storage.

Garmin calls sleeping partial updates every second subject to its power budget:
https://developer.garmin.com/connect-iq/api-docs/Toybox/WatchUi/WatchFace.html

## Validation

Run `node tests/render-regression.cjs` from the project root. The host harness
executes the rendering methods extracted from the Monkey C source against a
deterministic clipped raster, covering a day's second transitions, minute/hour
carries, unchanged callbacks, cache invalidation, and changing data regions.
It approximates font rasterization and does not replace the Garmin simulator.

Compile `monkey.jungle` with `monkeyc -d instinct2 -y developer_key` and output
to `bin/Instinct2Draft-power-efficient.prg`. On a headless Linux machine set
`JAVA_TOOL_OPTIONS=-Djava.awt.headless=true`.

On-device checks still needed: inspect glyph edges and overlapping date/eye
regions, open/close widgets, observe 09→10 and 59→00 seconds, and profile
sleeping partial updates. Reduced drawing is verified; battery-life gains
have not been measured.
