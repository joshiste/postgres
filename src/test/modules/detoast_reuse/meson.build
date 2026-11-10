# Copyright (c) 2026, PostgreSQL Global Development Group

if not get_option('injection_points')
  subdir_done()
endif

detoast_reuse_sources = files(
  'detoast_reuse.c',
)

if host_system == 'windows'
  detoast_reuse_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'detoast_reuse',
    '--FILEDESC', 'detoast_reuse - test code for detoasting a column once per row',])
endif

detoast_reuse = shared_module('detoast_reuse',
  detoast_reuse_sources,
  kwargs: pg_test_mod_args,
)
test_install_libs += detoast_reuse

test_install_data += files(
  'detoast_reuse.control',
  'detoast_reuse--1.0.sql',
)

tests += {
  'name': 'detoast_reuse',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'regress': {
    'sql': [
      'detoast_reuse',
      'detoast_reuse_icu',
    ],
    # The injection points are cluster-wide, so disable installcheck
    'runningcheck': false,
  },
}
