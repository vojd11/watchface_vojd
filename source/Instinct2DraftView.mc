import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;
import Toybox.Activity;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.ActivityMonitor;
import Toybox.Weather;
import Toybox.Application.Storage;

class Instinct2DraftView extends WatchUi.WatchFace {

    var timeFontResource;
    private var _drawnTime as String = "";
    private var _drawnSeconds as String = "";
    private var _drawnWeather as String = "";
    private var _drawnStats as String = "";
    private var _drawnDate as String = "";
    private var _drawnDay as String = "";
    private var _drawnBattery as String = "";
    private var _drawnProgress as Number = -1;
    private var _timeDigitWidth as Number = 0;
    private var _secondDigitWidth as Number = 0;
    private var _graphDirty as Boolean = true;

    // Cached data members
    private var _lastMinute as Number = -1;
    private var _lastHour as Number = -1;

    // Cheap discontinuity detection for the date line: a manual clock
    // change, travel or DST can move the calendar date or the timezone
    // without moving the hour. Tracking these two lets us catch that
    // without paying for a Gregorian.info() call on every update.
    private var _lastUtcDay as Number = -1;
    private var _lastTzOffset as Number = -1;

    // Per-minute cached data
    private var _minutesStr as String = "";
    private var _stepsStr as String = "0";
    private var _stepsProgress as Float = 0.0;
    private var _hrSamples as Array<Number or Null>;
    private var _hrSampleCount as Number = 0;
    private var _hrMin as Number = 0;
    private var _hrMax as Number = 0;
    private var _minutesSinceGraphUpdate as Number = 0;

    // Per-hour/change cached data
    private var _hoursStr as String = "";
    private var _dateStr as String = "";
    private var _dayOfWeekStr as String = "";
    private var _tempStr as String = "--";
    private var _hiLowStr as String = "--/--";
    private var _batteryStr as String = "0%";
    private var _batteryLevel as Float = 0.0;
    private var _wasCharging as Boolean = false;
    private var _drainStr as String = "--%/d";

    // Static layout, computed once
    private var _subWindowX as Number = 144;
    private var _subWindowY as Number = 31;
    private var _subWindowR as Number = 28;

    // Partial/dynamic update state
    private var _isSleep as Boolean = false;
    // Defaults to true deliberately: onShow() always runs before the first
    // onUpdate(), but if that ever failed to hold, defaulting to false
    // would leave a permanently blank watch face - far worse than one
    // stray draw.
    private var _isVisible as Boolean = true;
    private var _secClipX as Number = 0;
    private var _secClipY as Number = 0;
    private var _secClipH as Number = 0;
    private var _hrClipX as Number = 0;
    private var _hrClipY as Number = 0;
    private var _hrClipW as Number = 0;
    private var _hrClipH as Number = 0;
    private var _lastDrawnHeartRate as String = "";
    private var _cachedHeartRate as String = "";

    function initialize() {
        WatchFace.initialize();

        // Load custom font resource once
        try {
            timeFontResource = WatchUi.loadResource(Rez.Fonts.LargeTimeFont);
        } catch (e) {
            timeFontResource = Graphics.FONT_SYSTEM_NUMBER_THAI_HOT;
        }

        // Pre-allocate HR samples array (90 minutes)
        _hrSamples = new [90];
    }

    // Load your resources here
    function onLayout(dc as Dc) as Void {
        setLayout(null);
        _lastMinute = -1;

        // Sub-window ("Eye") geometry is fixed per device; compute once
        if (WatchUi has :getSubscreen) {
            var subscreen = WatchUi.getSubscreen();
            if (subscreen != null) {
                _subWindowX = subscreen.x + (subscreen.width / 2);
                _subWindowY = subscreen.y + (subscreen.height / 2);
                _subWindowR = subscreen.width / 2 - 5;
            }
        }
    }

    // Called when this View is brought to the foreground. Restore
    // the state of this View and prepare it to be shown. This includes
    // loading resources into memory.
    function onShow() as Void {
        _isVisible = true;

        // The screen may have been overwritten by another app, widget or a
        // system alert while we were hidden, so force a full redraw on the
        // next onUpdate() instead of taking the cheap seconds/HR-only patch
        // path, which would leave whatever covered us still on screen.
        _lastMinute = -1;
    }

