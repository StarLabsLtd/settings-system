/* SPDX-License-Identifier: GPL-3.0-or-later */

private enum WriteResult {
    SUCCESS,
    AUTH_REJECTED,
    AUTH_CANCELLED,
    PARTIAL
}

private async void next_iteration () {
    Idle.add (() => {
        next_iteration.callback ();
        return Source.REMOVE;
    });
    yield;
}

private class TestBackend : About.FirmwareSettingsBackend {
    internal About.FirmwareSettingsAccess access = READ_WRITE;
    internal Fwupd.BiosSetting[] settings = {};
    internal WriteResult next_result = SUCCESS;
    internal bool hold_enable;
    internal bool hold_write;
    internal bool enable_started;
    internal bool write_started;
    internal uint read_count;
    internal uint write_count;
    internal HashTable<string, string> last_changes = new HashTable<string, string> (str_hash, str_equal);

    internal override bool pending_reboot { get { return false; } }

    internal override async void connect_client (Cancellable cancellable) throws Error {
    }

    internal override async About.FirmwareSettingsAccess authorize (Cancellable cancellable) throws Error {
        return access;
    }

    internal override async void enable_authentication (Cancellable cancellable) throws Error {
        enable_started = true;
        while (hold_enable && !cancellable.is_cancelled ()) {
            yield next_iteration ();
        }
        if (cancellable.is_cancelled ()) {
            throw new IOError.CANCELLED ("cancelled before dispatch");
        }
    }

    internal override async Fwupd.BiosSetting[] read (Cancellable cancellable) throws Error {
        read_count++;
        return settings;
    }

    internal override async void write (HashTable<string, string> changes) throws Error {
        write_started = true;
        write_count++;
        last_changes = new HashTable<string, string> (str_hash, str_equal);
        changes.foreach ((id, value) => last_changes.insert (id, value));
        while (hold_write) {
            yield next_iteration ();
        }

        var result = next_result;
        next_result = SUCCESS;
        if (result == AUTH_REJECTED) {
            throw new About.FirmwareSettingsError.AUTH_FAILED ("authorization rejected");
        }
        if (result == AUTH_CANCELLED) {
            throw new About.FirmwareSettingsError.AUTH_FAILED ("authentication cancelled");
        }

        foreach (var setting in settings) {
            var value = changes.lookup (setting.get_id ());
            if (value != null && (result != PARTIAL || setting.get_id () == "A")) {
                setting.set_current_value (value);
                if (result == PARTIAL) {
                    setting.set_read_only (true);
                }
            }
        }
        if (result == PARTIAL) {
            throw new IOError.FAILED ("partial firmware write");
        }
    }
}

private Fwupd.BiosSetting string_setting (string id, string value, uint64 upper = 32) {
    var setting = new Fwupd.BiosSetting (id, "/test/" + id);
    setting.set_id (id);
    setting.set_name (id);
    setting.set_kind (Fwupd.BiosSettingKind.STRING);
    setting.set_current_value (value);
    setting.set_lower_bound (1);
    setting.set_upper_bound (upper);
    return setting;
}

private Fwupd.BiosSetting integer_setting (string id, string value, uint64 upper = uint64.MAX) {
    var setting = string_setting (id, value, upper);
    setting.set_kind (Fwupd.BiosSettingKind.INTEGER);
    setting.set_scalar_increment (1);
    return setting;
}

private Fwupd.BiosSetting enum_setting (string id, string value, string[] values) {
    var setting = string_setting (id, value);
    setting.set_kind (Fwupd.BiosSettingKind.ENUMERATION);
    foreach (var possible in values) {
        setting.add_possible_value (possible);
    }
    return setting;
}

private async About.FirmwareSettingsView create_view (TestBackend backend) {
    var view = new About.FirmwareSettingsView.with_backend (backend);
    view.set_visible_for_test (true);
    yield view.load ();
    return view;
}

private Gtk.Button? find_apply (Gtk.Widget widget) {
    if (widget is Gtk.Button && ((Gtk.Button) widget).label == "Apply (1)") {
        return (Gtk.Button) widget;
    }
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = find_apply (child);
        if (found != null) return found;
    }
    return null;
}

private Adw.AlertDialog? find_confirmation (Gtk.Widget widget) {
    if (widget is Adw.AlertDialog) return (Adw.AlertDialog) widget;
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = find_confirmation (child);
        if (found != null) return found;
    }
    return null;
}

