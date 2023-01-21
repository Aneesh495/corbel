/// Global system constants and tuning thresholds for Corbel.
class CorbelConstants {
  /// Default block size for 128-integer Frame of Reference (FoR) postings.
  static const int postingsBlockSize = 128;

  /// Default skip interval for postings skip lists.
  static const int defaultSkipInterval = 16;

  /// Default BM25 term frequency saturation parameter k1.
  static const double defaultBm25K1 = 1.2;

  /// Default BM25 document length normalization parameter b.
  static const double defaultBm25B = 0.75;

  /// Default number of bi-directional links per node in HNSW vector graphs (M).
  static const int defaultHnswM = 16;

  /// Maximum connections per node on base layer l0 in HNSW graphs (2 * M).
  static const int defaultHnswM0 = 32;

  /// Size of dynamic candidate list during HNSW graph construction.
  static const int defaultHnswEfConstruction = 100;

  /// Size of dynamic candidate list during HNSW nearest neighbor search.
  static const int defaultHnswEfSearch = 50;

  /// Maximum buffer memory budget before IndexWriter automatically triggers a segment flush.
  static const int defaultFlushMemoryBudgetBytes = 32 * 1024 * 1024; // 32 MB

  /// Default maximum segment size before segment is frozen against further merges.
  static const int defaultMaxSegmentSizeBytes = 5 * 1024 * 1024 * 1024; // 5 GB

  /// Maximum number of segments allowed before tiered merge policy triggers merge.
  static const int defaultMaxSegmentsPerTier = 10;

  /// Default TCP port for Corbel HTTP and REST engine.
  static const int defaultHttpPort = 8484;

  /// Default TCP port for Corbel cluster consensus and segment rsync.
  static const int defaultClusterPort = 8485;

  const CorbelConstants._();
}
