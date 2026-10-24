import Toybox.Application;
import Toybox.WatchUi;

class Instinct2DraftApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state) {
    }

    // onStop() is called when your application is exiting
    function onStop(state) {
    }

    // Return the initial view of your application here
    function getInitialView() {
        var view = new Instinct2DraftView();
        return [ view, new PowerEfficientDelegate(view) ];
    }

}

function getApp() as Instinct2DraftApp {
    return Application.getApp() as Instinct2DraftApp;
}

// Discard cached seconds after a rejected partial update so the next accepted
// frame repairs both digits, including a rejected tens-digit rollover.
class PowerEfficientDelegate extends WatchUi.WatchFaceDelegate {
    private var _view;

    function initialize(view) {
        WatchFaceDelegate.initialize();
        _view = view;
    }

    function onPowerBudgetExceeded(powerInfo) as Void {
        _view.invalidateSeconds();
    }
}
