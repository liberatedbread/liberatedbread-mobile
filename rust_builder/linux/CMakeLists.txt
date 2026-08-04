# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration. PROJECT_NAME must match the plugin name in
# ../pubspec.yaml: Flutter's generated_plugins.cmake reads
# ${plugin_name}_bundled_libraries, so a mismatch silently drops the cdylib
# from the bundle.
set(PROJECT_NAME "liberated_bread_core")
project(${PROJECT_NAME} LANGUAGES CXX)

include("../cargokit/cmake/cargokit.cmake")
apply_cargokit(${PROJECT_NAME} ../../rust liberated_bread_core "")

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(liberated_bread_core_bundled_libraries
  "${${PROJECT_NAME}_cargokit_lib}"
  PARENT_SCOPE
)
