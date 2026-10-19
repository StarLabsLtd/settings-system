/* SPDX-License-Identifier: GPL-3.0-or-later */

private enum WriteResult {
    SUCCESS,
    REJECT,
    CANCEL
}

private class TestBackend : About.FirmwareSettingsBackend {
    internal Fwupd.BiosSetting[] settings = {};
    internal WriteResult next_result = SUCCESS;

    internal override async Fwupd.BiosSetting[] read () throws Error {
        return settings;
    }

    internal override async void write (string id, string value) throws Error {
        var result = next_result;
        next_result = SUCCESS;
        if (result == REJECT) throw new IOError.FAILED ("rejected by firmware");
        if (result == CANCEL) throw new IOError.CANCELLED ("authentication cancelled");
        foreach (var setting in settings) {
            if (setting.get_id () == id) setting.set_current_value (value);
        }
    }
}

private Fwupd.BiosSetting setting (string id, string value, uint64 upper = 16, bool read_only = false) {
    var result = new Fwupd.BiosSetting (id, "/test/" + id);
    result.set_id (id);
    result.set_name (id);
    result.set_kind (Fwupd.BiosSettingKind.STRING);
    result.set_current_value (value);
    result.set_lower_bound (1);
    result.set_upper_bound (upper);
    result.set_read_only (read_only);
    return result;
}

private async void scenario () {
    var backend = new TestBackend ();
    var a = setting ("A", "old-a");
    var b = setting ("B", "old-b");
    backend.settings = { a, b };
    var view = new About.FirmwareSettingsView.with_backend (backend);
    yield view.load ();

    view.edit_for_test ("A", "new-a");
    view.edit_for_test ("B", "new-b");
    yield view.apply_for_test ("A");
    assert (a.get_current_value () == "new-a");
    assert (view.draft_for_test ("A") == null);
    assert (view.draft_for_test ("B") == "new-b");
    assert (view.value_for_test ("B") == "new-b");

    backend.next_result = REJECT;
    yield view.apply_for_test ("B");
    assert (view.draft_for_test ("B") == "new-b");
    backend.next_result = CANCEL;
    yield view.apply_for_test ("B");
    assert (view.draft_for_test ("B") == "new-b");

    b.set_upper_bound (3);
    yield view.load ();
    assert (view.draft_for_test ("B") == "new-b");
    assert (!view.can_apply_for_test ("B"));
    assert (view.has_conflict_for_test ("B"));

    b.set_upper_bound (16);
    b.set_read_only (true);
    yield view.load ();
    assert (view.draft_for_test ("B") == "new-b");
    assert (!view.can_apply_for_test ("B"));
    assert (view.has_conflict_for_test ("B"));

    backend.settings = { a };
    yield view.load ();
    assert (view.draft_for_test ("B") == "new-b");
    assert (!view.can_apply_for_test ("B"));
    assert (view.has_conflict_for_test ("B"));

    b.set_read_only (false);
    backend.settings = { a, b };
    yield view.load ();
    yield view.apply_for_test ("B");
    assert (b.get_current_value () == "new-b");
    assert (view.draft_for_test ("B") == null);
    assert (view.value_for_test ("A") == "new-a");
}

public int main (string[] args) {
    Gtk.init ();
    Test.init (ref args);
    Test.add_func ("/firmware-settings/drafts-survive-refresh", () => {
        var loop = new MainLoop ();
        scenario.begin ((obj, result) => {
            scenario.end (result);
            loop.quit ();
        });
        loop.run ();
    });
    return Test.run ();
}
