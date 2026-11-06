/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

public class About.SecurityView : Switchboard.SettingsPage {
    private Fwupd.Client client = new Fwupd.Client ();
    private Gtk.Label summary_label;
    private Gtk.Label hsi_label;
    private Gtk.Box checks_box;
    private Gtk.Image summary_icon;
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

        checks_box = new Gtk.Box (VERTICAL, 12);
        summary_icon = new Gtk.Image.from_icon_name ("security-high-symbolic") { pixel_size = 32 };
        var overview = new Gtk.Box (HORIZONTAL, 12);
        overview.append (summary_icon);
        overview.append (summary_label);
        var help = new Gtk.Expander (_("About Security Checks"));
        var help_box = new Gtk.Box (VERTICAL, 6);
        help_box.append (new Gtk.Label (_("fwupd reports hardware and firmware protections, not overall system or application security. HSI levels are cumulative requirements, not a percentage of checks passed. A ! suffix reports a runtime security issue. Missing data does not establish that a device is secure or insecure.")) {
            wrap = true, xalign = 0
        });
        help_box.append (new Gtk.LinkButton.with_label (
            "https://fwupd.github.io/libfwupdplugin/hsi.html", _("Host Security ID Specification")
        ) { halign = START });
        help.child = help_box;

        var content = new Gtk.Box (VERTICAL, 12);
        content.append (overview);
        content.append (hsi_label);
        content.append (help);
        content.append (checks_box);
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
        summary_icon.icon_name = "content-loading-symbolic";
        while (checks_box.get_first_child () != null) {
            checks_box.remove (checks_box.get_first_child ());
        }

        // Register fwupd's remote errors before the first D-Bus failure.
        error_quark ();
        try {
            yield client.connect_async (null);
            var checks = yield client.get_host_security_attrs_async (null);
            show_checks (checks, client.get_host_security_id (), client.get_host_vendor (), client.get_host_product ());
        } catch (Fwupd.Error.NOT_SUPPORTED e) {
            summary_label.label = _("Security checks are not supported on this device.");
            summary_icon.icon_name = "dialog-question-symbolic";
        } catch (Error e) {
            summary_label.label = _("Unable to check security: %s").printf (e.message);
            summary_icon.icon_name = "dialog-error-symbolic";
        }

        refresh_button.sensitive = true;
        busy = false;
    }

    internal void show_checks (GenericArray<weak Fwupd.SecurityAttr> checks, string? hsi, string? vendor, string? product) {
        while (checks_box.get_first_child () != null) {
            checks_box.remove (checks_box.get_first_child ());
        }
        hsi_label.visible = false;
        var attention_list = new Gtk.ListBox () { selection_mode = NONE };
        var unavailable_list = new Gtk.ListBox () { selection_mode = NONE };
        var passed_list = new Gtk.ListBox () { selection_mode = NONE };
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
                    .replace ("$HostVendor$", vendor ?? _("Unknown Manufacturer"))
                    .replace ("$HostProduct$", product ?? _("Unknown Device"));
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

            var reported_result = Fwupd.SecurityAttr.result_to_string (check.get_result ()) ?? _("Unknown");
            details.append (new Gtk.Label (_("Reported result: %s").printf (reported_result)) {
                xalign = 0, wrap = true, selectable = true
            });
            var level = (uint) check.get_level ();
            details.append (new Gtk.Label (level == 0
                ? _("Runtime or additional check; does not raise the HSI level.")
                : _("Required for HSI level %u").printf (level)) { xalign = 0, wrap = true });
            var url = check.get_url ();
            if (url != null && (url.has_prefix ("https://") || url.has_prefix ("http://"))) {
                details.append (new Gtk.LinkButton.with_label (url, _("Learn More")) { halign = START });
            }
            row.add_row (details);
            if (missing) {
                unavailable_list.append (row);
            } else if (success) {
                passed_list.append (row);
            } else {
                attention_list.append (row);
            }
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

        add_check_group (_("Needs Attention"), failed, attention_list, true);
        add_check_group (_("Unavailable"), unavailable, unavailable_list, true);
        add_check_group (_("Passed"), passed, passed_list, false);
        summary_icon.icon_name = failed > 0 ? "dialog-warning-symbolic"
            : unavailable > 0 || passed == 0 ? "dialog-question-symbolic" : "security-high-symbolic";

        if (hsi != null && hsi != "" && passed + failed + unavailable > 0) {
            hsi_label.label = _("Host Security ID: %s").printf (hsi) + "\n" + hsi_description (hsi);
            hsi_label.visible = true;
        }
    }

    private void add_check_group (string title, uint count, Gtk.ListBox list, bool expanded) {
        if (count == 0) {
            return;
        }
        list.add_css_class ("boxed-list");
        var group = new Gtk.Expander (_("%s (%u)").printf (title, count)) {
            expanded = expanded,
            child = list
        };
        checks_box.append (group);
    }

    [CCode (cname = "fwupd_error_quark", cheader_filename = "fwupd.h")]
    private static extern Quark error_quark ();

    internal static string hsi_description (string hsi) {
        // Interpret only known IDs. Preserve the complete daemon value above.
        string description = _("The security level could not be determined.");
        // fwupd emits a level, optional runtime !, and optional version tuple.
        if (!Regex.match_simple ("\\AHSI:[0-5]!?(?: \\(v[0-9]+\\.[0-9]+\\.[0-9]+\\))?\\z", hsi)) {
            return description;
        }
        switch (hsi[4]) {
            case '0':
                description = _("Basic security requirements are not met.");
                break;
            case '1':
                description = _("Basic security requirements are met.");
                break;
            case '2':
                description = _("HSI level 2 requirements are met.");
                break;
            case '3':
                description = _("HSI level 3 requirements are met.");
                break;
            case '4':
                description = _("HSI level 4 requirements are met.");
                break;
            case '5':
                description = _("HSI level 5 requirements are met.");
                break;
        }
        if (hsi.length > 5 && hsi[5] == '!') {
            description += " " + _("A runtime security issue was reported. Review the checks below.");
        }
        return description;
    }
}
