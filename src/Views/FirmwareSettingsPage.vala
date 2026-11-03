/* SPDX-License-Identifier: GPL-3.0-or-later */

public class About.FirmwareSettingsPage : Switchboard.SettingsPage {
    public FirmwareSettingsPage () {
        Object (
            header: _("Maintenance"),
            icon: new ThemedIcon ("preferences-system"),
            title: _("Firmware Settings"),
            description: _("Configure the firmware settings reported by this device. Changes may require a restart.")
        );
    }

    construct {
        var editor = new FirmwareSettingsView ();
        var navigation = new Adw.NavigationView ();
        navigation.add (editor);
        child = navigation;
        map.connect (() => editor.load.begin ());
    }
}
