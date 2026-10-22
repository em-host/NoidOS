// A panel button for Nix Actions. Clicking it opens the Nix Actions menu (the
// `nix-actions` command, installed by modules/common/nix-actions.nix), where
// rebuilding, updating, adding a flake and cleaning up are chosen.
//
// Built like Plasma's own click-only widgets (Show Desktop, Icon): the icon is
// the whole widget, and clicking or pressing Enter "activates" it. That also
// makes a global keyboard shortcut for it possible (right-click > Configure).

import QtQuick
import QtQuick.Layouts

import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    readonly property string command: "nix-actions"

    preferredRepresentation: fullRepresentation
    toolTipSubText: i18n("Rebuild, update, add programs, clean up")

    Plasmoid.icon: "system-software-update"
    Plasmoid.title: i18n("Nix Actions")
    Plasmoid.backgroundHints: PlasmaCore.Types.NoBackground

    // Starts the menu. The time after the "#" is only there to make every click
    // a new command for the "executable" engine (the shell ignores everything
    // after the "#"). Without it, a click while an earlier one is still running
    // would do nothing, and that one lasts as long as the terminal of a rebuild
    // stays open.
    Plasmoid.onActivated: executable.connectSource(root.command + " # " + Date.now())

    Layout.minimumWidth: Kirigami.Units.iconSizes.medium
    Layout.minimumHeight: Kirigami.Units.iconSizes.medium
    Layout.maximumWidth: Layout.minimumWidth
    Layout.maximumHeight: Layout.minimumHeight
    Layout.preferredWidth: Layout.minimumWidth
    Layout.preferredHeight: Layout.minimumHeight

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []
        onNewData: (sourceName, data) => disconnectSource(sourceName)
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent

        activeFocusOnTab: true
        hoverEnabled: true

        onClicked: Plasmoid.activated()

        Keys.onPressed: event => {
            switch (event.key) {
            case Qt.Key_Space:
            case Qt.Key_Enter:
            case Qt.Key_Return:
            case Qt.Key_Select:
                Plasmoid.activated();
                break;
            }
        }

        Accessible.name: Plasmoid.title
        Accessible.description: root.toolTipSubText
        Accessible.role: Accessible.Button
        Accessible.onPressAction: Plasmoid.activated()

        Kirigami.Icon {
            anchors.fill: parent
            active: mouseArea.containsMouse
            source: Plasmoid.icon
            fallback: "view-refresh"
        }

        PlasmaCore.ToolTipArea {
            anchors.fill: parent
            mainText: Plasmoid.title
            subText: root.toolTipSubText
            textFormat: Text.PlainText
        }
    }
}
