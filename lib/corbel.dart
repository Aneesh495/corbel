/// Corbel: High-throughput inverted index, FST term dictionary,
/// columnar DocValues, and HNSW vector-relational retrieval engine in pure Dart.
library;

// Core Models
export 'src/core/constants.dart';
export 'src/core/document.dart';
export 'src/core/exceptions.dart';
export 'src/core/schema.dart';
export 'src/core/version.dart';

// Storage and Encoding
export 'src/storage/byte_buffer.dart';
export 'src/storage/checksum.dart';
export 'src/storage/directory.dart';
export 'src/storage/elias_fano.dart';
export 'src/storage/for_compression.dart';
export 'src/storage/index_input.dart';
export 'src/storage/index_output.dart';
export 'src/storage/roaring_bitmap.dart';
export 'src/storage/vbyte.dart';
export 'src/storage/wal.dart';

// Text Analysis Pipeline
export 'src/analysis/analyzer.dart';
export 'src/analysis/token.dart';
export 'src/analysis/token_stream.dart';

// Index Subsystems
export 'src/index/deletion_vector.dart';
export 'src/index/merge_policy.dart';
export 'src/index/segment_info.dart';
export 'src/index/segment_reader.dart';
export 'src/index/segment_writer.dart';

// Vector Subsystems
export 'src/vector/distance.dart';
export 'src/vector/hnsw_graph.dart';
export 'src/vector/quantization.dart';
export 'src/vector/vector_index.dart';

// Query Engine and Ranking
export 'src/query/boolean_query.dart';
export 'src/query/dismax_query.dart';
export 'src/query/explanation.dart';
export 'src/query/fuzzy_query.dart';
export 'src/query/highlighter.dart';
export 'src/query/hybrid_query.dart';
export 'src/query/knn_vector_query.dart';
export 'src/query/optimizer.dart';
export 'src/query/phrase_query.dart';
export 'src/query/prefix_query.dart';
export 'src/query/query.dart';
export 'src/query/query_parser.dart';
export 'src/query/range_query.dart';
export 'src/query/scorer.dart';
export 'src/query/similarity.dart';
export 'src/query/term_query.dart';
export 'src/query/wand_scorer.dart';
export 'src/query/wildcard_query.dart';

// Positional Span Queries
export 'src/query/span/span_first_query.dart';
export 'src/query/span/span_near_query.dart';
export 'src/query/span/span_not_query.dart';
export 'src/query/span/span_or_query.dart';
export 'src/query/span/span_query.dart';
export 'src/query/span/span_scorer.dart';
export 'src/query/span/span_term_query.dart';
export 'src/query/span/spans.dart';

// Columnar Aggregations
export 'src/aggregation/date_histogram.dart';
export 'src/aggregation/range_aggregation.dart';
export 'src/aggregation/stats_aggregation.dart';
export 'src/aggregation/t_digest.dart';
export 'src/aggregation/terms_aggregation.dart';

// Spatial and Multidimensional Indexing
export 'src/spatial/bkd_tree.dart';
export 'src/spatial/geo_aggregations.dart';
export 'src/spatial/geo_distance.dart';
export 'src/spatial/geo_point.dart';
export 'src/spatial/geo_queries.dart';
export 'src/spatial/geo_shapes.dart';

// Runtime Engine & Concurrency
export 'src/concurrency/isolate_pool.dart';
export 'src/engine/corbel_engine.dart';
export 'src/engine/index_searcher.dart';
export 'src/engine/index_writer.dart';
export 'src/engine/index_writer_config.dart';
export 'src/engine/snapshot.dart';

// Cluster and Distributed Replication
export 'src/cluster/raft.dart';
export 'src/cluster/segment_sync.dart';

// Server and Native Acceleration
export 'src/native/simd_ffi.dart';
export 'src/server/http_server.dart';
export 'src/server/router.dart';