private Adw.AlertDialog? confirmation (Gtk.Window parent) {
    var windows = Gtk.Window.get_toplevels ();
    for (uint i = 0; i < windows.get_n_items (); i++) {
        var window = (Gtk.Window) windows.get_item (i);
        var dialog = find_confirmation (window);
        if (dialog != null) return dialog;
    }
    return null;
}

private async void confirmation_scenario () {
    var backend = new TestBackend ();
    backend.settings = { string_setting ("A", "old-a") };
    var view = yield create_view (backend);
    var window = new Gtk.Window () { child = view, default_width = 900, default_height = 600 };
    window.present ();
    yield next_iteration ();
    view.edit_for_test ("A", "draft-a");
    var button = find_apply (view);
    assert (button != null);
    button.clicked ();
    var dialog = confirmation (window);
    assert (dialog != null);
    assert (backend.write_count == 0);
    dialog.response ("cancel");
    assert (view.draft_for_test ("A") == "draft-a");
    assert (backend.write_count == 0);
    button.clicked ();
    dialog = confirmation (window);
    assert (dialog != null);
    dialog.response ("apply");
    while (view.draft_for_test ("A") != null) yield next_iteration ();
    assert (backend.write_count == 1);
    assert (backend.last_changes.lookup ("A") == "draft-a");
    window.destroy ();
}

private async void slider_scenario () {
    var backend = new TestBackend ();
    var numeric = integer_setting ("level", "10", 100);
    numeric.set_lower_bound (5);
    numeric.set_scalar_increment (5);
    var memory = enum_setting ("com.coreboot-cfr.memory_speed", "6400MT/s",
                              {"5500MT/s", "6400MT/s", "7500MT/s"});
    backend.settings = { numeric, memory, integer_setting ("large", "0"),
        enum_setting ("com.coreboot-cfr.webcam", "Enabled", {"Disabled", "Enabled"}) };
    var view = yield create_view (backend);
    var toggle = view.control_for_test ("com.coreboot-cfr.webcam") as Gtk.Switch;
    assert (toggle != null && toggle.active);
    toggle.active = false;
    assert (view.draft_for_test ("com.coreboot-cfr.webcam") == "Disabled");
    view.discard_for_test ("com.coreboot-cfr.webcam");
    assert (toggle.active);
    var weak_toggle = WeakRef (toggle);
    toggle = null;
    var input = (Gtk.Entry) view.control_for_test ("level");
    var slider = input.get_parent ().get_first_child () as Gtk.Scale;
    assert (slider != null);
    slider.set_value (3);
    assert (input.text == "20");
    assert (view.draft_for_test ("level") == "20");
    input.text = "25";
    assert (slider.get_value () == 4);
    input.text = "24";
    assert (!view.can_apply_for_test ());
    view.discard_for_test ("level");
    assert (input.text == "10");
    assert (slider.get_value () == 1);
    var selector = (Gtk.DropDown) view.control_for_test ("com.coreboot-cfr.memory_speed");
    var memory_slider = selector.get_parent ().get_first_child () as Gtk.Scale;
    assert (memory_slider != null);
    memory_slider.set_value (2);
    assert (view.draft_for_test ("com.coreboot-cfr.memory_speed") == "7500MT/s");
    view.discard_for_test ("com.coreboot-cfr.memory_speed");
    assert (memory_slider.get_value () == 1);
    var large = (Gtk.Entry) view.control_for_test ("large");
    assert (large.get_parent ().get_first_child () == large);
    var weak_slider = WeakRef (slider);
    var weak_memory_slider = WeakRef (memory_slider);
    input = null;
    selector = null;
    large = null;
    slider = memory_slider = null;
    yield view.load ();
    assert (weak_slider.get () == null);
    assert (weak_memory_slider.get () == null);
    assert (weak_toggle.get () == null);
    assert (backend.write_count == 0);
}

private async void access_scenario () {
    var backend = new TestBackend ();
    backend.settings = { string_setting ("A", "old-a") };
    var view = yield create_view (backend);
    view.edit_for_test ("A", "draft-a");
    backend.access = READ_ONLY;
    yield view.load ();
    assert (view.control_for_test ("A") == null);
    assert (view.draft_for_test ("A") == "draft-a");
    assert (!view.can_apply_for_test ());
    var reads = backend.read_count;
    backend.access = DENIED;
    yield view.load ();
    assert (backend.read_count == reads);
    assert (view.draft_for_test ("A") == "draft-a");
    assert (!view.can_apply_for_test ());
    backend.access = READ_WRITE;
    yield view.load ();
    assert (view.control_for_test ("A") != null);
    assert (view.can_apply_for_test ());
}

