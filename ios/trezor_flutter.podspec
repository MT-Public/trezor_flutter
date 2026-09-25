Pod::Spec.new do |s|
  s.name             = 'trezor_flutter'
  s.version          = '1.0.0'
  s.summary          = 'Bluetooth LE transport for Trezor hardware wallets.'
  s.description      = <<-DESC
CoreBluetooth implementation of the trezor_flutter packet pipe. The Trezor
protocols themselves (Codec v1 and THP) are implemented in Dart.
                       DESC
  s.homepage         = 'https://github.com/MT-Public/trezor_flutter'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'MT-Public' => 'https://github.com/MT-Public' }
  s.source           = { :path => '.' }
  s.source_files     = 'trezor_flutter/Sources/trezor_flutter/**/*.swift'
  s.resource_bundles = {
    'trezor_flutter_privacy' => ['trezor_flutter/Sources/trezor_flutter/PrivacyInfo.xcprivacy']
  }
  s.dependency 'Flutter'
  s.framework        = 'CoreBluetooth'
  s.platform         = :ios, '14.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
