const int hardenedOffset = 0x80000000;

/// Parses `m/44'/60'/0'/0/0` (also accepting `h`/`H` for hardened) into the
/// `address_n` list Trezor messages carry.
List<int> parseBip32Path(String path) {
  final trimmed = path.trim();
  final parts = trimmed.split('/');
  if (parts.isEmpty || (parts.first != 'm' && parts.first != 'M')) {
    throw FormatException('BIP-32 path must start with "m/"', path);
  }
  final result = <int>[];
  for (final raw in parts.skip(1)) {
    if (raw.isEmpty) throw FormatException('Empty path component', path);
    final hardened =
        raw.endsWith("'") || raw.endsWith('h') || raw.endsWith('H');
    final digits = hardened ? raw.substring(0, raw.length - 1) : raw;
    final index = int.tryParse(digits);
    if (index == null || index < 0 || index >= hardenedOffset) {
      throw FormatException('Invalid path component "$raw"', path);
    }
    result.add(hardened ? index + hardenedOffset : index);
  }
  return result;
}

String formatBip32Path(List<int> addressN) {
  final buffer = StringBuffer('m');
  for (final index in addressN) {
    if (index >= hardenedOffset) {
      buffer.write("/${index - hardenedOffset}'");
    } else {
      buffer.write('/$index');
    }
  }
  return buffer.toString();
}
