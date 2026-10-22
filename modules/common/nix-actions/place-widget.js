// Plasma desktop-scripting code. Adds the "Nix Actions" widget to the panel
// if it is not on any panel yet. Safe to run on every login.
//
// It goes right after the Lock/Logout (power) widget when there is one,
// otherwise at the far end of the panel.
//
// The result is reported with print(); place-widget.sh reads it.

// (The id still has the name from when this was only the Rebuild button, so a
// panel that already has the button keeps it.)
var WIDGET = "org.nixos.rebuildbutton";
var POWER_WIDGET = "org.kde.plasma.lock_logout";

var allPanels = panels();

if (allPanels.length === 0) {
    print("no-panel");
} else {
    var alreadyThere = false;
    for (var i = 0; i < allPanels.length; i++) {
        if (allPanels[i].widgets(WIDGET).length > 0) {
            alreadyThere = true;
        }
    }

    if (alreadyThere) {
        print("present");
    } else {
        var panel = allPanels[0];
        var widget = panel.addWidget(WIDGET);

        // On failure Plasma returns an Error object instead of a widget, so
        // check for a real widget (it has a numeric index) rather than truthiness.
        if (!widget || typeof widget.index !== "number") {
            print("unknown-widget");
        } else {
            var power = panel.widgets(POWER_WIDGET);
            if (power.length > 0) {
                widget.index = power[0].index + 1;
            }
            print("added");
        }
    }
}
