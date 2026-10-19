/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class About.SecurityView : Switchboard.SettingsPage {
    private Fwupd.Client client = new Fwupd.Client ();
    private Gtk.Label summary_label;
    private Gtk.Label hsi_label;
    private Gtk.ListBox checks_list;
    private Gtk.Button refresh_button;
    private bool busy;

    public SecurityView () {
        Object (
            header: _("Information"),
            icon: new ThemedIcon ("security-high"),
            title: _("Security"),
            description: _("Review the security of your hardware, firmware, and operating system.")
        );
    }

    construct {
        summary_label = new Gtk.Label (_("Checking security…")) {
            wrap = true,
            xalign = 0
        };
        summary_label.add_css_class (Granite.STYLE_CLASS_H3_LABEL);

        hsi_label = new Gtk.Label (null) {
            selectable = true,
            wrap = true,
            xalign = 0,
            visible = false
        };
        hsi_label.add_css_class (Granite.CssClass.DIM);

        checks_list = new Gtk.ListBox () {
            selection_mode = NONE
        };
        checks_list.add_css_class ("boxed-list");

        var content = new Gtk.Box (VERTICAL, 12);
        content.append (summary_label);
        content.append (hsi_label);
        content.append (checks_list);
        child = content;

        refresh_button = add_button (_("Refresh"));
        refresh_button.clicked.connect (() => load.begin ());
        map.connect (() => load.begin ());
    }

    private async void load () {
        if (busy) {
            return;
        }

        busy = true;
        refresh_button.sensitive = false;
        summary_label.label = _("Checking security…");
        hsi_label.visible = false;
        while (checks_list.get_first_child () != null) {
            checks_list.remove (checks_list.get_first_child ());
        }

        try {
            yield client.connect_async (null);
            var checks = yield client.get_host_security_attrs_async (null);
            uint passed = 0;
            uint failed = 0;
            uint unavailable = 0;
            foreach (var check in checks) {
#if HAS_FWUPD_2_0
                if (check.has_flag (Fwupd.SecurityAttrFlags.OBSOLETED)) {
#else
                if (check.has_flag (Fwupd.SECURITY_ATTR_FLAG_OBSOLETED)) {
#endif
                    continue;
                }

                string result;
                string icon_name;
#if HAS_FWUPD_2_0
                bool missing = check.has_flag (Fwupd.SecurityAttrFlags.MISSING_DATA) ||
                    check.get_result () == Fwupd.SecurityAttrResult.UNKNOWN;
                bool success = check.has_flag (Fwupd.SecurityAttrFlags.SUCCESS);
#else
                bool missing = check.has_flag (Fwupd.SECURITY_ATTR_FLAG_MISSING_DATA) ||
                    check.get_result () == Fwupd.SecurityAttrResult.UNKNOWN;
                bool success = check.has_flag (Fwupd.SECURITY_ATTR_FLAG_SUCCESS);
#endif
                if (missing) {
                    result = _("Unavailable");
                    icon_name = "dialog-question-symbolic";
                    unavailable++;
                } else if (success) {
                    result = _("Passed");
                    icon_name = "object-select-symbolic";
                    passed++;
                } else {
                    result = _("Needs Attention");
                    icon_name = "dialog-warning-symbolic";
                    failed++;
                }

                var name = check.get_title () ?? check.get_name () ??
                    check.get_appstream_id () ?? _("Security Check");
                var row = new Adw.ExpanderRow () {
                    title = dgettext ("fwupd", name),
                    subtitle = result,
                    use_markup = false
                };
                row.add_prefix (new Gtk.Image.from_icon_name (icon_name));

                var details = new Gtk.Box (VERTICAL, 6) {
                    margin_top = 12,
                    margin_bottom = 12,
                    margin_start = 12,
                    margin_end = 12
                };
                var description = check.get_description ();
                if (description != null && description != "") {
                    description = dgettext ("fwupd", description)
                        .replace ("$HostVendor$", client.get_host_vendor () ?? _("Unknown Manufacturer"))
                        .replace ("$HostProduct$", client.get_host_product () ?? _("Unknown Device"));
                    details.append (new Gtk.Label (description) {
                        wrap = true,
                        xalign = 0,
                        selectable = true
                    });
                } else {
                    details.append (new Gtk.Label (missing
                        ? _("The result of this check could not be determined.")
                        : success ? _("This check passed.")
                        : _("Review your firmware and operating system configuration.")) {
                        wrap = true,
                        xalign = 0
                    });
                }

                var url = check.get_url ();
                if (url != null && (url.has_prefix ("https://") || url.has_prefix ("http://"))) {
                    details.append (new Gtk.LinkButton.with_label (url, _("Learn More")) { halign = START });
                }
                row.add_row (details);
                checks_list.append (row);
            }

            if (passed + failed + unavailable == 0) {
                summary_label.label = _("Security checks are not available on this device.");
            } else if (failed > 0) {
                summary_label.label = _("Some security checks need attention.");
            } else if (unavailable > 0) {
                summary_label.label = _("Some security checks could not be completed.");
            } else {
                summary_label.label = _("All reported security checks passed.");
            }

            var hsi = client.get_host_security_id ();
            if (hsi != null && hsi != "" && passed + failed + unavailable > 0) {
                hsi_label.label = _("Host Security ID: %s").printf (hsi);
                hsi_label.visible = true;
            }
        } catch (Error e) {
            summary_label.label = _("Unable to check security: %s").printf (e.message);
        }

        refresh_button.sensitive = true;
        busy = false;
    }
}
