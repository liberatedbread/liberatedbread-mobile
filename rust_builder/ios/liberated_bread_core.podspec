#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint liberated_bread_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'liberated_bread_core'
  s.version          = '0.0.1'
  s.summary          = 'Rust core for Liberated Bread Mobile.'
  s.description      = <<-DESC
The BLE and device-spec engine behind Liberated Bread Mobile, built from
../../rust by cargokit and linked into the Flutter app over FFI.
                       DESC
  s.homepage         = 'https://github.com/liberatedbread/liberatedbread-mobile'
  s.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  s.author           = 'Pigs Can Fly Labs LLC'

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  # Keep in step with IPHONEOS_DEPLOYMENT_TARGET in
  # ios/Runner.xcodeproj/project.pbxproj — test/platform/
  # deployment_targets_test.dart fails when they diverge. A pod floor BELOW the
  # app's is not harmless: CocoaPods builds the pod against its own declared
  # platform, so the lower number silently opts this target out of the
  # availability checking the rest of the app gets, and an API newer than 11.0
  # used in a future Classes/ file would compile here and crash on a device the
  # app still claims to support.
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust liberated_bread_core',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/libliberated_bread_core.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/libliberated_bread_core.a',
  }
end
