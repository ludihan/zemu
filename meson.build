project(
  'zemu',
  'c',
  meson_version : '>= 1.3.0',
  version : '0.1',
  default_options : ['warning_level=3'],
)

dependencies = [
  dependency('sdl3')
]

sources = [
  'src/zemu.c',
]

exe = executable(
  'zemu',
  sources,
  dependencies : dependencies,
  install : true,
)

test('basic', exe)