private async void write_scenario () {
    var backend = new TestBackend ();
    var a = string_setting ("A", "old-a");
    var b = string_setting ("B", "old-b");
    backend.settings = { a, b };
    var view = yield create_view (backend);

    // The editor reaches one batch request without a separate write-
    // authorization operation. Polkit authorization is not simulated here.
    assert (view.describe_changes () == "");
    view.edit_for_test ("A", "first-write");
    assert ("old-a → first-write" in view.describe_changes ());
    assert (!("old-b" in view.describe_changes ()));
    yield view.apply_for_test ();
    assert (backend.write_count == 1);
    assert (backend.last_changes.size () == 1);
    assert (backend.last_changes.lookup ("A") == "first-write");
    assert (view.draft_for_test ("A") == null);
    assert (view.status_for_test () == "");

    view.edit_for_test ("A", "second-write");
    yield view.apply_for_test ();
    assert (backend.write_count == 2);
    assert (view.draft_for_test ("A") == null);

    view.edit_for_test ("A", "rejected-a");
    view.edit_for_test ("B", "rejected-b");
    var reads_before = backend.read_count;
    backend.next_result = AUTH_REJECTED;
    yield view.apply_for_test ();
    assert (view.draft_for_test ("A") == "rejected-a");
    assert (view.draft_for_test ("B") == "rejected-b");
    assert (backend.read_count == reads_before);
    assert (backend.last_changes.size () == 2);
    assert (backend.last_changes.lookup ("A") == "rejected-a");
    assert (backend.last_changes.lookup ("B") == "rejected-b");
    assert ("Authorization" in view.status_for_test ());

    backend.next_result = AUTH_CANCELLED;
    yield view.apply_for_test ();
    assert (view.draft_for_test ("A") == "rejected-a");
    assert (view.draft_for_test ("B") == "rejected-b");
    assert (backend.read_count == reads_before);
    assert ("Authorization" in view.status_for_test ());

    backend.next_result = PARTIAL;
    yield view.apply_for_test ();
    assert (a.get_current_value () == "rejected-a");
    assert (a.get_read_only ());
    assert (view.draft_for_test ("A") == null);
    assert (view.draft_for_test ("B") == "rejected-b");
    assert (view.can_apply_for_test ());
    assert ("Some changes may already have been saved" in view.status_for_test ());

    yield view.apply_for_test ();
    assert (view.draft_for_test ("B") == null);

    a.set_read_only (false);
    yield view.load ();
    view.edit_for_test ("A", "authoritative-refresh");
    a.set_current_value ("authoritative-refresh");
    a.set_read_only (true);
    yield view.load ();
    assert (view.draft_for_test ("A") == null);
    a.set_read_only (false);

    view.edit_for_test ("B", "navigation-b");

    backend.hold_enable = true;
    backend.enable_started = false;
    backend.write_started = false;
    var completed = false;
    view.apply_for_test.begin ((obj, result) => {
        view.apply_for_test.end (result);
        completed = true;
    });
    while (!backend.enable_started) yield next_iteration ();
    view.set_visible_for_test (false);
    backend.hold_enable = false;
    while (!completed) yield next_iteration ();
    assert (!backend.write_started);

    view.set_visible_for_test (true);
    yield view.load ();
    backend.hold_write = true;
    backend.write_started = false;
    completed = false;
    view.apply_for_test.begin ((obj, result) => {
        view.apply_for_test.end (result);
        completed = true;
    });
    while (!backend.write_started) yield next_iteration ();
    var writes_in_progress = backend.write_count;
    yield view.apply_for_test ();
    assert (backend.write_count == writes_in_progress);
    view.set_visible_for_test (false);
    backend.hold_write = false;
    while (!completed) yield next_iteration ();
    assert (b.get_current_value () == "navigation-b");
    assert (view.draft_for_test ("B") == "navigation-b");
    view.set_visible_for_test (true);
    yield view.load ();
    assert (view.draft_for_test ("B") == null);

    view.edit_for_test ("B", "hidden-partial");
    backend.next_result = PARTIAL;
    backend.hold_write = true;
    backend.write_started = false;
    completed = false;
    view.apply_for_test.begin ((obj, result) => {
        view.apply_for_test.end (result);
        completed = true;
    });
    while (!backend.write_started) yield next_iteration ();
    view.set_visible_for_test (false);
    backend.hold_write = false;
    while (!completed) yield next_iteration ();
    view.set_visible_for_test (true);
    yield view.load ();
    assert (view.draft_for_test ("B") == "hidden-partial");
    assert ("Some changes may already have been saved" in view.status_for_test ());
}

