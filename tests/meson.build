firmware_settings_test = executable(
    'firmware-settings-test',
    'firmware-settings-test.vala',
    meson.project_source_root() / 'src' / 'Interfaces' / 'FirmwareSettingsBackend.vala',
    meson.project_source_root() / 'src' / 'Views' / 'FirmwareSettingsView.vala',
    dependencies: [
        fwupd_dep,
        glib_dep,
        dependency('gio-2.0'),
        dependency('gtk4'),
        dependency('libadwaita-1'),
        dependency('granite-7')
    ],
    install: false
)

test('firmware settings drafts', find_program('xvfb-run'),
    args: ['-a', firmware_settings_test],
    env: ['GSETTINGS_BACKEND=memory'],
    protocol: 'tap',
    suite: 'firmware-settings')
