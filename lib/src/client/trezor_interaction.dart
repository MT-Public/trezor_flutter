import '../messages/common.dart';

/// How the wallet to open should be unlocked when passphrase protection is on.
sealed class TrezorPassphrase {
  const TrezorPassphrase();

  /// The default wallet (empty passphrase).
  static const TrezorPassphrase standardWallet = TrezorPassphraseText('');

  /// Typed on the Trezor itself. Only for models with
  /// `TrezorCapability.passphraseEntry`.
  static const TrezorPassphrase onDevice = TrezorPassphraseOnDevice();
}

class TrezorPassphraseText extends TrezorPassphrase {
  const TrezorPassphraseText(this.passphrase);

  final String passphrase;
}

class TrezorPassphraseOnDevice extends TrezorPassphrase {
  const TrezorPassphraseOnDevice();
}

/// Callbacks for everything that needs the user while talking to a Trezor.
///
/// Returning null from an async callback cancels the operation, which then
/// fails with a `TrezorFailureException` whose `isCancelled` is true.
class TrezorInteraction {
  const TrezorInteraction({
    this.onButtonRequest,
    this.onInteractionEnded,
    this.onPinMatrixRequest,
    this.onPassphraseRequest,
    this.onPairingCodeRequest,
  });

  /// The device is showing something the user must confirm or read. Show
  /// "Confirm on your Trezor". Fire-and-forget: the device drives the flow.
  final void Function(ButtonRequest request)? onButtonRequest;

  /// The device answered after one or more [onButtonRequest]s; hide the
  /// prompt.
  final void Function()? onInteractionEnded;

  /// Model One only. Return the PIN encoded as positions on the scrambled
  /// 3×3 matrix the device shows (keypad layout 7 8 9 / 4 5 6 / 1 2 3).
  /// `type` is a `PinMatrixRequestType`.
  final Future<String?> Function(int type)? onPinMatrixRequest;

  /// Passphrase protection is enabled. Null callback → standard wallet.
  final Future<TrezorPassphrase?> Function()? onPassphraseRequest;

  /// First Bluetooth connection (THP): the Trezor shows a 6-digit code, and
  /// the user types it into the app.
  final Future<String?> Function()? onPairingCodeRequest;
}