private async void draft_scenario () {
    var backend = new TestBackend ();
    var a = string_setting ("A", "old-a");
    var text = string_setting ("text", "old", 16);
    var number = integer_setting ("number", "1", 100);
    var locked = string_setting ("locked", "old-locked");
    string[] choices = { "Auto", "Enabled", "Disabled" };
    var choice = enum_setting ("choice", "Auto", choices);
    backend.settings = { a, text, number, locked, choice };
    var view = yield create_view (backend);

    view.edit_for_test ("A", "new-a");
    view.edit_for_test ("text", "draft");
    view.edit_for_test ("number", "10");
    view.edit_for_test ("locked", "pending-locked");
    view.select_for_test ("choice", "Disabled");
    yield view.load ();
    assert (view.draft_for_test ("A") == "new-a");
    assert (view.draft_for_test ("text") == "draft");
    assert (view.draft_for_test ("number") == "10");
    assert (view.draft_for_test ("locked") == "pending-locked");
    assert (view.draft_for_test ("choice") == "Disabled");

    text.set_upper_bound (3);
    number.set_upper_bound (5);
    string[] changed_choices = { "Auto", "Enabled" };
    var changed_choice = enum_setting ("choice", "Auto", changed_choices);
    locked.set_read_only (true);
    backend.settings = { a, text, number, locked, changed_choice };
    yield view.load ();
    assert (view.displayed_draft_for_test ("text") == "draft");
    assert (view.conflict_for_test ("text"));
    assert (view.displayed_draft_for_test ("number") == "10");
    assert (view.conflict_for_test ("number"));
    assert (view.displayed_draft_for_test ("choice") == "Pending value: Disabled");
    assert (view.conflict_for_test ("choice"));
    assert (view.displayed_draft_for_test ("locked") == "pending-locked");
    assert (view.conflict_for_test ("locked"));
    assert (!view.can_apply_for_test ());

    view.edit_for_test ("text", "new");
    view.edit_for_test ("number", "5");
    view.select_for_test ("choice", "Enabled");
    assert (!view.conflict_for_test ("text"));
    assert (!view.conflict_for_test ("number"));
    assert (!view.conflict_for_test ("choice"));
    assert (view.draft_for_test ("A") == "new-a");
    assert (!view.can_apply_for_test ());

    view.discard_for_test ("locked");
    assert (view.can_apply_for_test ());

    view.select_for_test ("choice", "Auto");
    assert (view.draft_for_test ("choice") == null);
    view.select_for_test ("choice", "Enabled");
    string[] final_choices = { "Auto" };
    changed_choice = enum_setting ("choice", "Auto", final_choices);
    backend.settings = { a, text, number, locked, changed_choice };
    yield view.load ();
    assert (view.conflict_for_test ("choice"));
    view.discard_for_test ("choice");
    assert (view.draft_for_test ("choice") == null);
    assert (view.draft_for_test ("A") == "new-a");

    text.set_read_only (true);
    yield view.load ();
    assert (view.displayed_draft_for_test ("text") == "new");
    assert (view.conflict_for_test ("text"));
    assert (!view.can_apply_for_test ());

    backend.settings = { a, text, locked, changed_choice };
    yield view.load ();
    assert (view.displayed_draft_for_test ("number") == "5");
    assert (view.conflict_for_test ("number"));
    assert (!view.can_apply_for_test ());
}

private async void lifetime_scenario () {
    var backend = new TestBackend ();
    var text = string_setting ("text", "old");
    string[] choices = { "Auto", "Enabled" };
    var choice = enum_setting ("choice", "Auto", choices);
    backend.settings = { text, choice };
    var view = yield create_view (backend);

    for (uint i = 0; i < 4; i++) {
        view.edit_for_test ("text", "draft-%u".printf (i));
        view.select_for_test ("choice", "Enabled");
        view.discard_for_test ("text");
        view.discard_for_test ("choice");

        Object? entry = view.control_for_test ("text");
        Object? dropdown = view.control_for_test ("choice");
        Object? conflict = view.conflict_label_for_test ("text");
        Object? discard = view.discard_button_for_test ("choice");
        var entry_ref = WeakRef (entry);
        var dropdown_ref = WeakRef (dropdown);
        var conflict_ref = WeakRef (conflict);
        var discard_ref = WeakRef (discard);
        entry = dropdown = conflict = discard = null;

        yield view.load ();
        for (uint iteration = 0; iteration < 4; iteration++) {
            yield next_iteration ();
        }
        assert (entry_ref.get () == null);
        assert (dropdown_ref.get () == null);
        assert (conflict_ref.get () == null);
        assert (discard_ref.get () == null);
    }
}

