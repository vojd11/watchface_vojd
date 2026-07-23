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
        return [ new Instinct2DraftView() ];
    }

}

function getApp() as Instinct2DraftApp {
    return Application.getApp() as Instinct2DraftApp;
}
