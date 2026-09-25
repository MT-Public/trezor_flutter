/// Everything this package throws derives from [TrezorException], so callers
/// can catch the family without also swallowing unrelated errors.
class TrezorException implements Exception {
  const TrezorException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The native layer reported an error (permission, adapter off, open failed).
///
/// [code] is one of the string constants on [TrezorPlatformErrorCode], taken
/// verbatim from the `PlatformException` code the native side raised.
class TrezorPlatformException extends TrezorException {
  const TrezorPlatformException(this.code, String message) : super(message);

  final String code;

  @override
  String toString() => 'TrezorPlatformException($code): $message';
}

/// Error codes shared by the Android and iOS implementations.
abstract final class TrezorPlatformErrorCode {
  static const deviceNotFound = 'deviceNotFound';
  static const permissionDenied = 'permissionDenied';
  static const bluetoothUnavailable = 'bluetoothUnavailable';
  static const bluetoothOff = 'bluetoothOff';
  static const bondingFailed = 'bondingFailed';
  static const openFailed = 'openFailed';
  static const notConnected = 'notConnected';
  static const writeFailed = 'writeFailed';
  static const timeout = 'timeout';
  static const unsupported = 'unsupported';
}

/// The device went away (unplugged, out of range, powered off).
class TrezorDisconnectedException extends TrezorException {
  const TrezorDisconnectedException([super.message = 'Trezor disconnected']);
}

class TrezorTimeoutException extends TrezorException {
  const TrezorTimeoutException(super.message);
}

/// The bytes on the wire did not match what the protocol allows.
class TrezorProtocolException extends TrezorException {
  const TrezorProtocolException(super.message);
}

/// The device answered with a `Failure` message.
class TrezorFailureException extends TrezorException {
  const TrezorFailureException(this.code, String message) : super(message);

  /// `Failure.code`; see [TrezorFailureCode]. Null if the device omitted it.
  final int? code;

  bool get isCancelled =>
      code == TrezorFailureCode.actionCancelled ||
      code == TrezorFailureCode.pinCancelled;

  @override
  String toString() => 'TrezorFailureException($code): $message';
}

/// `Failure.FailureType` values from `messages-common.proto`.
abstract final class TrezorFailureCode {
  static const unexpectedMessage = 1;
  static const buttonExpected = 2;
  static const dataError = 3;
  static const actionCancelled = 4;
  static const pinExpected = 5;
  static const pinCancelled = 6;
  static const pinInvalid = 7;
  static const invalidSignature = 8;
  static const processError = 9;
  static const notEnoughFunds = 10;
  static const notInitialized = 11;
  static const pinMismatch = 12;
  static const wipeCodeMismatch = 13;
  static const invalidSession = 14;
  static const busy = 15;
  static const thpUnallocatedSession = 16;
  static const invalidProtocol = 17;
  static const inProgress = 19;
  static const firmwareError = 99;
}

/// A THP transport-layer error packet (`transport_error` control byte).
class ThpTransportException extends TrezorException {
  ThpTransportException(this.code) : super(_describe(code));

  final int code;

  static const transportBusy = 1;
  static const unallocatedChannel = 2;
  static const decryptionFailed = 3;
  static const deviceLocked = 5;

  static String _describe(int code) => switch (code) {
    transportBusy => 'THP transport busy',
    unallocatedChannel => 'THP channel is not allocated',
    decryptionFailed => 'THP decryption failed',
    deviceLocked => 'Trezor is locked',
    _ => 'THP transport error $code',
  };
}

/// THP pairing did not complete: the code was wrong, the user declined on the
/// device, or a commitment check failed.
class TrezorPairingException extends TrezorException {
  const TrezorPairingException(super.message);
}
