Pod::Spec.new do |s|
  s.name             = 'trezor_flutter'
  s.version          = '1.2.0'
  s.summary          = 'USB and Bluetooth LE transport for Trezor hardware wallets on macOS.'
  s.description      = <<-DESC
IOKit (USB) and CoreBluetooth (Bluetooth LE) implementation of the
trezor_flutter packet pipe. The Trezor protocols themselves (Codec v1 and THP)
are implemented in Dart.
                       DESC
  s.homepage         = 'https://github.com/MT-Public/trezor_flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Macromodule Technologies' => 'https://macromodule.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'trezor_flutter/Sources/trezor_flutter/**/*.swift'
  s.resource_bundles = {
    'trezor_flutter_privacy' => ['trezor_flutter/Sources/trezor_flutter/PrivacyInfo.xcprivacy']
  }
  s.dependency 'FlutterMacOS'
  s.frameworks       = 'CoreBluetooth', 'IOKit'
  s.platform         = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
