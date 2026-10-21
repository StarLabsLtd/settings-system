/* SPDX-License-Identifier: GPL-3.0-or-later */

internal abstract class About.FirmwareSettingsBackend : Object {
    internal signal void pending_reboot_changed ();
    internal abstract bool pending_reboot { get; }

    internal abstract async void connect_client (Cancellable cancellable) throws Error;
    internal abstract async bool authorize_read (Cancellable cancellable) throws Error;
    internal abstract async void enable_authentication (Cancellable cancellable) throws Error;
    internal abstract async Fwupd.BiosSetting[] read (Cancellable cancellable) throws Error;
    internal abstract async void write (HashTable<string, string> changes) throws Error;
}

internal errordomain About.FirmwareSettingsError {
    AUTH_FAILED
}

internal class About.FwupdFirmwareSettingsBackend : FirmwareSettingsBackend {
    private Fwupd.Client client = new Fwupd.Client ();

    construct {
#if HAS_FWUPD_PENDING_REBOOT
        client.notify["pending-reboot"].connect (() => pending_reboot_changed ());
#endif
    }

    internal override bool pending_reboot {
        get {
#if HAS_FWUPD_PENDING_REBOOT
            return client.get_pending_reboot ();
#else
            return false;
#endif
        }
    }

    internal override async void connect_client (Cancellable cancellable) throws Error {
        yield client.connect_async (cancellable);
    }

    internal override async bool authorize_read (Cancellable cancellable) throws Error {
        var connection = yield Bus.get (BusType.SYSTEM, cancellable);
        var subject = new Polkit.SystemBusName (connection.get_unique_name ());
        var authority = yield Polkit.Authority.get_async (cancellable);
        var result = yield authority.check_authorization (
            subject,
            "org.freedesktop.fwupd.get-bios-settings",
            null,
            Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION,
            cancellable
        );
        return result.get_is_authorized ();
    }

    internal override async void enable_authentication (Cancellable cancellable) throws Error {
        yield client.set_feature_flags_async (Fwupd.FeatureFlags.ALLOW_AUTHENTICATION, cancellable);
    }

    internal override async Fwupd.BiosSetting[] read (Cancellable cancellable) throws Error {
        Fwupd.BiosSetting[] result = {};
        foreach (var setting in yield client.get_bios_settings_async (cancellable)) {
            result += setting;
        }
        return result;
    }

    internal override async void write (HashTable<string, string> changes) throws Error {
        try {
            yield ((BiosSettingsClient) client).modify (changes, null);
        } catch (Fwupd.Error.AUTH_FAILED e) {
            throw new FirmwareSettingsError.AUTH_FAILED (e.message);
        }
    }
}

// libfwupd serializes the table without consuming its container.
[Compact]
[CCode (cname = "FwupdClient", cheader_filename = "fwupd.h")]
private extern class BiosSettingsClient {
    [CCode (cname = "fwupd_client_modify_bios_setting_async", finish_name = "fwupd_client_modify_bios_setting_finish")]
    public extern async bool modify (HashTable<string, string> changes, Cancellable? cancellable) throws Error;
}
