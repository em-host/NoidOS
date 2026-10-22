// Adds a "Nix Actions" button to the system menu, right next to the power
// button. Clicking it opens the Nix Actions menu (the `nix-actions` command,
// installed by modules/common/nix-actions.nix), where rebuilding, updating,
// adding a flake and cleaning up are chosen.

import Gio from 'gi://Gio';
import St from 'gi://St';

import {Extension, gettext as _} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as Util from 'resource:///org/gnome/shell/misc/util.js';

const COMMAND = 'nix-actions';

export default class NixActionsButton extends Extension {
    enable() {
        // The row of buttons at the bottom of the system menu
        // (screenshot, settings, lock, power). The power button is its last child.
        const system = Main.panel.statusArea.quickSettings?._system;
        const row = (system?._systemItem ?? system?.quickSettingsItems?.[0])?.child;
        const powerButton = row?.get_last_child();

        if (!row || !powerButton) {
            console.warn('[nix-actions] could not find the power button row; ' +
                'the GNOME Shell layout may have changed.');
            return;
        }

        this._button = new St.Button({
            style_class: 'icon-button',
            can_focus: true,
            accessible_name: _('Nix Actions'),
            child: new St.Icon({
                gicon: new Gio.ThemedIcon({
                    // First one that exists in the icon theme wins.
                    names: [
                        'system-software-update-symbolic',
                        'software-update-available-symbolic',
                        'view-refresh-symbolic',
                    ],
                }),
            }),
        });

        this._button.connect('clicked', () => {
            Main.panel.closeQuickSettings();
            Util.spawn([COMMAND]);
        });

        // Put it directly before (to the left of) the power button.
        row.insert_child_below(this._button, powerButton);
    }

    disable() {
        this._button?.destroy();
        this._button = null;
    }
}
