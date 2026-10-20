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

    internal override async bool authorize_read (Cancellable cancellable) throws Error {
        return true;
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

private async void write_scenario () {
    var backend = new TestBackend ();
    var a = string_setting ("A", "old-a");
    var b = string_setting ("B", "old-b");
    backend.settings = { a, b };
    var view = yield create_view (backend);

    // The editor reaches one batch request without a separate write-
    // authorization operation. Polkit authorization is not simulated here.
    view.edit_for_test ("A", "first-write");
    yield view.apply_for_test ();
    assert (backend.write_count == 1);
    assert (backend.last_changes.size () == 1);
    assert (backend.last_changes.lookup ("A") == "first-write");
    assert (view.draft_for_test ("A") == null);

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
    view.set_visible_for_test (false);
    backend.hold_write = false;
    while (!completed) yield next_iteration ();
    assert (b.get_current_value () == "navigation-b");
    assert (view.draft_for_test ("B") == "navigation-b");
    view.set_visible_for_test (true);
    yield view.load ();
    assert (view.draft_for_test ("B") == null);
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

public int main (string[] args) {
    Gtk.init ();
    Test.init (ref args);
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
    return Test.run ();
}
