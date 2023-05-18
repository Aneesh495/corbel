import '../core/schema.dart';
import '../index/merge_policy.dart';
import '../storage/directory.dart';

/// Configuration settings governing index writing, buffer sizing, and merge policies.
class IndexWriterConfig {
  final Schema schema;
  final Directory directory;
  final MergePolicy mergePolicy;
  final int maxBufferedDocs;
  final int ramBufferSizeMB;
  final bool enableWal;
  final String walFileName;

  const IndexWriterConfig({
    required this.schema,
    required this.directory,
    this.mergePolicy = const TieredMergePolicy(),
    this.maxBufferedDocs = 1000,
    this.ramBufferSizeMB = 64,
    this.enableWal = true,
    this.walFileName = 'corbel.wal',
  });
}
