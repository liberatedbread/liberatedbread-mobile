# Project-level configuration.
cmake_minimum_required(VERSION 3.10)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "liberated_bread_mobile")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
#
# Deliberately NOT `flutter create`'s <org>.<project> default
# (ca.pigscanfly.liberated_bread_mobile). The real identifier for this app is
# the flat ca.pigscanfly.liberatedbread — the same value as the Android
# applicationId (android/app/build.gradle, asserted by scripts/verify_apk.sh)
# and the Xcode bundle id. Regenerating this scaffold will reset it to the
# convention default; restore it, the same way the README says to for
# android/ and ios/.
set(APPLICATION_ID "ca.pigscanfly.liberatedbread")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# The targets in this build that are OURS — the only ones we can actually fix a
# warning in. Every other caller of apply_standard_settings() below is plugin
# code that Flutter's generated scaffolding pulled in (see the comment on that
# function), so this list is what separates "our code, warnings are errors"
# from "someone else's code, warnings are warnings".
#
# Keep in sync with the add_executable() call below. Adding a first-party
# target and forgetting to list it here is safe in the only direction that
# matters: it loses -Werror, it does not gain a broken build.
set(FIRST_PARTY_TARGETS "${BINARY_NAME}")

# Warning suppressions for third-party plugin sources — see the
# apply_standard_settings() comment below for why third-party code ends up
# compiled with our flags at all.
#
# Every flag here is probed with check_cxx_compiler_flag() before use, because
# the compiler is not something this file gets to pin. `flutter build linux`
# hardcodes CC=clang / CXX=clang++ (flutter_tools/lib/src/linux/build_linux.dart),
# so in practice this builds under whichever clang the developer's distro
# ships — anywhere from 11 to 21 across the machines this project is built on.
# GCC still turns up whenever cmake is driven directly (IDE integrations, tool
# scripts, `cmake -S linux`), and GCC is the one that accepts a bad -Wno-*
# quietly. An unguarded -Wno-* is NOT harmless on a compiler that does not
# know it:
#
#   * Clang emits "unknown warning option" under -Wunknown-warning-option,
#     which -Werror then turns into an error — the exact failure we are fixing.
#   * GCC accepts an unknown -Wno-* silently, and then, if any OTHER diagnostic
#     fires in that translation unit, retroactively errors on the unrecognized
#     option. A latent breakage that shows up only once unrelated code warns.
#
# The probe deliberately tests the POSITIVE spelling (-Wdeprecated-literal-
# operator) and adds the negative one. Probing "-Wno-foo" directly is the
# classic false positive: GCC accepts unknown negative options quietly, so the
# check would pass on GCC 11 and we would append a flag GCC does not know —
# precisely the second bullet above. The positive spelling is rejected loudly
# by every compiler that does not implement it, which is what makes the probe
# meaningful. (Verified on this project: probing "-Wno-deprecated-literal-
# operator" returns true on GCC 11; probing the positive form returns false.)
include(CheckCXXCompilerFlag)

set(THIRD_PARTY_WARNING_SUPPRESSIONS "")

# -Wdeprecated-literal-operator: the nlohmann/json.hpp vendored into
# flutter_secure_storage_linux declares `operator "" _json(...)` — the C++11
# spelling with whitespace before the identifier, deprecated by CWG2521.
# Measured against real toolchains (see the PR that added this):
#
#   clang 11    does not know the flag at all
#   clang 17-19 know the flag; diagnostic is OFF unless -Wdeprecated is passed
#   clang 20-21 diagnostic is ON BY DEFAULT — this is where -Werror breaks
#   gcc 11      no such diagnostic, and does not know the flag
#
# So the build breaks on clang >= 20 and is completely invisible to anyone
# still on an older clang, which is why this reproduced on one machine and not
# another rather than on everyone's at once. The header lives
# under linux/flutter/ephemeral/.plugin_symlinks/ — a symlink into ~/.pub-cache
# that `flutter pub get` recreates — so it is not ours to patch, and any edit to
# it would be undone by the next clean checkout.
foreach(positive_flag "-Wdeprecated-literal-operator")
  string(MAKE_C_IDENTIFIER "CXX_HAS${positive_flag}" probe_result_var)
  check_cxx_compiler_flag("${positive_flag}" ${probe_result_var})
  if(${probe_result_var})
    string(REPLACE "-W" "-Wno-" negative_flag "${positive_flag}")
    list(APPEND THIRD_PARTY_WARNING_SUPPRESSIONS "${negative_flag}")
  endif()
endforeach()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
#
# "plugins use this function by default" is not a style note, it is the whole
# problem: Flutter's generated linux/flutter/generated_plugins.cmake
# add_subdirectory()s each plugin, and the plugin's own CMakeLists.txt calls
# apply_standard_settings() on its target. So -Werror, written here for OUR
# runner, lands on third-party and vendored sources we cannot edit and do not
# control the compiler warnings of. That is a build break waiting on someone
# else's release cadence: every new compiler version that adds a diagnostic
# firing anywhere in a plugin's dependency tree fails our build, for a warning
# in code we have no way to fix.
#
# So -Werror is scoped to FIRST_PARTY_TARGETS. Third-party targets keep -Wall,
# so their warnings are still printed and still visible in build logs, they
# just do not fail the build. They additionally get the probed suppressions
# above, which keep known-noisy vendored headers from burying real warnings in
# the log — noise reduction, not the load-bearing part of the fix.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall)
  # Keep warnings-as-errors for our own targets, but do not force it onto
  # generated third-party plugin targets. Newer Clang versions warn about the
  # vendored nlohmann json.hpp in flutter_secure_storage_linux; treating that
  # plugin warning as an error breaks Linux builds on some machines. The
  # third-party branch suppresses only the specific warnings probed above.
  if("${TARGET}" IN_LIST FIRST_PARTY_TARGETS)
    target_compile_options(${TARGET} PRIVATE -Werror)
  else()
    target_compile_options(${TARGET} PRIVATE ${THIRD_PARTY_WARNING_SUPPRESSIONS})
  endif()
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Define the application target. To change its name, change BINARY_NAME above,
# not the value here, or `flutter run` will no longer work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# App icon. GTK has no asset catalogue, so unlike every other platform in this
# repo the Linux icon is not picked up by a manifest — it is a plain directory
# of PNGs that has to be copied into the bundle here and loaded by name at
# runtime (linux/my_application.cc, my_application_set_app_icon).
#
# NOT a Flutter asset in pubspec.yaml, which would have needed no CMake at all:
# that ships desktop artwork inside the Android and iOS bundles too, where
# nothing can ever read it. The files are generated by
# tool/branding/generate_icons.mjs and committed; see docs/BRANDING.md.
#
# scripts/verify_linux_bundle.sh asserts they arrive, because a bundle missing
# them still builds, still runs, and only looks wrong in a window list.
install(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/resources"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
