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
    
    // Cached data members
    private var _lastMinute as Number = -1;
    private var _lastHour as Number = -1;
    private var _lastDay as Number = -1;
    
    // Per-minute cached data
    private var _minutesStr as String = "";
    private var _stepsStr as String = "0";
    private var _stepsProgress as Float = 0.0;
    private var _hrSamples as Array<Number or Null>;
    private var _hrSampleCount as Number = 0;
    private var _hrMin as Number = 0;
    private var _hrMax as Number = 0;
    
    // Per-hour/change cached data
    private var _hoursStr as String = "";
    private var _dateStr as String = "";
    private var _dayOfWeekStr as String = "";
    private var _tempStr as String = "--";
    private var _hiLowStr as String = "--/--";
    private var _batteryStr as String = "0%";
    private var _batteryLevel as Float = 0.0;
    private var _drainStr as String = "--%/d";
    
    // Partial update state
    private var _isSleep as Boolean = false;
    private var _secClipX as Number = 0;
    private var _secClipY as Number = 0;
    private var _secClipW as Number = 0;
    private var _secClipH as Number = 0;
    private var _hrClipX as Number = 0;
    private var _hrClipY as Number = 0;
    private var _hrClipW as Number = 0;
    private var _hrClipH as Number = 0;

    function initialize() {
        WatchFace.initialize();
        System.println("View initialize");
        
        // Load custom font resource once
        try {
            timeFontResource = WatchUi.loadResource(Rez.Fonts.LargeTimeFont);
        } catch (e) {
            System.println("Failed to load custom font: " + e.getErrorMessage());
            timeFontResource = Graphics.FONT_SYSTEM_NUMBER_THAI_HOT;
        }

        // Pre-allocate HR samples array (90 minutes)
        _hrSamples = new [90];
    }

    // Load your resources here
    function onLayout(dc as Dc) as Void {
        setLayout(null);
    }

    // Called when this View is brought to the foreground. Restore
    // the state of this View and prepare it to be shown. This includes
    // loading resources into memory.
    function onShow() as Void {
    }

    // Update the view
    function onUpdate(dc as Graphics.Dc) as Void {
        var now = Time.now();
        var clockTime = System.getClockTime();
        var currentSecond = clockTime.sec;
        var currentMinute = clockTime.min;
        var currentHour = clockTime.hour;
        var infoShort = Gregorian.info(now, Time.FORMAT_SHORT);
        var currentDay = infoShort.day;

        var forceUpdate = (_lastMinute == -1);

        // --- HOURLY / DAILY / CHANGE UPDATES ---
        if (forceUpdate || currentHour != _lastHour || currentDay != _lastDay) {
            _lastHour = currentHour;
            _lastDay = currentDay;

            _hoursStr = currentHour.format("%02d");
            
            var infoMedium = Gregorian.info(now, Time.FORMAT_MEDIUM);
            _dayOfWeekStr = infoMedium.day_of_week.toUpper();
            _dateStr = Lang.format("$1$.$2$.$3$", [
                infoShort.day.format("%02d"),
                infoShort.month.format("%02d"),
                infoShort.year
            ]);

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

            // Battery Update (Hourly or if charging state changes)
            updateBatteryLevel(now.value());
        }

        // --- MINUTELY UPDATES ---
        if (forceUpdate || currentMinute != _lastMinute) {
            _lastMinute = currentMinute;
            _minutesStr = currentMinute.format("%02d");

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

            // Update HR Graph data samples
            updateHrGraphData();
            
            // Re-update battery drain if needed (could be minutely for more precision if desired, 
            // but usually hourly is enough. Let's stick to hourly/change for drain too to save CPU).
        }

        // --- PER-SECOND UPDATES ---
        var secondsStr = currentSecond.format("%02d");
        var heartRate = getHeartRateString();

        // --- DRAWING ---
        dc.clearClip(); // Ensure we are not drawing with a clip from partial update
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        var baselineY = dc.getHeight() / 2 + 30;
        var timeFont = timeFontResource;
        var tinyFont = Graphics.FONT_TINY;
        var timeHeight = dc.getFontHeight(timeFont);
        var tinyHeight = dc.getFontHeight(tinyFont);
        
        // Top Stats
        var topFont = Graphics.FONT_XTINY;
        dc.drawText(25, 5, topFont, _tempStr, Graphics.TEXT_JUSTIFY_LEFT);
        var tempWidth = dc.getTextWidthInPixels(_tempStr, topFont);
        dc.drawText(25 + tempWidth + 2, 5, topFont, _hiLowStr, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(20, 20, topFont, _stepsStr, Graphics.TEXT_JUSTIFY_LEFT);
        
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(60, 20, topFont, _drainStr, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);

        // Date & Time
        dc.drawText(0, baselineY - timeHeight - 5, tinyFont, _dateStr, Graphics.TEXT_JUSTIFY_LEFT);
        dc.drawText(0, baselineY - timeHeight, timeFont, _hoursStr, Graphics.TEXT_JUSTIFY_LEFT);
        var hoursWidth = dc.getTextWidthInPixels(_hoursStr, timeFont);
        
        var minX = hoursWidth;
        dc.drawText(minX, baselineY - timeHeight, timeFont, _minutesStr, Graphics.TEXT_JUSTIFY_LEFT);
        var minutesWidth = dc.getTextWidthInPixels(_minutesStr, timeFont);

        var secX = minX + minutesWidth + 4;
        var xtinyFont = Graphics.FONT_SYSTEM_XTINY;
        var xtinyHeight = dc.getFontHeight(xtinyFont);
        dc.drawText(secX, baselineY - tinyHeight - xtinyHeight + 5, xtinyFont, _dayOfWeekStr, Graphics.TEXT_JUSTIFY_LEFT);
        
        // Draw Seconds and calculate Clip
        dc.drawText(secX, baselineY - tinyHeight, tinyFont, secondsStr, Graphics.TEXT_JUSTIFY_LEFT);
        var secWidth = dc.getTextWidthInPixels("00", tinyFont);
        _secClipX = secX;
        _secClipY = baselineY - tinyHeight;
        _secClipW = secWidth;
        _secClipH = tinyHeight;

        // Sub-window ("Eye")
        var subWindowX = 144, subWindowY = 31, subWindowR = 28;
        if (WatchUi has :getSubscreen) {
            var subscreen = WatchUi.getSubscreen();
            if (subscreen != null) {
                subWindowX = subscreen.x + (subscreen.width / 2);
                subWindowY = subscreen.y + (subscreen.height / 2);
                subWindowR = subscreen.width / 2 - 5;
            }
        }

        if (_stepsProgress > 0) {
            dc.setPenWidth(5);
            dc.drawArc(subWindowX, subWindowY, subWindowR, Graphics.ARC_CLOCKWISE, 90, (90 - (_stepsProgress * 360)).toNumber());
        }

        dc.drawText(subWindowX, subWindowY, Graphics.FONT_NUMBER_MILD, heartRate, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        var hrWidth = dc.getTextWidthInPixels("888", Graphics.FONT_NUMBER_MILD);
        var hrHeight = dc.getFontHeight(Graphics.FONT_NUMBER_MILD);
        _hrClipX = subWindowX - hrWidth / 2;
        _hrClipY = subWindowY - hrHeight / 2;
        _hrClipW = hrWidth;
        _hrClipH = hrHeight;
        
        // Battery Icon
        var batX = secX + 25, batY = baselineY - 34, batW = 16, batH = 28;
        dc.setPenWidth(1);
        dc.drawRectangle(batX, batY, batW, batH);
        dc.fillRectangle(batX + 4, batY - 4, 8, 4); // Tip
        
        var batteryFill = (_batteryLevel / 100.0 * (batH - 4)).toNumber();
        if (batteryFill > 0) {
            dc.fillRectangle(batX + 2, batY + batH - 2 - batteryFill, batW - 4, batteryFill);
        }
        dc.drawText(batX + 8, batY + batH + 1, Graphics.FONT_XTINY, _batteryStr, Graphics.TEXT_JUSTIFY_CENTER);

        // HR Graph
        renderHrGraph(dc, 5, 130, 120, 40);
    }

    function onPartialUpdate(dc as Graphics.Dc) as Void {
        if (!_isSleep) { return; }

        var clockTime = System.getClockTime();
        var secondsStr = clockTime.sec.format("%02d");
        var heartRate = getHeartRateString();

        // Update Seconds
        dc.setClip(_secClipX, _secClipY, _secClipW, _secClipH);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_secClipX, _secClipY, Graphics.FONT_TINY, secondsStr, Graphics.TEXT_JUSTIFY_LEFT);

        // Update Heart Rate
        dc.setClip(_hrClipX, _hrClipY, _hrClipW, _hrClipH);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(_hrClipX + _hrClipW/2, _hrClipY + _hrClipH/2, Graphics.FONT_NUMBER_MILD, heartRate, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        
        dc.clearClip();
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
        
        if (lastChargeLevel == null || (prevBattery != null && battery > prevBattery + 1)) {
            lastChargeLevel = battery;
            lastChargeTime = nowTimestamp;
            Storage.setValue("lastChargeLevel", lastChargeLevel);
            Storage.setValue("lastChargeTime", lastChargeTime);
        }
        Storage.setValue("prevBattery", battery);

        if (lastChargeTime != null && nowTimestamp > lastChargeTime) {
            var daysPassed = (nowTimestamp - lastChargeTime).toFloat() / 86400.0;
            if (daysPassed > 0.01) {
                var drainPerDay = (lastChargeLevel - battery) / daysPassed;
                _drainStr = drainPerDay > 0 ? drainPerDay.format("%.1f") + "%/d" : "--%/d";
            }
        }
    }

    private function updateHrGraphData() as Void {
        if (ActivityMonitor has :getHeartRateHistory) {
            var hrHistory = ActivityMonitor.getHeartRateHistory(90, true);
            if (hrHistory != null) {
                var min = 255, max = 0, count = 0;
                var sample = hrHistory.next();
                while (sample != null && count < 90) {
                    var hr = sample.heartRate;
                    if (hr != null && hr != ActivityMonitor.INVALID_HR_SAMPLE) {
                        _hrSamples[count] = hr;
                        if (hr < min) { min = hr; }
                        if (hr > max) { max = hr; }
                    } else {
                        _hrSamples[count] = null;
                    }
                    sample = hrHistory.next();
                    count++;
                }
                _hrSampleCount = count;
                _hrMin = min;
                _hrMax = max;
            }
        }
    }

    private function renderHrGraph(dc as Graphics.Dc, x as Number, y as Number, width as Number, height as Number) as Void {
        if (_hrSampleCount == 0) { return; }

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
