# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(vad_plus_library VERSION 0.0.1 LANGUAGES C)

add_library(vad_plus SHARED
  "vad_plus.c"
)

set_target_properties(vad_plus PROPERTIES
  PUBLIC_HEADER vad_plus.h
  OUTPUT_NAME "vad_plus"
)

target_compile_definitions(vad_plus PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(vad_plus PRIVATE "-Wl,-z,max-page-size=16384")
endif()