    // Update the view
    function onUpdate(dc as Graphics.Dc) as Void {
        // Never paint while something else owns the display. The cheap path
        // below only patches small rectangles, so drawing here would leave
        // boxes of our content sitting on top of a system screen.
        if (!_isVisible) { return; }

        var clockTime = System.getClockTime();
        var currentSecond = clockTime.sec;
        var currentMinute = clockTime.min;
        var currentHour = clockTime.hour;

        var forceUpdate = (_lastMinute == -1);
        var minuteChanged = forceUpdate || currentMinute != _lastMinute;

        // Catch date/timezone discontinuities that don't move the hour
        // (manual clock change, travel, DST). Only worth checking when the
        // minute rolls over - these never need sub-minute detection - and
        // both reads are cheap compared to Gregorian.info().
        var calendarChanged = false;
        if (minuteChanged) {
            var utcDay = Time.now().value() / 86400;
            var tzOffset = clockTime.timeZoneOffset;
            if (utcDay != _lastUtcDay || tzOffset != _lastTzOffset) {
                _lastUtcDay = utcDay;
                _lastTzOffset = tzOffset;
                calendarChanged = true;
            }
        }

        var hourChanged = forceUpdate || currentHour != _lastHour || calendarChanged;

        // --- HOURLY / DAILY / CHANGE UPDATES ---
        if (hourChanged) {
            _lastHour = currentHour;

            var now = Time.now();
            _hoursStr = currentHour.format("%02d");

            var infoShort = Gregorian.info(now, Time.FORMAT_SHORT);
            var infoMedium = Gregorian.info(now, Time.FORMAT_MEDIUM);
            _dayOfWeekStr = infoMedium.day_of_week.toUpper();
            _dateStr = Lang.format("$1$.$2$.$3$", [
                infoShort.day.format("%02d"),
                infoShort.month.format("%02d"),
                infoShort.year
            ]);

            // Clear unavailable fields rather than retaining stale weather.
            _tempStr = "--";
            _hiLowStr = "--/--";

            // Weather Update
            if (Toybox has :Weather) {
                var weather = Weather.getCurrentConditions();
                if (weather != null && weather.temperature != null) {
                    _tempStr = weather.temperature.format("%d") + "°";
                }

                var dailyForecast = Weather.getDailyForecast();
                if (dailyForecast != null && dailyForecast.size() > 0) {
                    var today = dailyForecast[0];
                    if (today.highTemperature != null && today.lowTemperature != null) {
                        _hiLowStr = today.highTemperature.format("%d") + "°/" + today.lowTemperature.format("%d") + "°";
                    }
                }
            }
        }

        // --- MINUTELY UPDATES ---
        if (minuteChanged) {
            _lastMinute = currentMinute;
            _minutesStr = currentMinute.format("%02d");
            updateBatteryLevel(Time.now().value());

            // Steps
            var stepGoal = 5000;
            var monitorInfo = ActivityMonitor.getInfo();
            if (monitorInfo != null) {
                var stepsCount = monitorInfo.steps != null ? monitorInfo.steps : 0;
                _stepsStr = stepsCount.toString();
                stepGoal = monitorInfo.stepGoal != null && monitorInfo.stepGoal > 0 ? monitorInfo.stepGoal : 5000;
                _stepsProgress = stepsCount.toFloat() / stepGoal.toFloat();
                if (_stepsProgress > 1.0) { _stepsProgress = 1.0; }
            }

            // Refresh the 90-minute history every five minute boundaries.
            _minutesSinceGraphUpdate++;
            if (forceUpdate || _minutesSinceGraphUpdate >= 5) {
                updateHrGraphData();
                _minutesSinceGraphUpdate = 0;
            }
        }

        // Refresh data at minute boundaries, but repaint only changed regions.
        // Full restoration is reserved for onShow/onLayout invalidation.
        if (hourChanged || minuteChanged) {
            var heartRate = getHeartRateString();
            _cachedHeartRate = heartRate;
            drawChangedFrame(dc, currentSecond, heartRate, forceUpdate);
        } else {
            drawDynamicRegions(dc, currentSecond, getCachedHeartRateString(currentSecond));
        }
    }

