import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:trezor_flutter/messages.dart';
import 'package:trezor_flutter/trezor_flutter.dart';
import 'package:trezor_flutter/src/protocol/codec_v1.dart';
import 'package:trezor_flutter/src/protocol/thp/thp_channel.dart';
import 'package:trezor_flutter/src/protocol/thp/thp_crypto.dart';
import 'package:trezor_flutter/src/protocol/thp/thp_packet.dart';
import 'package:trezor_flutter/src/protobuf/proto.dart';
import 'package:trezor_flutter/src/util/bytes.dart';

import 'fake_trezor.dart';

const app = TrezorAppIdentity(appName: 'Test Wallet', hostName: 'Test phone');

void main() {
  group('known-answer vectors', () {
    test('CRC-32/IEEE', () {
      expect(crc32(ascii.encode('123456789')), 0xCBF43926);
    });

    test('Elligator 2 (elligator.org curve25519_direct vectors)', () {
      const vectors = {
        '0000000000000000000000000000000000000000000000000000000000000000':
            '0000000000000000000000000000000000000000000000000000000000000000',
        '66665895c5bc6e44ba8d65fd9307092e3244bf2c18877832bd568cb3a2d38a12':
            '04d44290d13100b2c25290c9343d70c12ed4813487a07ac1176daa5925e7975e',
        '673a505e107189ee54ca93310ac42e4545e9e59050aaac6f8b5f64295c8ec02f':
            '242ae39ef158ed60f20b89396d7d7eef5374aba15dc312a6aea6d1e57cacf85e',
        '990b30e04e1c3620b4162b91a33429bddb9f1b70f1da6e5f76385ed3f98ab131':
            '998e98021eb4ee653effaa992f3fae4b834de777a953271baaa1fa3fef6b776e',
        '341a60725b482dd0de2e25a585b208433044bc0a1ba762442df3a0e888ca063c':
            '683a71d7fca4fc6ad3d4690108be808c2e50a5af3174486741d0a83af52aeb01',
        '185435d2b005a3b63f3187e64a1ef3582533e1958d30e4e4747b4d1d3376c728':
            'f938b1b320abb0635930bd5d7ced45ae97fa8b5f71cc21d87b4c60905c125d34',
      };
      vectors.forEach((input, output) {
        expect(bytesToHex(elligator2(hexToBytes(input))), output);
      });
    });

    test('CPace generator (draft-irtf-cfrg-cpace test vectors)', () {
      final prs = ascii.encode('Password');
      final ci = ascii.encode('oc\x0bB_responder\x0bA_initiator');
      final sid = hexToBytes('7e4b4791d6a8ef019b936c79fb7f2c57');
      expect(
        bytesToHex(cpaceGeneratorString(prs: prs, ci: ci, sid: sid)),
        '0843506163653235350850617373776f72646d000000000000000000'
        '00000000000000000000000000000000000000000000000000000000'
        '00000000000000000000000000000000000000000000000000000000'
        '00000000000000000000000000000000000000000000000000000000'
        '000000000000000000000000000000001a6f630b425f726573706f6e'
        '6465720b415f696e69746961746f72107e4b4791d6a8ef019b936c79'
        'fb7f2c57',
      );
      expect(
        bytesToHex(cpaceGenerator(prs: prs, ci: ci, sid: sid)),
        '64e8099e3ea682cfdc5cb665c057ebb514d06bf23ebc9f743b51b82242327074',
      );
    });
  });

  group('framing', () {
    test('Codec v1 packets carry ?## header and are padded', () {
      final payload = Uint8List.fromList(List.generate(100, (i) => i));
      final packets = CodecV1Wire.encodePackets(17, payload, 64);
      expect(packets, hasLength(2)); // 8 header + 100 body = 108 > 63
      expect(packets.every((p) => p.length == 64 && p[0] == 0x3F), isTrue);
      expect(packets[0].sublist(1, 9), [0x23, 0x23, 0, 17, 0, 0, 0, 100]);
    });

    test('THP message survives segmentation at 64 and 244 bytes', () {
      for (final size in [64, 244]) {
        final data = Uint8List.fromList(List.generate(700, (i) => i & 0xFF));
        final message = ThpMessage(0x14, 0xABCD, data);
        final assembler = ThpAssembler();
        ThpMessage? out;
        for (final p in message.toPackets(size)) {
          expect(p.length, size);
          out = assembler.add(p) ?? out;
        }
        expect(out!.control, 0x14);
        expect(out.channelId, 0xABCD);
        expect(out.data, data);
      }
    });

    test('THP assembler drops a payload with a bad CRC', () {
      final packets = ThpMessage(0x04, 1, Uint8List(10)).toPackets(64);
      packets[0][6] ^= 0xFF;
      expect(ThpAssembler().add(packets[0]), isNull);
    });
  });

  group('Codec v1 over USB', () {
    test('probe, Initialize, and a ButtonRequest round trip', () async {
      final link = FakeLink(64);
      final device = FakeCodecV1Trezor(link);
      var buttonRequests = 0;
      var ended = 0;
      final client = await TrezorClient.connect(
        link: link,
        transport: TrezorTransportType.usb,
        app: app,
        interaction: TrezorInteraction(
          onButtonRequest: (_) => buttonRequests++,
          onInteractionEnded: () => ended++,
        ),
      );
      expect(client.protocol, TrezorProtocol.codecV1);
      expect(client.features.model, 'Safe 5');
      expect(client.features.firmwareVersion, '2.9.3');

      final pong = await client.callExpect<Success>(const Ping(message: 'hi'));
      expect(pong.message, 'hi');
      expect(buttonRequests, 1);
      expect(ended, 1);
      expect(device.received.first, MessageType.cancel);
    });
  });

  group('Ethereum signing', () {
    Future<(TrezorClient, FakeCodecV1Trezor)> connected() async {
      final link = FakeLink(64);
      final device = FakeCodecV1Trezor(link);
      final client = await TrezorClient.connect(
        link: link,
        transport: TrezorTransportType.usb,
        app: app,
      );
      return (client, device);
    }

    test('EIP-1559 streams calldata beyond the first 1024 bytes', () async {
      final (client, device) = await connected();
      final data = Uint8List.fromList(List.generate(2500, (i) => i & 0xFF));
      final sig = await client.ethereumSignEip1559(
        path: "m/44'/60'/0'/0/0",
        chainId: 137,
        nonce: BigInt.from(7),
        maxFeePerGas: BigInt.from(60000000000),
        maxPriorityFeePerGas: BigInt.from(30000000000),
        gasLimit: BigInt.from(100000),
        to: '0x000000000000000000000000000000000000dEaD',
        value: BigInt.zero,
        data: data,
      );
      expect(device.signedChainId, 137);
      expect(device.receivedCalldata!.toBytes(), data);
      expect(sig.v, BigInt.one);
      expect(sig.r, List.filled(32, 0x11));
      expect(sig.s, List.filled(32, 0x22));
    });

    test('legacy parity-only v is rebuilt as EIP-155', () async {
      final (client, device) = await connected();
      device.legacyParity = 1;
      final sig = await client.ethereumSignLegacy(
        path: "m/44'/60'/0'/0/0",
        chainId: 56,
        nonce: BigInt.zero,
        gasPrice: BigInt.from(3000000000),
        gasLimit: BigInt.from(21000),
        to: '0x000000000000000000000000000000000000dEaD',
        value: BigInt.from(10).pow(15),
      );
      expect(sig.v, BigInt.from(1 + 2 * 56 + 35));
      expect(device.receivedCalldata!.toBytes(), isEmpty);
    });
  });

  group('Solana', () {
    test('address and signature on a hardened path', () async {
      final link = FakeLink(64);
      final device = FakeCodecV1Trezor(link);
      final client = await TrezorClient.connect(
        link: link,
        transport: TrezorTransportType.usb,
        app: app,
      );
      const path = "m/44'/501'/2'/0'";
      expect(await client.solanaGetAddress(path), 'So1anaFakeAddress');
      expect(device.solanaPath, parseBip32Path(path));

      final message = Uint8List.fromList(List.generate(150, (i) => i));
      final sig = await client.solanaSignTransaction(path, message);
      expect(sig, List.filled(64, 0x33));
      expect(device.solanaSignedMessage, message);
    });
  });

  group('Tron', () {
    // Unsigned transactions exactly as TronGrid returned them
    // (createtransaction / triggersmartcontract, USDT transfer).
    final trxTransfer = hexToBytes(
      '0a02f9f42208ad71395f7e9aa6be40c8bdebb88e345a67080112630a2d747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5472616e73666572436f6e747261637412320a154189cbcb2372e1c2fbc00f24895a406a0c722c89f312154182dd6b9966724ae2fdc79b416c7588da67ff1b3518c0843d70b984e8b88e34',
    );
    final trc20Transfer = hexToBytes(
      '0a02f9f522081bc31384699eb1964080d5ebb88e345aae01081f12a9010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412740a154189cbcb2372e1c2fbc00f24895a406a0c722c89f3121541a614f803b6fd780986a42c78ec9c7f77e6ded13c2244a9059cbb00000000000000000000000082dd6b9966724ae2fdc79b416c7588da67ff1b3500000000000000000000000000000000000000000000000000000000000f424070a089e8b88e34900180c2d72f',
    );

    test('TronGrid raw_data is reproduced byte for byte', () {
      final trx = TronRawTransactionParser.parse(trxTransfer);
      expect(trx.contract.messageType, MessageType.tronTransferContract);
      expect(trx.feeLimit, isNull);

      final trc20 = TronRawTransactionParser.parse(trc20Transfer);
      expect(trc20.contract.messageType, MessageType.tronTriggerSmartContract);
      expect(trc20.feeLimit, 100000000);
    });

    test('signs from raw_data: SignTx, then the contract', () async {
      final link = FakeLink(64);
      final device = FakeCodecV1Trezor(link);
      final client = await TrezorClient.connect(
        link: link,
        transport: TrezorTransportType.usb,
        app: app,
      );
      final sig = await client.tronSignRawTransaction(
        "m/44'/195'/0'/0/0",
        trc20Transfer,
      );
      expect(sig, List.filled(65, 0x44));
      expect(device.tronContractType, MessageType.tronTriggerSmartContract);
      final signTx = ProtoFields.decode(device.tronSignTx!);
      expect(signTx.uints(1), parseBip32Path("m/44'/195'/0'/0/0"));
      expect(signTx.uint(7), 100000000);
    });

    test('refuses what Trezor could not rebuild exactly', () {
      final tx = ProtoFields.decode(trxTransfer);
      final contract = tx.bytes(11)!;

      // Permission id on the contract (multi-signature accounts).
      final withPermission = Uint8List.fromList([
        ...trxTransfer.sublist(0, trxTransfer.length),
      ]);
      final patchedContract = Uint8List.fromList([...contract, 0x28, 0x02]);
      final patched = _replaceField11(
        withPermission,
        contract,
        patchedContract,
      );
      expect(
        () => TronRawTransactionParser.parse(patched),
        throwsA(isA<TrezorProtocolException>()),
      );

      // Two contracts.
      final twoContracts = Uint8List.fromList([
        ...trxTransfer,
        0x5a,
        contract.length,
        ...contract,
      ]);
      expect(
        () => TronRawTransactionParser.parse(twoContracts),
        throwsA(isA<TrezorProtocolException>()),
      );

      // Same fields, different order: the device would sign other bytes.
      final reordered =
          (ProtoWriter()
                ..uint(8, tx.uint(8))
                ..bytes(1, tx.bytes(1))
                ..bytes(4, tx.bytes(4))
                ..bytes(11, contract)
                ..uint(14, tx.uint(14)))
              .toBytes();
      expect(
        () => TronRawTransactionParser.parse(reordered),
        throwsA(isA<TrezorProtocolException>()),
      );
    });
  });

  group('THP', () {
    late Uint8List deviceKey;
    setUp(() => deviceKey = randomBytes(32));

    Future<TrezorClient> connect(
      FakeLink link,
      FakeThpTrezor device,
      ThpCredentialStore store, {
      TrezorTransportType transport = TrezorTransportType.ble,
      List<String>? codesAsked,
    }) => TrezorClient.connect(
      link: link,
      transport: transport,
      app: app,
      credentialStore: store,
      interaction: TrezorInteraction(
        onPairingCodeRequest: () async {
          codesAsked?.add(device.displayedCode!);
          return device.displayedCode;
        },
      ),
    );

    test(
      'first BLE connection pairs with a code and stores a credential',
      () async {
        final link = FakeLink(244);
        final device = FakeThpTrezor(link, staticPrivateKey: deviceKey);
        final store = InMemoryThpCredentialStore();
        final asked = <String>[];

        final client = await connect(link, device, store, codesAsked: asked);

        expect(client.protocol, TrezorProtocol.thp);
        expect(client.features.internalModel, 'T3W1');
        expect(asked, hasLength(1));
        expect(device.pairingConfirmationShown, isTrue);
        final saved = await store.load();
        expect(saved, hasLength(1));
        expect(
          saved.single.trezorStaticPublicKey,
          await ThpCrypto.x25519PublicKey(deviceKey),
        );
      },
    );

    test('reconnecting with the stored credential skips pairing', () async {
      final store = InMemoryThpCredentialStore();
      final firstLink = FakeLink(244);
      final device = FakeThpTrezor(firstLink, staticPrivateKey: deviceKey);
      await connect(firstLink, device, store);

      final secondLink = FakeLink(244);
      final sameDevice = FakeThpTrezor(secondLink, staticPrivateKey: deviceKey)
        ..credAuthKey.setAll(0, device.credAuthKey);
      final asked = <String>[];
      final client = await connect(
        secondLink,
        sameDevice,
        store,
        codesAsked: asked,
      );

      expect(asked, isEmpty);
      expect(client.features.model, 'Safe 7');
    });

    test('a wrong code fails pairing and stores nothing', () async {
      final link = FakeLink(244);
      final device = FakeThpTrezor(link, staticPrivateKey: deviceKey);
      final store = InMemoryThpCredentialStore();
      final attempt = TrezorClient.connect(
        link: link,
        transport: TrezorTransportType.ble,
        app: app,
        credentialStore: store,
        interaction: TrezorInteraction(
          onPairingCodeRequest: () async =>
              device.displayedCode == '000000' ? '111111' : '000000',
        ),
      );
      await expectLater(attempt, throwsA(isA<TrezorPairingException>()));
      expect(await store.load(), isEmpty);
    });

    test('USB: Cancel probe falls through to THP', () async {
      final link = FakeLink(64);
      final device = FakeThpTrezor(link, staticPrivateKey: deviceKey);
      // A THP device answers a Codec v1 message with Failure(InvalidProtocol).
      final thpHandler = link.onHostPacket!;
      link.onHostPacket = (packet) {
        if (packet[0] == 0x3F && packet[1] == 0x23) {
          for (final p in CodecV1Wire.encodePackets(
            MessageType.failure,
            (ProtoWriterShim.failure(17)),
            64,
          )) {
            link.deliver(p);
          }
          return;
        }
        thpHandler(packet);
      };
      final client = await connect(
        link,
        device,
        InMemoryThpCredentialStore(),
        transport: TrezorTransportType.usb,
      );
      expect(client.protocol, TrezorProtocol.thp);
    });

    test('a lost packet is retransmitted after the ACK timeout', () async {
      // Packet 1 is the allocation request, packet 2 the handshake
      // initiation: drop it so no ACK comes back and the host must resend.
      final link = FakeLink(244)..dropHostPacket = 2;
      final device = FakeThpTrezor(link, staticPrivateKey: deviceKey);
      final watch = Stopwatch()..start();
      final client = await connect(link, device, InMemoryThpCredentialStore());
      expect(client.features.model, 'Safe 7');
      expect(watch.elapsed, greaterThanOrEqualTo(ThpChannel.ackTimeout));
    });

    test('wallet calls open a seeded session on id 1', () async {
      final link = FakeLink(244);
      final device = FakeThpTrezor(link, staticPrivateKey: deviceKey);
      final client = await connect(link, device, InMemoryThpCredentialStore());
      final address = await client.callWallet<EthereumAddress>(
        EthereumGetAddress(addressN: parseBip32Path("m/44'/60'/0'/0/0")),
      );
      expect(address.address, startsWith('session1:'));
    });
  });
}

abstract final class ProtoWriterShim {
  /// `Failure { code = [code] }`, encoded by hand.
  static Uint8List failure(int code) => Uint8List.fromList([0x08, code]);
}

/// Replaces the single contract (field 11) in [raw] with [replacement].
Uint8List _replaceField11(Uint8List raw, Uint8List old, Uint8List replacement) {
  final hexRaw = bytesToHex(raw);
  final oldField = bytesToHex([0x5a, old.length, ...old]);
  final newField = bytesToHex([0x5a, replacement.length, ...replacement]);
  return hexToBytes(hexRaw.replaceFirst(oldField, newField));
}
