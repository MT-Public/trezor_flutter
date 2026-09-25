import 'dart:convert';
import 'dart:typed_data';

import '../exceptions.dart';

/// Minimal protobuf (proto2) wire codec covering what Trezor messages use.
///
/// Trezor's schemas only use varint scalars (uint32/uint64/bool/enum) and
/// length-delimited fields (bytes/string/embedded message), so those are the
/// two wire types written. The reader also accepts packed repeated varints and
/// skips fixed32/fixed64 fields, so a firmware that adds fields of any type to
/// a response never breaks decoding.
///
/// This replaces protoc-generated code on purpose: it keeps the package free of
/// a code-generation toolchain, and each message class documents exactly which
/// fields the host relies on.
class ProtoWriter {
  final BytesBuilder _out = BytesBuilder();

  static const _wireVarint = 0;
  static const _wireLength = 2;

  void _key(int field, int wireType) => _varint((field << 3) | wireType);

  void _varint(int value) {
    if (value < 0) {
      throw ArgumentError.value(value, 'value', 'negative varints unsupported');
    }
    var v = value;
    while (v >= 0x80) {
      _out.addByte((v & 0x7F) | 0x80);
      v >>= 7;
    }
    _out.addByte(v);
  }

  void uint(int field, int? value) {
    if (value == null) return;
    _key(field, _wireVarint);
    _varint(value);
  }

  void boolean(int field, bool? value) {
    if (value == null) return;
    uint(field, value ? 1 : 0);
  }

  void bytes(int field, List<int>? value) {
    if (value == null) return;
    _key(field, _wireLength);
    _varint(value.length);
    _out.add(value);
  }

  void string(int field, String? value) {
    if (value == null) return;
    bytes(field, utf8.encode(value));
  }

  void message(int field, ProtoEncodable? value) {
    if (value == null) return;
    bytes(field, value.encode());
  }

  /// Repeated varints, unpacked — the proto2 default and what trezorlib writes.
  void repeatedUint(int field, List<int> values) {
    for (final v in values) {
      uint(field, v);
    }
  }

  void repeatedBytes(int field, List<List<int>> values) {
    for (final v in values) {
      bytes(field, v);
    }
  }

  void repeatedMessage(int field, List<ProtoEncodable> values) {
    for (final v in values) {
      message(field, v);
    }
  }

  Uint8List toBytes() => _out.toBytes();
}

/// Anything that serializes to a protobuf message body.
abstract interface class ProtoEncodable {
  Uint8List encode();
}

/// Decoded fields of one message, keyed by field number.
///
/// Values are `int` for varints and `Uint8List` for length-delimited fields;
/// repeated fields keep every occurrence in order.
class ProtoFields {
  ProtoFields._(this._fields);

  final Map<int, List<Object>> _fields;

  factory ProtoFields.decode(List<int> data) {
    final fields = <int, List<Object>>{};
    var offset = 0;

    int readVarint() {
      var result = 0;
      var shift = 0;
      while (true) {
        if (offset >= data.length) {
          throw const TrezorProtocolException('Truncated protobuf varint');
        }
        final byte = data[offset++];
        if (shift < 64) result |= (byte & 0x7F) << shift;
        if (byte & 0x80 == 0) return result;
        shift += 7;
        if (shift > 70) {
          throw const TrezorProtocolException('Protobuf varint too long');
        }
      }
    }

    while (offset < data.length) {
      final key = readVarint();
      final field = key >> 3;
      final wireType = key & 0x7;
      switch (wireType) {
        case 0:
          (fields[field] ??= []).add(readVarint());
        case 1:
          offset += 8;
        case 2:
          final length = readVarint();
          if (length < 0 || offset + length > data.length) {
            throw const TrezorProtocolException('Truncated protobuf field');
          }
          (fields[field] ??= []).add(
            Uint8List.fromList(data.sublist(offset, offset + length)),
          );
          offset += length;
        case 5:
          offset += 4;
        default:
          throw TrezorProtocolException('Unsupported wire type $wireType');
      }
      if (offset > data.length) {
        throw const TrezorProtocolException('Truncated protobuf field');
      }
    }
    return ProtoFields._(fields);
  }

  bool has(int field) => _fields.containsKey(field);

  int? uint(int field) {
    final values = _fields[field];
    if (values == null) return null;
    final last = values.last;
    if (last is int) return last;
    // A packed repeated field read as a scalar: take its last element.
    final unpacked = _unpackVarints(last as Uint8List);
    return unpacked.isEmpty ? null : unpacked.last;
  }

  bool? boolean(int field) {
    final v = uint(field);
    return v == null ? null : v != 0;
  }

  Uint8List? bytes(int field) {
    final values = _fields[field];
    if (values == null) return null;
    final last = values.last;
    return last is Uint8List ? last : null;
  }

  String? string(int field) {
    final b = bytes(field);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  T? message<T>(int field, T Function(ProtoFields) decode) {
    final b = bytes(field);
    return b == null ? null : decode(ProtoFields.decode(b));
  }

  List<int> uints(int field) {
    final values = _fields[field];
    if (values == null) return const [];
    final result = <int>[];
    for (final v in values) {
      if (v is int) {
        result.add(v);
      } else {
        result.addAll(_unpackVarints(v as Uint8List));
      }
    }
    return result;
  }

  List<Uint8List> bytesList(int field) =>
      (_fields[field] ?? const []).whereType<Uint8List>().toList();

  List<T> messages<T>(int field, T Function(ProtoFields) decode) =>
      bytesList(field).map((b) => decode(ProtoFields.decode(b))).toList();

  static List<int> _unpackVarints(Uint8List data) {
    final result = <int>[];
    var offset = 0;
    while (offset < data.length) {
      var value = 0;
      var shift = 0;
      while (true) {
        final byte = data[offset++];
        if (shift < 64) value |= (byte & 0x7F) << shift;
        if (byte & 0x80 == 0) break;
        shift += 7;
        if (offset >= data.length) {
          throw const TrezorProtocolException('Truncated packed varint');
        }
      }
      result.add(value);
    }
    return result;
  }
}
