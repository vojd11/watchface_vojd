// Host-side check of when onUpdate() refreshes data, run on the actual Monkey C
// method bodies with stubbed Toybox APIs. It covers clock jumps and the
// heart-rate cache; it is not a simulator. Run from the repository root.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync('source/Instinct2DraftView.mc', 'utf8');
String.prototype.equals = function (other) { return String(this) === String(other); };
String.prototype.toUpper = function () { return this.toUpperCase(); };
Number.prototype.format = function (f) { return f === '%02d' ? String(this).padStart(2, '0') : String(this); };
Number.prototype.toFloat = function () { return Number(this); };

// Compile one Monkey C method so that it runs against `ctx` as the view.
function method(name) {
  const m = new RegExp(`function\\s+${name}\\s*\\(([^)]*)\\)[^{]*\\{`).exec(source);
  assert.ok(m, 'missing method ' + name);
  const start = m.index + m[0].length;
  let end = start, depth = 1;
  while (depth) { if (source[end] === '{') depth++; if (source[end] === '}') depth--; end++; }
  const params = m[1].replace(/ as [\w.]+/g, '');
  const body = source.slice(start, end - 1)
    .replace(/\b\w+ has :\w+/g, 'false')                    // optional APIs are absent here
    .replace(/\b(\w+) \/ (\d+)\b/g, 'Math.trunc($1 / $2)');  // Number / Number truncates
  return Function('ctx', 'args', `with(ctx) { return (function(${params}) {${body}}).apply(ctx, args); }`);
}

// The fake clock: UTC epoch seconds plus a timezone offset in seconds.
const clock = { epoch: Date.UTC(2026, 10, 21, 10, 30, 0) / 1000, tz: 7200 };
const local = () => new Date((clock.epoch + clock.tz) * 1000);
const calls = { frame: [], dynamic: 0, battery: 0, hrReads: 0 };

const ctx = {
  System: { getClockTime: () => ({ hour: local().getUTCHours(), min: local().getUTCMinutes(),
    sec: local().getUTCSeconds(), timeZoneOffset: clock.tz }) },
  Time: { now: () => ({ value: () => clock.epoch }), FORMAT_SHORT: 0, FORMAT_MEDIUM: 1 },
  Gregorian: { info: () => ({ day: local().getUTCDate(), month: local().getUTCMonth() + 1,
    year: local().getUTCFullYear(), day_of_week: 'Sat' }) },
  Lang: { format: (f, a) => f.replace(/\$(\d)\$/g, (_, i) => a[i - 1]) },
  ActivityMonitor: { getInfo: () => ({ steps: 100, stepGoal: 5000 }) },
  updateBatteryLevel: () => { calls.battery++; },
  updateHrGraphData: () => {},
  getHeartRateString: () => String(60 + ++calls.hrReads),
  drawChangedFrame: (dc, second, heartRate, force) => { calls.frame.push(force); },
  drawDynamicRegions: () => { calls.dynamic++; },
};
// Declared members with literal initialisers, e.g. `private var _lastMinute as Number = -1;`.
for (const m of source.matchAll(/^\s*(?:private\s+)?var\s+(_\w+)[^=;\n]*(?:=\s*([^;\n]+))?;/gm)) {
  let value = null;
  try { if (m[2]) value = Function('return ' + m[2])(); } catch (e) { /* not a literal */ }
  ctx[m[1]] = value;
}
for (const name of ['onUpdate', 'getCachedHeartRateString']) {
  const run = method(name);
  ctx[name] = (...args) => run(ctx, args);
}
const update = () => ctx.onUpdate({});
const snapshot = () => ({ frames: calls.frame.length, dynamic: calls.dynamic, battery: calls.battery, hr: calls.hrReads });

// First update paints a forced full frame.
update();
assert.deepEqual(calls.frame, [true], 'first update forces a full frame');

// A plain second inside the same minute takes the cheap path.
let before = snapshot();
clock.epoch += 1; update();
assert.equal(calls.dynamic, before.dynamic + 1, 'same minute: dynamic regions only');
assert.equal(calls.battery, before.battery, 'same minute: no minutely work');

// A normal minute rollover refreshes without forcing a full frame.
before = snapshot();
clock.epoch += 59; update();
assert.equal(calls.frame.length, before.frames + 1, 'minute rollover: changed frame');
assert.equal(calls.frame.at(-1), false, 'minute rollover: not a forced frame');
assert.equal(calls.battery, before.battery + 1, 'minute rollover: minutely work');

// A whole-day jump keeps hour and minute but must refresh the date at once.
before = snapshot();
const oldDate = ctx._dateStr;
clock.epoch += 86400 + 1; update();
assert.equal(calls.frame.length, before.frames + 1, 'day jump: changed frame without waiting for the rollover');
assert.notEqual(ctx._dateStr, oldDate, 'day jump: date string refreshed');
assert.equal(ctx._dateStr, '22.11.2026');

// A whole-hour jump also reruns the minutely data refresh.
before = snapshot();
clock.epoch += 3600 + 1; update();
assert.equal(calls.frame.length, before.frames + 1, 'hour jump: changed frame');
assert.equal(calls.battery, before.battery + 1, 'hour jump: minutely work');

// A timezone change that leaves the wall clock unchanged is still noticed.
before = snapshot();
clock.tz += 3600; clock.epoch -= 3600 - 1; update();
assert.equal(calls.frame.length, before.frames + 1, 'timezone offset change: changed frame');

// Heart rate: read at the minute refresh, then again once it is 5 s old,
// whatever the second-of-minute is (a wake-up at :07 used to show a stale value).
clock.epoch += 60 - (clock.epoch + clock.tz) % 60; update();   // align to :00
before = snapshot();
for (let i = 0; i < 4; i++) { clock.epoch += 1; update(); }     // :01 to :04
assert.equal(calls.hrReads, before.hr, 'no heart-rate read within 5 s');
clock.epoch += 3; update();                                     // :07
assert.equal(calls.hrReads, before.hr + 1, 'heart rate re-read at :07, 7 s after the last read');
clock.epoch += 2; update();                                     // :09
assert.equal(calls.hrReads, before.hr + 1, 'no second read 2 s later');

// The cache function alone: empty cache and a clock that moved backwards.
ctx._cachedHeartRate = '70'; ctx._lastHrRead = 1000;
assert.equal(ctx.getCachedHeartRateString(1004), '70', 'cached value within 5 s');
assert.notEqual(ctx.getCachedHeartRateString(1005), '70', 'refreshed at 5 s');
assert.equal(ctx._lastHrRead, 1005);
before = snapshot();
ctx.getCachedHeartRateString(900);
assert.equal(calls.hrReads, before.hr + 1, 'refreshed when the clock moved backwards');
ctx._cachedHeartRate = '';
ctx.getCachedHeartRateString(901);
assert.equal(calls.hrReads, before.hr + 2, 'refreshed when the cache is empty');

console.log('PASS: minute rollover, day/hour/timezone jumps, heart-rate cache');
