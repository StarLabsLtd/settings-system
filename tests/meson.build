firmware_settings_test = executable(
    'firmware-settings-test',
    'firmware-settings-test.vala',
    meson.project_source_root() / 'src' / 'Interfaces' / 'FirmwareSettingsBackend.vala',
    meson.project_source_root() / 'src' / 'Views' / 'FirmwareSettingsView.vala',
    vala_args: ['--define=FIRMWARE_SETTINGS_TEST'],
    dependencies: [
        fwupd_dep,
        glib_dep,
        dependency('gio-2.0'),
        dependency('gtk4'),
        dependency('libadwaita-1', version: '>=1.5'),
        dependency('granite-7'),
        dependency('polkit-gobject-1')
    ],
    install: false
)

test(
    'firmware settings batch editor',
    find_program('run-firmware-settings.sh'),
    args: firmware_settings_test,
    env: ['GSETTINGS_BACKEND=memory', 'GTK_A11Y=test'],
    protocol: 'tap',
    suite: 'firmware-settings'
)

security_test = executable(
    'security-test',
    'security-test.vala',
    meson.project_source_root() / 'src' / 'Views' / 'SecurityView.vala',
    dependencies: [fwupd_dep, glib_dep, switchboard_dep, dependency('gtk4'),
                   dependency('libadwaita-1', version: '>=1.5'), dependency('granite-7')],
    install: false
)

test(
    'security presentation',
    find_program('run-firmware-settings.sh'),
    args: security_test,
    env: ['GSETTINGS_BACKEND=memory', 'GTK_A11Y=none'],
    protocol: 'tap',
    suite: 'firmware-settings'
)
