/* SPDX-License-Identifier: GPL-3.0-or-later */

internal abstract class About.FirmwareSettingsBackend : Object {
    internal abstract async Fwupd.BiosSetting[] read () throws Error;
    internal abstract async void write (string id, string value) throws Error;
}

internal class About.FwupdFirmwareSettingsBackend : FirmwareSettingsBackend {
    private Fwupd.Client client = new Fwupd.Client ();

    internal override async Fwupd.BiosSetting[] read () throws Error {
        yield client.connect_async (null);
        yield client.set_feature_flags_async (Fwupd.FeatureFlags.ALLOW_AUTHENTICATION, null);
        Fwupd.BiosSetting[] result = {};
        foreach (var setting in yield client.get_bios_settings_async (null)) {
            result += setting;
        }
        return result;
    }

    internal override async void write (string id, string value) throws Error {
        var changes = new HashTable<string, string> (str_hash, str_equal);
        changes.insert (id, value);
        yield client.modify_bios_setting_async ((owned) changes, null);
    }
}
