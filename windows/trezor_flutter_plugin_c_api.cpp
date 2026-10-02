#include "include/trezor_flutter/trezor_flutter_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "trezor_flutter_plugin.h"

void TrezorFlutterPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  trezor_flutter::TrezorFlutterPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
