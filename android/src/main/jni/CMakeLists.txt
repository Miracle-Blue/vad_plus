# CMakeLists.txt for Android VAD Plus native library
cmake_minimum_required(VERSION 3.10)

project(vad_plus_library VERSION 0.0.1 LANGUAGES CXX)

# Set C++ standard
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Add the shared library
add_library(vad_plus SHARED
    vad_plus_jni.cpp
)

# Find required Android libraries
find_library(log-lib log)
find_library(android-lib android)

# Link libraries
target_link_libraries(vad_plus
    ${log-lib}
    ${android-lib}
)

# Set properties
set_target_properties(vad_plus PROPERTIES
    OUTPUT_NAME "vad_plus"
)

# Export symbols
target_compile_definitions(vad_plus PUBLIC DART_SHARED_LIB)

# Compiler flags
target_compile_options(vad_plus PRIVATE
    -Wall
    -Wextra
    -fvisibility=hidden
)

# Support Android 15 16k page size
target_link_options(vad_plus PRIVATE "-Wl,-z,max-page-size=16384")
