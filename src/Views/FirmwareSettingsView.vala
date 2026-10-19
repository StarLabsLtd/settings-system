/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class About.FirmwareSettingsView : Adw.NavigationPage {
    private Fwupd.Client client = new Fwupd.Client ();
    private Gtk.Box settings_box;
    private Gtk.Label status_label;
    private Gtk.Label reboot_label;
    private Gtk.Button refresh_button;
    private Gtk.Button apply_button;
    private bool busy;
    private bool page_visible;
    private bool reload_pending;
    private Cancellable? operation_cancellable;
    private HashTable<string, string> pending_edits = new HashTable<string, string> (str_hash, str_equal);

    private HashTable<string, Fwupd.BiosSetting> editable_settings = new HashTable<string, Fwupd.BiosSetting> (str_hash, str_equal);

    construct {
        title = _("Firmware Settings");

        var back_button = new Granite.BackButton (_("All Updates")) {
            action_name = "navigation.pop",
            halign = START
        };

        refresh_button = new Gtk.Button.with_label (_("Refresh"));
        map.connect (() => {
            page_visible = true;
            if (reload_pending && !busy) {
                load.begin ();
            }
        });
        shown.connect (() => {
            page_visible = true;
            reload_if_needed ();
        });
        hiding.connect (() => {
            page_visible = false;
            cancel_operation ();
        });
        unmap.connect (() => {
            page_visible = false;
            cancel_operation ();
        });
        var header_bar = new Gtk.HeaderBar () {
            show_title_buttons = false,
            title_widget = new Gtk.Label (title)
        };
        header_bar.pack_start (back_button);
        header_bar.pack_end (refresh_button);
        apply_button = new Gtk.Button.with_label (_("Apply")) { sensitive = false };
        apply_button.add_css_class (Granite.STYLE_CLASS_SUGGESTED_ACTION);
        header_bar.pack_end (apply_button);
        apply_button.clicked.connect (() => save.begin ());

        status_label = new Gtk.Label ("") {
            wrap = true,
            xalign = 0
        };
        reboot_label = new Gtk.Label (_("Restart required to apply firmware settings.")) {
            wrap = true,
            xalign = 0,
            visible = false
        };
        settings_box = new Gtk.Box (VERTICAL, 12);

        var content = new Gtk.Box (VERTICAL, 12) {
            margin_top = 12,
            margin_bottom = 12,
            margin_start = 12,
            margin_end = 12
        };
        content.append (status_label);
        content.append (reboot_label);
        content.append (settings_box);

        var toolbarview = new Adw.ToolbarView () {
            content = new Gtk.ScrolledWindow () { child = content },
            top_bar_style = RAISED_BORDER
        };
        toolbarview.add_top_bar (header_bar);
        child = toolbarview;

        refresh_button.clicked.connect (() => load.begin ());
    }

    public async void load () {
        if (busy) {
            reload_pending = true;
            return;
        }

        reload_pending = false;
        set_busy (true);
        var cancellable = new Cancellable ();
        operation_cancellable = cancellable;
        yield read_settings (cancellable);
        if (operation_cancellable == cancellable) {
            operation_cancellable = null;
        }
        set_busy (false);
        reload_if_needed ();
    }

    private void set_busy (bool value) {
        busy = value;
        settings_box.sensitive = !value;
        refresh_button.sensitive = !value;
        update_apply_button ();
    }

    private void cancel_operation () {
        if (busy) {
            reload_pending = true;
        }
        if (operation_cancellable != null) {
            operation_cancellable.cancel ();
        }
    }

    private void reload_if_needed () {
        if (reload_pending && page_visible && !busy) {
            load.begin ();
        }
    }

    private async Polkit.AuthorizationResult authorize_settings (
        Cancellable cancellable,
        string action_id
    ) throws Error {
        var connection = yield Bus.get (BusType.SYSTEM, cancellable);
        var subject = new Polkit.SystemBusName (connection.get_unique_name ());
        var authority = yield Polkit.Authority.get_async (cancellable);
        return yield authority.check_authorization (
            subject,
            action_id,
            null,
            Polkit.CheckAuthorizationFlags.ALLOW_USER_INTERACTION,
            cancellable
        );
    }

    private async void read_settings (Cancellable cancellable) {
        while (settings_box.get_first_child () != null) {
            settings_box.remove (settings_box.get_first_child ());
        }

        editable_settings.remove_all ();
        status_label.label = _("Loading firmware settings…");
        reboot_label.visible = false;

        try {
            yield client.connect_async (cancellable);
            if (cancellable.is_cancelled ()) {
                return;
            }
            var authorization = yield authorize_settings (
                cancellable,
                "org.freedesktop.fwupd.get-bios-settings"
            );
            if (!authorization.get_is_authorized ()) {
                status_label.label = _("Authentication is required to read firmware settings.");
                return;
            }
            if (cancellable.is_cancelled ()) {
                return;
            }
            yield client.set_feature_flags_async (Fwupd.FeatureFlags.ALLOW_AUTHENTICATION, cancellable);
            if (cancellable.is_cancelled ()) {
                return;
            }
            var settings = yield client.get_bios_settings_async (cancellable);
            if (cancellable.is_cancelled ()) {
                return;
            }
#if HAS_FWUPD_BIOS_METADATA
            var groups = new HashTable<string, Gtk.Box> (str_hash, str_equal);
#endif
            foreach (var setting in settings) {
                // fwupd exposes this status even when other values are hidden.
                if (setting.get_name () == "pending_reboot") {
                    reboot_label.visible |= setting.get_current_value () == "1";
                    continue;
                }

                var parent = settings_box;
#if HAS_FWUPD_BIOS_METADATA
                var group = setting.get_parent ();
                if (group != null && group != "") {
                    parent = groups.lookup (group);
                    if (parent == null) {
                        parent = new Gtk.Box (VERTICAL, 12);
                        var heading = new Gtk.Label (group) { xalign = 0, wrap = true };
                        heading.add_css_class (Granite.STYLE_CLASS_H3_LABEL);
                        heading.add_css_class ("heading");
                        parent.append (heading);
                        groups.insert (group, parent);
                        settings_box.append (parent);
                    }
                }
#endif
                add_setting (setting, parent, pending_edits, this);
            }

            pending_edits.foreach ((id, value) => {
                if (editable_settings.lookup (id) == null) {
                    add_unavailable_draft (id, value);
                }
            });

            status_label.label = settings_box.get_first_child () == null
                ? _("Firmware settings are not available on this device.")
                : _("Authentication may be required to change firmware settings.");
        } catch (Error e) {
            if (cancellable.is_cancelled ()) {
                return;
            }
            status_label.label = _("Unable to load firmware settings: %s").printf (e.message);
        }
    }

    private static void add_setting (Fwupd.BiosSetting setting, Gtk.Box settings_box,
                                     HashTable<string, string> pending, FirmwareSettingsView owner) {
        var current = setting.get_current_value ();
        var editable = !setting.get_read_only () && current != null && setting.get_id () != null;
        if (editable) {
            owner.editable_settings.insert (setting.get_id (), setting);
            if (pending.lookup (setting.get_id ()) == current) {
                pending.remove (setting.get_id ());
            }
        }
        var box = new Gtk.Box (VERTICAL, 6);
        var name_label = new Gtk.Label (setting.get_description () ?? setting.get_name () ?? setting.get_id ()) {
            xalign = 0,
            wrap = true
        };
        box.append (name_label);
#if HAS_FWUPD_BIOS_METADATA
        var help = setting.get_help_text ();
        if (help != null && help != "") {
            var help_label = new Gtk.Label (help) { xalign = 0, wrap = true };
            help_label.add_css_class (Granite.CssClass.DIM);
            box.append (help_label);
        }
#endif

        var controls = new Gtk.Box (HORIZONTAL, 6);
        unowned Gtk.Entry? entry = null;
        unowned Gtk.DropDown? dropdown = null;
        var value = setting.get_id () != null ? pending.lookup (setting.get_id ()) ?? current : current;
        var view = WeakRef (owner);

        if (editable && setting.get_kind () == Fwupd.BiosSettingKind.ENUMERATION) {
            var values = new Gtk.StringList (null);
            uint selected = Gtk.INVALID_LIST_POSITION;
            // libfwupd retains this array despite its container-transfer annotation.
            unowned var possible = get_possible_values (setting);
            for (uint i = 0; i < possible.length; i++) {
                values.append (possible[i]);
                if (possible[i] == value) {
                    selected = i;
                }
            }
            var selector = new Gtk.DropDown (values, null) {
                selected = selected,
                hexpand = true
            };
            dropdown = selector;
            dropdown.update_relation (Gtk.AccessibleRelation.LABELLED_BY, name_label, null, -1);
            controls.append (dropdown);
        } else if (editable && (setting.get_kind () == Fwupd.BiosSettingKind.INTEGER ||
                               setting.get_kind () == Fwupd.BiosSettingKind.STRING)) {
            var input = new Gtk.Entry () {
                text = value,
                hexpand = true
            };
            entry = input;
            entry.update_relation (Gtk.AccessibleRelation.LABELLED_BY, name_label, null, -1);
            controls.append (entry);
            var constraints = setting.get_kind () == Fwupd.BiosSettingKind.INTEGER
                ? _("Range: %s–%s; increment: %s").printf (
                    setting.get_lower_bound ().to_string (), setting.get_upper_bound ().to_string (),
                    setting.get_scalar_increment ().to_string ())
                : _("Length: %s–%s bytes").printf (
                    setting.get_lower_bound ().to_string (), setting.get_upper_bound ().to_string ());
            box.append (new Gtk.Label (constraints) { xalign = 0, wrap = true });
        } else {
            controls.append (new Gtk.Label (current ?? _("Unavailable")) {
                xalign = 0,
                wrap = true,
                selectable = true
            });
            box.append (new Gtk.Label (_("Not Editable")) { xalign = 0 });
        }

        if (entry != null) {
            entry.changed.connect (() => {
                var page = view.get () as FirmwareSettingsView;
                if (page != null) {
                    page.stage_edit (setting, entry.text);
                }
            });
        } else if (dropdown != null) {
            dropdown.notify["selected"].connect (() => {
                var page = view.get () as FirmwareSettingsView;
                var selected = dropdown.selected_item as Gtk.StringObject;
                if (page != null) {
                    page.stage_edit (setting, selected != null ? selected.string : null);
                }
            });
        }

        box.append (controls);
        settings_box.append (box);
    }

    private void add_unavailable_draft (string id, string value) {
        var box = new Gtk.Box (VERTICAL, 6);
        box.append (new Gtk.Label (id) { xalign = 0, wrap = true });
        box.append (new Gtk.Label (value) { xalign = 0, wrap = true, selectable = true });
        box.append (new Gtk.Label (
            _("This pending value cannot currently be applied because the setting is read-only or unavailable.")
        ) { xalign = 0, wrap = true });
        var discard_button = new Gtk.Button.with_label (_("Discard")) { halign = START };
        var view = WeakRef (this);
        var draft = WeakRef (box);
        discard_button.clicked.connect (() => {
            var page = view.get () as FirmwareSettingsView;
            if (page != null) {
                page.pending_edits.remove (id);
                var row = draft.get () as Gtk.Box;
                if (row != null) {
                    page.settings_box.remove (row);
                }
                page.update_apply_button ();
            }
        });
        box.append (discard_button);
        settings_box.append (box);
    }

    [CCode (cname = "fwupd_bios_setting_get_possible_values")]
    private static extern unowned GenericArray<weak string> get_possible_values (Fwupd.BiosSetting setting);

    [CCode (cname = "fwupd_error_quark", cheader_filename = "fwupd.h")]
    private static extern Quark error_quark ();

    private void stage_edit (Fwupd.BiosSetting setting, string? value) {
        string? edited = value;
        if (edited != null && setting.get_kind () == Fwupd.BiosSettingKind.INTEGER && valid_value (setting, edited)) {
            edited = uint64.parse (edited, 10).to_string ();
        }
        if (edited == null || edited == setting.get_current_value ()) {
            pending_edits.remove (setting.get_id ());
        } else {
            pending_edits.insert (setting.get_id (), edited);
        }
        update_apply_button ();
    }

    private void update_apply_button () {
        bool valid = pending_edits.size () > 0;
        foreach (var id in pending_edits.get_keys ()) {
            var setting = editable_settings.lookup (id);
            if (setting == null || !valid_value (setting, pending_edits.lookup (id))) {
                valid = false;
                break;
            }
        }
        apply_button.sensitive = !busy && valid;
    }

    private static bool valid_value (Fwupd.BiosSetting setting, string value) {
        if (setting.get_kind () == Fwupd.BiosSettingKind.ENUMERATION) {
            foreach (var possible in get_possible_values (setting)) {
                if (value == possible) {
                    return true;
                }
            }
            return false;
        }
        var lower = setting.get_lower_bound ();
        var upper = setting.get_upper_bound ();
        if (setting.get_kind () == Fwupd.BiosSettingKind.STRING) {
            return value.length >= lower && value.length <= upper;
        }

        // Avoid floating point widgets: firmware integers can span all of uint64.
        uint64 number;
        if (value.length == 0) {
            return false;
        }
        for (int i = 0; i < value.length; i++) {
            if (!value[i].isdigit ()) {
                return false;
            }
        }
        if (!uint64.try_parse (value, out number, null, 10) || number < lower || number > upper) {
            return false;
        }
        var increment = setting.get_scalar_increment ();
        return increment == 0 || (number - lower) % increment == 0;
    }

    private async void save () {
        if (!apply_button.sensitive) {
            return;
        }

        set_busy (true);
        status_label.label = _("Applying firmware settings…");
        var cancellable = new Cancellable ();
        operation_cancellable = cancellable;
        // Register fwupd's D-Bus errors before the first failed request.
        error_quark ();
        try {
            try {
                var changes = new HashTable<string, string> (str_hash, str_equal);
                pending_edits.foreach ((id, value) => changes.insert (id, value));
                var authorization = yield authorize_settings (
                    cancellable,
                    "org.freedesktop.fwupd.set-bios-settings"
                );
                if (!authorization.get_is_authorized ()) {
                    status_label.label = _("Authentication is required to change firmware settings.");
                    return;
                }
                if (authorization.get_temporary_authorization_id () == null) {
                    status_label.label = _("This system cannot retain authorization to change firmware settings.");
                    return;
                }
                if (cancellable.is_cancelled ()) {
                    return;
                }
                yield client.set_feature_flags_async (Fwupd.FeatureFlags.ALLOW_AUTHENTICATION, cancellable);
                if (cancellable.is_cancelled ()) {
                    return;
                }
                // fwupd's authorization is server-side; cancellation here
                // only abandons the reply, not a write already in progress.
                operation_cancellable = null;
                yield ((BiosSettingsClient) client).modify (changes, null);
            } catch (Fwupd.Error.AUTH_FAILED e) {
                // Authorization fails before any writes; refreshing prompts again.
                if (cancellable.is_cancelled ()) {
                    return;
                }
                status_label.label = _("Authorization is required to change firmware settings.");
                return;
            } catch (Error e) {
                if (cancellable.is_cancelled ()) {
                    return;
                }
                var window = get_root () as Gtk.Window;
                if (page_visible && window != null && window.visible) {
                    var dialog = new Granite.MessageDialog (
                        _("Unable to apply firmware settings"),
                        _("%s\n\nSome changes may already have been applied. Check the current settings before retrying.").printf (e.message),
                        new ThemedIcon ("dialog-error"),
                        Gtk.ButtonsType.CLOSE
                    ) {
                        transient_for = window
                    };
                    dialog.response.connect (dialog.destroy);
                    dialog.present ();
                }
            }

            // Refresh values without discarding unapplied edits.
            if (page_visible && !cancellable.is_cancelled ()) {
                reload_pending = false;
                var refresh_cancellable = new Cancellable ();
                operation_cancellable = refresh_cancellable;
                yield read_settings (refresh_cancellable);
                if (operation_cancellable == refresh_cancellable) {
                    operation_cancellable = null;
                }
            } else {
                reload_pending = true;
            }
        } finally {
            if (operation_cancellable == cancellable) {
                operation_cancellable = null;
            }
            set_busy (false);
            reload_if_needed ();
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