#if HAS_FWUPD_2_0
private uint count_labels (Gtk.Widget widget, string text) {
    uint count = widget is Gtk.Label && ((Gtk.Label) widget).get_text () == text ? 1 : 0;
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        count += count_labels (child, text);
    }
    return count;
}

private Gtk.Stack? find_group_stack (Gtk.Widget widget) {
    if (widget is Gtk.Stack && ((Gtk.Stack) widget).get_child_by_name ("Audio") != null) {
        return (Gtk.Stack) widget;
    }
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = find_group_stack (child);
        if (found != null) return found;
    }
    return null;
}

private async void metadata_scenario () {
    var first = string_setting ("A", "old-a");
    var second = string_setting ("B", "old-b");
    var metadata = new VariantBuilder (VariantType.VARDICT);
    metadata.add ("{sv}", "DisplayGroup", new Variant.string ("Audio"));
    metadata.add ("{sv}", "HelpText", new Variant.string ("Controls the speaker amplifier."));
    var values = metadata.end ();
    try {
        assert (((Fwupd.Codec) first).from_variant (values));
        assert (((Fwupd.Codec) second).from_variant (values));
    } catch (Error e) {
        error ("Cannot load firmware metadata: %s", e.message);
    }

    var retained = ((Fwupd.Codec) first).to_variant (Fwupd.CodecFlags.NONE);
    if (retained.lookup_value ("DisplayGroup", null) == null) {
        Test.skip ("fwupd does not expose BIOS setting metadata");
        return;
    }

    var backend = new TestBackend ();
    backend.settings = { first, second };
    var view = yield create_view (backend);
    assert (find_group_stack (view) != null);
    assert (find_group_stack (view).visible_child_name == "Audio");
    assert (count_labels (view, "Controls the speaker amplifier.") == 2);
    var third = string_setting ("C", "old-c");
    var other = new VariantBuilder (VariantType.VARDICT);
    other.add ("{sv}", "DisplayGroup", new Variant.string ("Battery"));
    try {
        assert (((Fwupd.Codec) third).from_variant (other.end ()));
    } catch (Error e) {
        error ("Cannot load firmware metadata: %s", e.message);
    }
    backend.settings = {first, second, third};
    yield view.load ();
    var groups = find_group_stack (view);
    assert (groups != null);
    assert (!groups.get_page (groups.get_child_by_name ("")).visible);
    view.edit_for_test ("A", "draft-a");
    groups.visible_child_name = "Battery";
    view.edit_for_test ("C", "draft-c");
    yield view.load ();
    assert (groups.visible_child_name == "Battery");
    assert (view.can_apply_for_test ());
    backend.hold_write = true;
    var completed = false;
    view.apply_for_test.begin ((obj, result) => {
        view.apply_for_test.end (result);
        completed = true;
    });
    while (!backend.write_started) yield next_iteration ();
    assert (!groups.is_sensitive ());
    assert (backend.last_changes.size () == 2);
    assert (backend.last_changes.lookup ("A") == "draft-a");
    assert (backend.last_changes.lookup ("C") == "draft-c");
    backend.hold_write = false;
    while (!completed) yield next_iteration ();
    assert (view.draft_for_test ("A") == null);
    assert (view.draft_for_test ("C") == null);
}
#endif

public int main (string[] args) {
    Adw.init ();
    Test.init (ref args);
    Test.add_func ("/firmware-settings/confirmation", () => {
        var loop = new MainLoop ();
        confirmation_scenario.begin ((obj, result) => {
            confirmation_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
    Test.add_func ("/firmware-settings/sliders", () => {
        var loop = new MainLoop ();
        slider_scenario.begin ((obj, result) => {
            slider_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
    Test.add_func ("/firmware-settings/access", () => {
        var loop = new MainLoop ();
        access_scenario.begin ((obj, result) => {
            access_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
    Test.add_func ("/firmware-settings/write-lifecycle", () => {
        var loop = new MainLoop ();
        write_scenario.begin ((obj, result) => {
            write_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
    Test.add_func ("/firmware-settings/draft-conflicts", () => {
        var loop = new MainLoop ();
        draft_scenario.begin ((obj, result) => {
            draft_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
    Test.add_func ("/firmware-settings/row-lifetimes", () => {
        var loop = new MainLoop ();
        lifetime_scenario.begin ((obj, result) => {
            lifetime_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
#if HAS_FWUPD_2_0
    Test.add_func ("/firmware-settings/metadata", () => {
        var loop = new MainLoop ();
        metadata_scenario.begin ((obj, result) => {
            metadata_scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
#endif
    return Test.run ();
}
