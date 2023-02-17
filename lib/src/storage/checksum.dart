import 'dart:typed_data';

/// CRC32C (Castagnoli 0x82F63B78) checksum algorithm.
/// Standard checksum used for segment file verification and WAL integrity checks.
class CRC32C {
  int _crc = 0xFFFFFFFF;

  static final Uint32List _table = _generateTable();

  static Uint32List _generateTable() {
    final table = Uint32List(256);
    const poly = 0x82F63B78;
    for (var i = 0; i < 256; i++) {
      var entry = i;
      for (var j = 0; j < 8; j++) {
        if ((entry & 1) != 0) {
          entry = (entry >>> 1) ^ poly;
        } else {
          entry = entry >>> 1;
        }
      }
      table[i] = entry;
    }
    return table;
  }

  /// Resets the checksum calculator to initial state.
  void reset() {
    _crc = 0xFFFFFFFF;
  }

  /// Updates checksum with a single byte.
  void updateByte(int byte) {
    _crc = (_crc >>> 8) ^ _table[(_crc ^ byte) & 0xFF];
  }

  /// Updates checksum with byte slice.
  void update(List<int> bytes, [int offset = 0, int? length]) {
    final count = length ?? (bytes.length - offset);
    for (var i = 0; i < count; i++) {
      final b = bytes[offset + i];
      _crc = (_crc >>> 8) ^ _table[(_crc ^ b) & 0xFF];
    }
  }

  /// Returns final computed 32-bit unsigned checksum.
  int get value => (_crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;

  /// One-shot checksum calculation over full byte slice.
  static int compute(List<int> bytes, [int offset = 0, int? length]) {
    final crc = CRC32C();
    crc.update(bytes, offset, length);
    return crc.value;
  }
}

/// XXHash64: 64-bit high-throughput hash algorithm.
class XXHash64 {
  static const int _prime1 = -7046029288634856825; // 0x9E3779B185EBCA87
  static const int _prime2 = -441727670681411551;  // 0xC2B2AE3D27D4EB4F
  static const int _prime3 = 1609587929392839161;   // 0x165667B19E3779F9
  static const int _prime4 = -8796714831421244945; // 0x85EBCA77C2B2AE63
  static const int _prime5 = 2870177450012600261;   // 0x27D4EB2F165667C5

  /// Computes 64-bit hash over raw byte slice.
  static int hash(List<int> data, [int seed = 0, int offset = 0, int? length]) {
    final len = length ?? (data.length - offset);
    var h64 = 0;

    if (len >= 32) {
      var v1 = seed + _prime1 + _prime2;
      var v2 = seed + _prime2;
      var v3 = seed + 0;
      var v4 = seed - _prime1;

      var pos = offset;
      final limit = offset + len - 32;

      while (pos <= limit) {
        v1 = _round(v1, _readInt64LE(data, pos));
        pos += 8;
        v2 = _round(v2, _readInt64LE(data, pos));
        pos += 8;
        v3 = _round(v3, _readInt64LE(data, pos));
        pos += 8;
        v4 = _round(v4, _readInt64LE(data, pos));
        pos += 8;
      }

      h64 = _rotl64(v1, 1) + _rotl64(v2, 7) + _rotl64(v3, 12) + _rotl64(v4, 18);

      h64 = _mergeRound(h64, v1);
      h64 = _mergeRound(h64, v2);
      h64 = _mergeRound(h64, v3);
      h64 = _mergeRound(h64, v4);
    } else {
      h64 = seed + _prime5;
    }

    h64 += len;

    var pos = offset + (len >= 32 ? (len & ~31) : 0);
    final end = offset + len;

    while (pos + 8 <= end) {
      final k1 = _round(0, _readInt64LE(data, pos));
      h64 ^= k1;
      h64 = _rotl64(h64, 27) * _prime1 + _prime4;
      pos += 8;
    }

    if (pos + 4 <= end) {
      h64 ^= (_readInt32LE(data, pos) & 0xFFFFFFFF) * _prime1;
      h64 = _rotl64(h64, 23) * _prime2 + _prime3;
      pos += 4;
    }

    while (pos < end) {
      h64 ^= (data[pos] & 0xFF) * _prime5;
      h64 = _rotl64(h64, 11) * _prime1;
      pos++;
    }

    h64 ^= h64 >>> 33;
    h64 *= _prime2;
    h64 ^= h64 >>> 29;
    h64 *= _prime3;
    h64 ^= h64 >>> 32;

    return h64;
  }

  static int _round(int acc, int input) {
    acc += input * _prime2;
    acc = _rotl64(acc, 31);
    acc *= _prime1;
    return acc;
  }

  static int _mergeRound(int acc, int val) {
    final v = _round(0, val);
    acc ^= v;
    acc = acc * _prime1 + _prime4;
    return acc;
  }

  static int _rotl64(int x, int r) {
    return (x << r) | (x >>> (64 - r));
  }

  static int _readInt64LE(List<int> bytes, int offset) {
    var val = 0;
    for (var i = 0; i < 8; i++) {
      val |= (bytes[offset + i] & 0xFF) << (i * 8);
    }
    return val;
  }

  static int _readInt32LE(List<int> bytes, int offset) {
    var val = 0;
    for (var i = 0; i < 4; i++) {
      val |= (bytes[offset + i] & 0xFF) << (i * 8);
    }
    return val;
  }
}
