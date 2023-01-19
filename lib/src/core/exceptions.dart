/// Base exception for all engine-specific runtime errors.
class CorbelException implements Exception {
  /// Informative error message.
  final String message;

  /// Underlying cause if this exception wraps another failure.
  final Object? cause;

  /// Stack trace associated with the original failure.
  final StackTrace? stackTrace;

  const CorbelException(this.message, [this.cause, this.stackTrace]);

  @override
  String toString() {
    if (cause != null) {
      return 'CorbelException: $message (Caused by: $cause)';
    }
    return 'CorbelException: $message';
  }
}

/// Thrown when binary segment checksum verification fails or invalid headers are encountered.
class CorbelCorruptIndexException extends CorbelException {
  const CorbelCorruptIndexException(super.message, [super.cause, super.stackTrace]);
}

/// Thrown when an exclusive write lock cannot be obtained on an index directory.
class CorbelLockException extends CorbelException {
  const CorbelLockException(super.message, [super.cause, super.stackTrace]);
}

/// Thrown when document fields violate schema constraints or type mappings.
class CorbelSchemaException extends CorbelException {
  const CorbelSchemaException(super.message, [super.cause, super.stackTrace]);
}

/// Thrown when query string syntax fails to parse into a valid query AST.
class CorbelParseException extends CorbelException {
  /// Character position where the syntax error was detected.
  final int? position;

  const CorbelParseException(
    String message, {
    this.position,
    Object? cause,
    StackTrace? stackTrace,
  }) : super(message, cause, stackTrace);

  @override
  String toString() {
    if (position != null) {
      return 'CorbelParseException at offset $position: $message';
    }
    return 'CorbelParseException: $message';
  }
}

/// Thrown when a requested index, document, or segment is not found.
class CorbelNotFoundException extends CorbelException {
  const CorbelNotFoundException(super.message, [super.cause, super.stackTrace]);
}

/// Thrown when an error occurs during background segment merging.
class CorbelSegmentMergeException extends CorbelException {
  const CorbelSegmentMergeException(super.message, [super.cause, super.stackTrace]);
}

/// Thrown when cluster consensus or replication state operations fail.
class CorbelClusterException extends CorbelException {
  const CorbelClusterException(super.message, [super.cause, super.stackTrace]);
}