    private function drawChangedFrame(dc as Graphics.Dc, currentSecond as Number, heartRate as String, force as Boolean) as Void {
        dc.clearClip();
        if (force) {
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();
            _drawnTime = "";
            _drawnSeconds = "";
            _timeDigitWidth = digitWidth(dc, timeFontResource);
            _secondDigitWidth = digitWidth(dc, Graphics.FONT_TINY);
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        var baselineY = dc.getHeight() / 2 + 30;
        var timeFont = timeFontResource;
        var tinyFont = Graphics.FONT_TINY;
        var timeHeight = dc.getFontHeight(timeFont);
        var tinyHeight = dc.getFontHeight(tinyFont);

        // Independent regions have fixed bounds so shrinking strings erase cleanly.
        var topFont = Graphics.FONT_XTINY;
        var weatherKey = _tempStr + " " + _hiLowStr;
        if (force || !weatherKey.equals(_drawnWeather)) {
            clearRegion(dc, 0, 0, 113, 20);
            dc.drawText(25, 5, topFont, weatherKey, Graphics.TEXT_JUSTIFY_LEFT);
            _drawnWeather = weatherKey;
        }
        var statsKey = _stepsStr + " " + _drainStr;
        if (force || !statsKey.equals(_drawnStats)) {
            clearRegion(dc, 0, 20, 113, 20);
            dc.drawText(20, 20, topFont, _stepsStr, Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(60, 20, topFont, _drainStr, Graphics.TEXT_JUSTIFY_LEFT);
            _drawnStats = statsKey;
        }
        dc.clearClip();

        var timeY = baselineY - timeHeight;
        var secX = 4 * _timeDigitWidth + 4;
        var xtinyFont = Graphics.FONT_SYSTEM_XTINY;
        var xtinyHeight = dc.getFontHeight(xtinyFont);
        var timeText = _hoursStr + _minutesStr;
        if (force || !_dateStr.equals(_drawnDate)) {
            clearRegion(dc, 0, timeY - 5, 4 * _timeDigitWidth, tinyHeight);
            dc.drawText(0, timeY - 5, tinyFont, _dateStr, Graphics.TEXT_JUSTIFY_LEFT);
            // The date's font box overlaps the top of the large digits.
            // Restore their intersecting pixels after clearing the date.
            for (var d = 0; d < 4; d++) {
                dc.drawText(d * _timeDigitWidth, timeY, timeFont,
                    timeText.substring(d, d + 1), Graphics.TEXT_JUSTIFY_LEFT);
            }
            dc.clearClip();
            _drawnDate = _dateStr;
        }
        for (var i = 0; i < 4; i++) {
            if (force || !_drawnTime.substring(i, i + 1).equals(timeText.substring(i, i + 1))) {
                clearRegion(dc, i * _timeDigitWidth, timeY, _timeDigitWidth, timeHeight);
                dc.drawText(i * _timeDigitWidth, timeY, timeFont,
                    timeText.substring(i, i + 1), Graphics.TEXT_JUSTIFY_LEFT);
                dc.drawText(0, timeY - 5, tinyFont, _dateStr, Graphics.TEXT_JUSTIFY_LEFT);
            }
        }
        dc.clearClip();
        _drawnTime = timeText;
        if (force || !_dayOfWeekStr.equals(_drawnDay)) {
            clearRegion(dc, secX, baselineY - tinyHeight - xtinyHeight,
                25, xtinyHeight);
            dc.drawText(secX, baselineY - tinyHeight - xtinyHeight,
                xtinyFont, _dayOfWeekStr, Graphics.TEXT_JUSTIFY_LEFT);
            _drawnDay = _dayOfWeekStr;
        }
        dc.clearClip();
        _secClipX = secX;
        _secClipY = baselineY - tinyHeight;
        _secClipH = tinyHeight;
        drawSeconds(dc, currentSecond);

        var progress = (_stepsProgress * 360).toNumber();
        if (force || progress != _drawnProgress || !heartRate.equals(_lastDrawnHeartRate)) {
            clearRegion(dc, 113, 0, dc.getWidth() - 113, 64);
            // Restore the narrow overlap with the main time/date before the eye.
            dc.drawText(3 * _timeDigitWidth, timeY, timeFont,
                timeText.substring(3, 4), Graphics.TEXT_JUSTIFY_LEFT);
            dc.drawText(0, timeY - 5, tinyFont, _dateStr, Graphics.TEXT_JUSTIFY_LEFT);
            if (_stepsProgress > 0) {
                dc.setPenWidth(5);
                dc.drawArc(_subWindowX, _subWindowY, _subWindowR, Graphics.ARC_CLOCKWISE, 90, (90 - (_stepsProgress * 360)).toNumber());
            }

            // The digits' ink sits low within the font box, so vertically
            // centring on the sub-window centre reads as slightly too low.
            // Nudge the text up; the clip box moves with it so the per-second
            // path (which draws at the clip centre) stays in step.
            var hrTextY = _subWindowY - 3;
            dc.drawText(_subWindowX, hrTextY, Graphics.FONT_NUMBER_MILD, heartRate, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

            // Size the HR clip box for the widest value we can show ("888"), so
            // a 2 -> 3 digit change can never get cut off, and keep the full
            // font height. Don't try to shrink this box to dodge the progress
            // ring: the digits' ink sits lower than the box centre, so clamping
            // the height symmetrically shaves the bottoms off glyphs like 4 and
            // 7. The ring is restored by repainting it in drawDynamicRegions.
            var hrWidth = dc.getTextWidthInPixels("888", Graphics.FONT_NUMBER_MILD);
            var hrHeight = dc.getFontHeight(Graphics.FONT_NUMBER_MILD);
            _hrClipX = _subWindowX - hrWidth / 2;
            _hrClipY = hrTextY - hrHeight / 2;
            _hrClipW = hrWidth;
            _hrClipH = hrHeight;
            _lastDrawnHeartRate = heartRate;

            dc.clearClip();
            _drawnProgress = progress;
        }

        // Quantize the key to the actual displayed fill and percentage.
        var batteryKey = _batteryStr + ":" + (_batteryLevel / 100.0 * 24).toNumber();
        if (force || !batteryKey.equals(_drawnBattery)) {
            var batX = secX + 25, batY = baselineY - 34, batW = 16, batH = 28;
            clearRegion(dc, batX, batY - 4, batW + 1, batH + 5);
            dc.setPenWidth(1);
            dc.drawRectangle(batX, batY, batW, batH);
            dc.fillRectangle(batX + 4, batY - 4, 8, 4); // Tip

            var batteryFill = (_batteryLevel / 100.0 * (batH - 4)).toNumber();
            if (batteryFill > 0) {
                dc.fillRectangle(batX + 2, batY + batH - 2 - batteryFill, batW - 4, batteryFill);
            }
            clearRegion(dc, batX - 7, batY + batH + 1, 31, 130 - (batY + batH + 1));
            dc.drawText(batX + 8, batY + batH + 1, Graphics.FONT_XTINY, _batteryStr, Graphics.TEXT_JUSTIFY_CENTER);

            dc.clearClip();
            _drawnBattery = batteryKey;
        }
        if (force || _graphDirty) {
            clearRegion(dc, 0, 130, dc.getWidth(), dc.getHeight() - 130);
            renderHrGraph(dc, 5, 130, 120, 40);
            dc.clearClip();
            _graphDirty = false;
        }
    }

    private function digitWidth(dc, font) as Number {
        var width = 0;
        for (var i = 0; i < 10; i++) {
            var w = dc.getTextWidthInPixels(i.toString(), font);
            if (w > width) { width = w; }
        }
        return width;
    }

    private function clearRegion(dc, x, y, width, height) as Void {
        dc.setClip(x, y, width, height);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
    }

    private function drawSeconds(dc as Graphics.Dc, second as Number) as Void {
        var text = second.format("%02d");
        for (var i = 0; i < 2; i++) {
            if (_drawnSeconds.length() != 2 ||
                !_drawnSeconds.substring(i, i + 1).equals(text.substring(i, i + 1))) {
                var x = _secClipX + i * _secondDigitWidth;
                clearRegion(dc, x, _secClipY, _secondDigitWidth, _secClipH);
                dc.drawText(x, _secClipY, Graphics.FONT_TINY,
                    text.substring(i, i + 1), Graphics.TEXT_JUSTIFY_LEFT);
            }
        }
        dc.clearClip();
        _drawnSeconds = text;
    }

    // A rejected partial frame was not displayed: invalidate its digit cache.
    function invalidateSeconds() as Void {
        _drawnSeconds = "";
    }

    // Cheap path: refreshes only the regions that change every second
    // (seconds text, heart rate) without touching the rest of the screen.
    private function drawDynamicRegions(dc as Graphics.Dc, currentSecond as Number, heartRate as String) as Void {
        drawSeconds(dc, currentSecond);

        // Update Heart Rate only when it actually changed - it rarely moves
        // every second, so this skips a clear+redraw on most calls.
        if (!heartRate.equals(_lastDrawnHeartRate)) {
            dc.setClip(_hrClipX, _hrClipY, _hrClipW, _hrClipH);
            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();

            // The clip box has to cover the full font box to avoid clipping
            // glyphs, so its corners overlap the progress ring and the clear
            // above takes a bite out of it. Repaint the ring slice inside
            // the same clip. Only runs when HR changes, not every second.
            if (_stepsProgress > 0) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.setPenWidth(5);
                dc.drawArc(_subWindowX, _subWindowY, _subWindowR, Graphics.ARC_CLOCKWISE, 90, (90 - (_stepsProgress * 360)).toNumber());
                dc.setPenWidth(1); // don't leak pen state into later draws
            }

            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(_hrClipX + _hrClipW/2, _hrClipY + _hrClipH/2, Graphics.FONT_NUMBER_MILD, heartRate, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            _lastDrawnHeartRate = heartRate;
        }

        dc.clearClip();
    }

    function onPartialUpdate(dc as Graphics.Dc) as Void {
        if (!_isVisible || !_isSleep || _lastMinute == -1) { return; }

        var clockTime = System.getClockTime();
        // Keep sensor/history reads and the eye region out of the sleep budget.
        drawSeconds(dc, clockTime.sec);
    }

    // Active mode only: refresh heart rate at most every five seconds.
    // Sleeping mode reads it at the minute boundary in onUpdate().
    private function getCachedHeartRateString(currentSecond as Number) as String {
        if (_cachedHeartRate.equals("") || currentSecond % 5 == 0) {
            _cachedHeartRate = getHeartRateString();
        }
        return _cachedHeartRate;
    }

    private function getHeartRateString() as String {
        var heartRate = "--";
        var activityInfo = Activity.getActivityInfo();
        if (activityInfo != null && activityInfo.currentHeartRate != null) {
            heartRate = activityInfo.currentHeartRate.toString();
        } else if (ActivityMonitor has :getHeartRateHistory) {
            var hrHistory = ActivityMonitor.getHeartRateHistory(1, true);
            if (hrHistory != null) {
                var hrSample = hrHistory.next();
                if (hrSample != null && hrSample.heartRate != ActivityMonitor.INVALID_HR_SAMPLE && hrSample.heartRate != null) {
                    heartRate = hrSample.heartRate.toString();
                }
            }
        }
        return heartRate;
    }

    private function updateBatteryLevel(nowTimestamp as Number) as Void {
        var systemStats = System.getSystemStats();
        var battery = systemStats.battery;
        _batteryLevel = battery;
        _batteryStr = battery.format("%d") + "%";

        var lastChargeLevel = Storage.getValue("lastChargeLevel");
        var lastChargeTime = Storage.getValue("lastChargeTime");
        var prevBattery = Storage.getValue("prevBattery");

        var charging = systemStats.charging;
        // Track the baseline through charging and reset when disconnected.
        // The level-rise check also catches charging while this face was hidden.
        if (lastChargeLevel == null || lastChargeTime == null || charging || _wasCharging ||
            (prevBattery != null && battery > prevBattery + 1)) {
            lastChargeLevel = battery;
            lastChargeTime = nowTimestamp;
            Storage.setValue("lastChargeLevel", lastChargeLevel);
            Storage.setValue("lastChargeTime", lastChargeTime);
        }
        if (prevBattery == null || prevBattery != battery) {
            Storage.setValue("prevBattery", battery);
        }
        _wasCharging = charging;
        _drainStr = "--%/d";

        if (!charging && lastChargeTime != null && nowTimestamp > lastChargeTime) {
            var daysPassed = (nowTimestamp - lastChargeTime).toFloat() / 86400.0;
            if (daysPassed > 0.01) {
                var drainPerDay = (lastChargeLevel - battery) / daysPassed;
                _drainStr = drainPerDay > 0 ? drainPerDay.format("%.1f") + "%/d" : "--%/d";
            }
        }
    }

    private function updateHrGraphData() as Void {
        _graphDirty = true;
        _hrSampleCount = 0;
        _hrMin = 0;
        _hrMax = 0;
        for (var i = 0; i < 90; i++) { _hrSamples[i] = null; }

        if (!(ActivityMonitor has :getHeartRateHistory)) { return; }
        var now = Time.now().value();
        var hrHistory = ActivityMonitor.getHeartRateHistory(new Time.Duration(90 * 60), true);

        var min = 255, max = 0, validCount = 0;
        var sample = hrHistory.next();
        while (sample != null) {
            var age = now - sample.when.value();
            var hr = sample.heartRate;
            // Timestamp-based minute buckets preserve gaps and the time scale
            // regardless of the device's history sampling interval. Keep the
            // newest valid reading in each bucket (the iterator is newest first).
            if (age >= 0 && age < 90 * 60 && hr != null && hr != ActivityMonitor.INVALID_HR_SAMPLE) {
                var bucket = age / 60;
                if (_hrSamples[bucket] == null) {
                    _hrSamples[bucket] = hr;
                    if (hr < min) { min = hr; }
                    if (hr > max) { max = hr; }
                    validCount++;
                }
            }
            sample = hrHistory.next();
        }
        if (validCount > 0) {
            _hrSampleCount = 90;
            _hrMin = min;
            _hrMax = max;
        }
    }

    private function renderHrGraph(dc as Graphics.Dc, x as Number, y as Number, width as Number, height as Number) as Void {
        if (_hrSampleCount == 0) {
            dc.drawText(x + width / 2, y + height / 2, Graphics.FONT_XTINY,
                "HR --", Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            return;
        }

        var displayMin = _hrMin;
        var displayMax = _hrMax;
        var minHr = _hrMin;
        var maxHr = _hrMax;

        if (minHr >= maxHr) {
            if (minHr != 255 && minHr != 0) {
                minHr -= 5; maxHr += 5;
            } else {
                minHr = 60; maxHr = 80;
            }
        }

        var padMinHr = minHr - 2;
        var padMaxHr = maxHr + 2;
        var range = (padMaxHr - padMinHr).toFloat();

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        dc.drawLine(x, y, x + width, y);
        dc.drawLine(x + width, y, x + width, y + height);

        var centerY = y + height / 2;
        for (var dx = 2; dx < width; dx += 6) {
            dc.drawLine(x + dx, centerY, x + dx + 3, centerY);
        }

        for (var m = 30; m < 90; m += 30) {
            var vx = x + (width - 1) - (m.toFloat() * (width - 1) / 89.0).toNumber();
            for (var vy = 0; vy < height; vy += 4) {
                dc.drawLine(vx, y + vy, vx, y + vy + 2);
            }
        }

        dc.drawText(x + width + 2, y + 5, Graphics.FONT_XTINY, displayMax, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x + width + 2, y + height - 10, Graphics.FONT_XTINY, displayMin, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);

        dc.setPenWidth(2);
        var lastX = -1, lastY = -1;
        for (var i = 0; i < _hrSampleCount; i++) {
            var hr = _hrSamples[i];
            if (hr != null) {
                var currentX = x + (width - 1) - (i.toFloat() * (width - 1) / 89.0).toNumber();
                var currentY = y + height - ((hr - padMinHr).toFloat() / range * height).toNumber();
                dc.drawPoint(currentX, currentY);
                if (lastX != -1) { dc.drawLine(lastX, lastY, currentX, currentY); }
                lastX = currentX; lastY = currentY;
            } else {
                lastX = -1; lastY = -1;
            }
        }
    }

    // Called when this View is removed from the screen. Save the
    // state of this View here. This includes freeing resources from
    // memory.
    function onHide() as Void {
        // Something else owns the display now (app, widget, system alert).
        // Stop painting: our clip-based updates would otherwise punch
        // rectangles of watch face content into whatever is covering us.
        _isVisible = false;
    }

    // The user has just looked at their watch. Timers and animations may be started here.
    function onExitSleep() as Void {
        _isSleep = false;
        WatchUi.requestUpdate();
    }

    // Terminate any active timers and prepare for slow updates.
    function onEnterSleep() as Void {
        _isSleep = true;
        WatchUi.requestUpdate();
    }

}
