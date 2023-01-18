/// Engine version metadata and binary format constants.
class CorbelVersion {
  /// Major version incremented on breaking disk format changes.
  static const int major = 1;

  /// Minor version incremented on backward-compatible feature additions.
  static const int minor = 0;

  /// Patch version incremented on bug fixes and performance improvements.
  static const int patch = 0;

  /// Human-readable version string.
  static const String versionString = '1.0.0';

  /// Magic 32-bit header identifying Corbel binary segment files.
  /// ASCII for 'C' (0x43), 'B' (0x42), 'E' (0x45), 'L' (0x4C).
  static const int magicHeader = 0x4342454C;

  /// Current binary format version for index segments.
  static const int currentFormatVersion = 1;

  /// Minimum binary format version supported for reading backward compatibility.
  static const int minimumSupportedFormatVersion = 1;

  const CorbelVersion._();
}
