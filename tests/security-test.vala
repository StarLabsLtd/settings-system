/* SPDX-License-Identifier: GPL-3.0-or-later */

private Gtk.Expander? find_group (Gtk.Widget widget, string label) {
    if (widget is Gtk.Expander && ((Gtk.Expander) widget).label == label) {
        return (Gtk.Expander) widget;
    }
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        var found = find_group (child, label);
        if (found != null) return found;
    }
    return null;
}

private bool has_text (Gtk.Widget widget, string text) {
    if (widget is Gtk.Label && ((Gtk.Label) widget).get_text () == text) return true;
    for (var child = widget.get_first_child (); child != null; child = child.get_next_sibling ()) {
        if (has_text (child, text)) return true;
    }
    return false;
}

private Fwupd.SecurityAttr check (string name, Fwupd.SecurityAttrResult result) {
    var attr = new Fwupd.SecurityAttr ("org.fwupd.hsi.Test." + name);
    attr.set_name (name);
    attr.set_result (result);
    return attr;
}

private void grouping () {
    var checks = new GenericArray<Fwupd.SecurityAttr> ();
    var pass = check ("NotApplicable", NOT_SUPPORTED);
    var missing = check ("Missing", ENABLED);
    var obsolete = check ("Obsolete", NOT_ENABLED);
#if HAS_FWUPD_2_0
    pass.add_flag (Fwupd.SecurityAttrFlags.SUCCESS);
    missing.add_flag (Fwupd.SecurityAttrFlags.MISSING_DATA);
    obsolete.add_flag (Fwupd.SecurityAttrFlags.OBSOLETED);
#else
    pass.add_flag (Fwupd.SECURITY_ATTR_FLAG_SUCCESS);
    missing.add_flag (Fwupd.SECURITY_ATTR_FLAG_MISSING_DATA);
    obsolete.add_flag (Fwupd.SECURITY_ATTR_FLAG_OBSOLETED);
#endif
    pass.set_description ("$HostVendor$ $HostProduct$ test.");
    checks.add (pass);
    checks.add (missing);
    checks.add (obsolete);
    checks.add (check ("Unknown", UNKNOWN));
    checks.add (check ("Disabled", NOT_ENABLED));
    var view = new About.SecurityView ();
    view.show_checks ((GenericArray<weak Fwupd.SecurityAttr>) checks, "HSI:1!", "Vendor & Co", "<Device>");
    assert (find_group (view, "Passed (1)") != null);
    assert (!find_group (view, "Passed (1)").expanded);
    assert (find_group (view, "Unavailable (2)").expanded);
    assert (find_group (view, "Needs Attention (1)").expanded);
    find_group (view, "Passed (1)").expanded = true;
    assert (has_text (view, "Vendor & Co <Device> test."));
    assert (!has_text (view, "Obsolete"));
    assert (has_text (view, "Some security checks need attention."));
    view.show_checks (new GenericArray<weak Fwupd.SecurityAttr> (), null, null, null);
    assert (find_group (view, "Passed (1)") == null);
    assert (has_text (view, "Security checks are not available on this device."));
}

public int main (string[] args) {
    Gtk.init ();
    Test.init (ref args);
    Test.add_func ("/security/grouping-and-missing-data", grouping);
    Test.add_func ("/security/hsi", () => {
        assert ("not met" in About.SecurityView.hsi_description ("HSI:0"));
        assert ("Basic" in About.SecurityView.hsi_description ("HSI:1"));
        for (uint i = 2; i <= 5; i++) {
            assert ("level %u".printf (i) in About.SecurityView.hsi_description ("HSI:%u (v2.1.8)".printf (i)));
        }
        for (uint i = 0; i <= 5; i++) {
            var id = "HSI:%u".printf (i);
            var bare = About.SecurityView.hsi_description (id);
            foreach (var suffix in new string[] {"", "!", " (v1.8.4)", "! (v2.1.8)", " (v2.2.1)", "! (v0.0.0)"}) {
                var description = About.SecurityView.hsi_description (id + suffix);
                assert (description.has_prefix (bare));
                assert (!("could not be determined" in description));
                assert (("runtime" in description) == suffix.has_prefix ("!"));
            }
        }
    });
    Test.add_func ("/security/hsi-malformed-forms", () => {
        var unknown = About.SecurityView.hsi_description ("HSI:INVALID");
        foreach (var id in new string[] {
            "", "HSI:99", "HSI:10", "HSI:6!", "HSI:2garbage", "HSI:2 garbage",
            "HSI:2!garbage", "HSI:2!!", "HSI:2 !", "HSI:2U", "HSI:2A", "HSI:02",
            "HSI:2 ", " HSI:2", "HSI:2\n", "HSI:2!\n", "HSI:2 (v2.1.8)\n",
            "HSI:2 (v2.1)", "HSI:2 (v2.1.8", "HSI:2 (v2.1.8)garbage",
            "HSI:2! (v2.1.8)garbage", "HSI:2 (v2.1.8)!", "HSI:2(v2.1.8)",
            "HSI:2  (v2.1.8)", "HSI:2 (v2..8)", "HSI:2 (v-2.1.8)", "HSI:2 (v2.1.x)",
            "HSI:2 (v2.1.8.1)", "HSI:INVALID!", "garbage!"
        }) {
            assert (About.SecurityView.hsi_description (id) == unknown);
        }
        // The complete untrusted value remains visible even when not interpreted.
        var checks = new GenericArray<Fwupd.SecurityAttr> ();
        checks.add (check ("Unknown", UNKNOWN));
        var view = new About.SecurityView ();
        var malformed = "HSI:2!garbage";
        view.show_checks ((GenericArray<weak Fwupd.SecurityAttr>) checks, malformed, null, null);
        assert (has_text (view, "Host Security ID: " + malformed + "\n" + unknown));
    });
    return Test.run ();
}
