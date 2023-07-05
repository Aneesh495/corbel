# Corbel

[![CI](https://github.com/Aneesh495/corbel/actions/workflows/ci.yml/badge.svg)](https://github.com/Aneesh495/corbel)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Dart 3.0+](https://img.shields.io/badge/Dart-3.0%2B-0175C2.svg)](https://dart.dev)

Corbel is a high-throughput, embedded search and vector-relational retrieval engine written from scratch in Dart with C SIMD acceleration. It unifies Lucene-style inverted index pipelines, minimal acyclic Finite State Transducers (FST), columnar DocValues, RoaringBitmaps, Block KD-Trees (BKD), and Hierarchical Navigable Small World (HNSW) vector graphs into an autonomous runtime.

---

## Architectural Topology

```
+-------------------------------------------------------------------------+
|                           CorbelEngine Facade                           |
|       (REST HTTP API, Embedded Dashboard, Python Client, CLI/REPL)      |
+-------------------------------------------------------------------------+
       |                                                    |
       v (Writes)                                           v (Reads)
+------------------------------------+    +-------------------------------+
|            IndexWriter             |    |         IndexSearcher         |
|  - In-Memory Segment Buffer        |    |  - Point-in-Time Snapshot     |
|  - Write-Ahead Log (WAL) Durability|    |  - AST Query Compilation      |
|  - Generational Deletion Vectors   |    |  - WAND Early Dynamic Pruning |
|  - Tiered Log-Merge Compaction     |    |  - RRF Hybrid Fusion Scorer   |
|  - 2Q Buffer Pool Page Eviction    |    |  - LTR Two-Stage Reranker     |
+------------------------------------+    +-------------------------------+
       |                                                    |
       +-------------------------+--------------------------+
                                 |
                                 v
+-------------------------------------------------------------------------+
|                             SegmentReader                               |
|  +------------------+  +-------------------+  +----------------------+  |
|  |   FST (.cbl_fst) |  | Postings (.cbl_pos)|  | DocValues (.cbl_dvs) |  |
|  | Prefix / Fuzzy   |  | VByte Leapfrog    |  | Numeric / SortedSet  |  |
|  +------------------+  +-------------------+  +----------------------+  |
|  +------------------+  +-------------------+  +----------------------+  |
|  | Stored (.cbl_fdt)|  | HNSW (.cbl_vec)   |  | Tombs (.cbl_del)     |  |
|  | Block Compressed |  | Cosine / L2 SIMD  |  | RoaringBitmap        |  |
|  +------------------+  +-------------------+  +----------------------+  |
|  +------------------+  +-------------------+  +----------------------+  |
|  | BKD-Tree(.cbl_bkd|  | IVF-PQ (.cbl_ivf) |  | Spans & Phonetics    |  |
|  | Spatial Geodesics|  | Centroid Clusters |  | Soundex / Metaphone  |  |
|  +------------------+  +-------------------+  +----------------------+  |
+-------------------------------------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------------+
|                           Storage Abstraction                           |
|           (RAMDirectory, DiskDirectory, 2Q Buffer Pool Manager)         |
+-------------------------------------------------------------------------+
```

---

## Subsystem Capabilities

### 1. Inverted Index and Term Dictionary
- **Minimal Acyclic FST**: Compiles lexicographically sorted terms into minimal directed acyclic graphs sharing prefixes and suffixes with $O(L)$ exact lookup, $O(P)$ prefix scan, and Levenshtein parametric automata intersection for sub-millisecond fuzzy matching within edit distance 1 or 2.
- **Skip-List Postings Lists**: Encodes delta document gaps and term frequencies via VByte/LEB128 with configurable skip lists (every 16 or 64 documents) allowing sub-linear leapfrog skipping during boolean conjunctions.
- **RoaringBitmap Deletions**: Tracks soft-deleted document IDs across segment lifecycles using hybrid Array/Bitmap/Run containers with $O(1)$ set algebra.

### 2. Columnar DocValues and Aggregations
- **Numeric DocValues**: Single-pass Greatest Common Divisor (GCD) and delta bitpacking for fast range queries and statistics.
- **Sorted Set DocValues**: Categorical multi-valued string ordinals for top-k faceted term aggregations.
- **Streaming Aggregations**:
  - `TermsAggregation`: Top-K categorical frequency estimation using bounded priority queues.
  - `RangeAggregation`: Numeric interval bucketing with open and closed bounds.
  - `DateHistogramAggregation`: Epoch timestamp rounding into interval buckets.
  - `StatsAggregation`: Numerically stable one-pass Welford algorithm computing count, min, max, sum, average, variance, and standard deviation.
  - `TDigest`: Online streaming percentile sketch estimating $p50, p90, p99$ quantiles with bounded memory.

### 3. Vector Retrieval (HNSW & IVF-PQ) and Native SIMD
- **Hierarchical Navigable Small World (HNSW)**: Multi-layer graph topology supporting Cosine Similarity, Squared Euclidean (L2), Dot Product, and Manhattan distance metrics.
- **Inverted File Product Quantization (IVF-PQ)**: Scalable vector indexing using K-Means centroid clustering and residual subvector quantization with Asymmetric Distance Computation (ADC) lookup tables.
- **Vector Quantization**:
  - **SQ8 (Scalar Quantization)**: 8-bit dynamic min-max normalization reducing vector memory footprint by 75%.
  - **Product Quantization (PQ)**: Orthogonal subspace decomposition with ADC distance tables.
- **Native SIMD C Acceleration**: Polyglot C implementation utilizing ARM Neon and x86 AVX2 vector intrinsics via `dart:ffi` with transparent pure Dart fallbacks.

### 4. Spatial Indexing and Geodesics (BKD-Tree)
- **Block KD-Tree (BKD-Tree)**: Multi-dimensional spatial tree splitting points across alternating coordinate axes into leaf blocks (`.cbl_bkd`) for fast bounding box and k-NN search.
- **Geodesic Distance Kernels**: Haversine (spherical) and Vincenty (ellipsoidal WGS-84) distance formulas.
- **Geohash Encoding**: Radix-32 hierarchical spatial index prefixes.
- **Spatial Queries & Aggregations**: `GeoDistanceQuery`, `GeoBoundingBoxQuery` (with antimeridian wrap-around), `GeoPolygonQuery` (ray casting with holes), and `GeoHashGridAggregation`.

### 5. Positional Span Queries
- **Spans Engine**: Full positional tracking supporting `nextDoc()`, `advance()`, and `nextStartPosition()`.
- **Query Types**: `SpanTermQuery`, `SpanNearQuery` (ordered or unordered within slop), `SpanOrQuery`, `SpanNotQuery` (pre and post exclusion windows), and `SpanFirstQuery`.
- **SpanScorer**: Rewards tighter, more compact spans with higher relevance scores.

### 6. Text Analysis and Phonetics
- **Phonetic Encoders**: American Soundex, Lawrence Philips' Metaphone, and Double Metaphone (primary and alternate codes for non-English names).
- **Tokenizers & Filters**: `StandardTokenizer`, `CJKTokenizer` (overlapping bi-grams), `CodeTokenizer` (camelCase and snake_case decomposition), `PorterStemmer`, `SnowballStemmer`, `SynonymFilter`, and `ShingleFilter`.

### 7. Query Engine and Ranking Models
- **Ranking**: Okapi BM25 with term frequency saturation ($k_1$) and field length normalization ($b$); Classic TF-IDF vector space scoring.
- **Custom Function Scoring**: `FieldValueFactorFunction` (log, sqrt, reciprocal modifiers) and `DecayFunction` (Gauss, Exponential, Linear decay curves).
- **Learning to Rank (LTR)**: Two-stage candidate reranking using Gradient Boosted Decision Trees (`GbdtModel`) and linear models (`LinearLtrModel`).
- **Execution Engine**:
  - `QueryOptimizer`: Flattens nested clauses, eliminates redundancies, resolves contradictions, and orders conjunctions by posting list cost.
  - `WandScorer`: Implements Weak AND (WAND) dynamic pruning, computing cumulative upper-bound scores to leapfrog non-competitive documents.
  - `Highlighter`: Extracts relevance-scored text passages with sentence boundary snapping and HTML formatting tags.

### 8. Suggesters and Spell Checking
- **CompletionSuggester**: Fast weighted prefix Trie and fuzzy Levenshtein autocomplete.
- **SymSpell**: Symmetric Delete algorithm for ultra-fast single-word and compound sentence spelling correction.
- **DirectSpellChecker**: Live FST term dictionary query rewriting for "did-you-mean" suggestions without duplicate memory overhead.

### 9. Storage Durability and 2Q Buffer Pool
- **Write-Ahead Log (WAL)**: CRC32C-protected transaction log providing durability and automatic crash recovery replay on restart.
- **Buffer Pool Manager**: Slotted page frames managed by a Two-Queue (2Q) replacement policy that eliminates scan pollution from bulk index operations.

### 10. Distributed Sharding and Raft Consensus
- **ConsistentHashRing**: Murmur3 32-bit consistent hashing with virtual node replication for balanced sharding.
- **ScatterGatherSearcher**: Scatter-gather query distribution, global min-heap top-k merging, and distributed facet consolidation across shards.
- **Raft Consensus & TCP Replication**: Role state machine, leader election, replicated log, and chunked TCP segment synchronization.

### 11. HTTP REST API, Python SDK, and Web Dashboard
- Embedded HTTP REST API compatible with standard search conventions:
  - `GET /_cat/indices`: List collection statistics.
  - `POST /:index/_doc`: Index document.
  - `POST /:index/_search`: Search index.
  - `POST /_bulk`: High-throughput streaming NDJSON ingestion.
  - `GET /_metrics`: Prometheus exposition metrics.
  - `GET /_cluster/health`: Cluster health diagnostics.
  - `GET /_dashboard`: Single-page web console for interactive search exploration and health monitoring.
- Official typed Python SDK with query builders, bulk streaming indexer, and unittest suite.

---

## Benchmarks

Measured on Apple M-Series Silicon (pure Dart JIT/AOT):

| Workload | Metric | Throughput / Latency |
|----------|--------|----------------------|
| Document Ingestion | Raw Batch Throughput | **3,400+ docs/sec** |
| BM25 Term Query | Search Throughput | **28,000+ QPS** |
| HNSW Vector Search (128-dim, k=10) | ANN Query Throughput | **4,200+ QPS** |
| Pairwise Dot Product | SIMD Kernel | **18.5+ Million Ops/sec** |
| Crash Recovery Replay | WAL Processing | **85,000+ records/sec** |

---

## Quickstart

### 1. Run via Dart CLI

```bash
# Clone the repository
git clone https://github.com/Aneesh495/corbel.git
cd corbel

# Fetch dependencies
dart pub get

# Launch interactive REPL console
dart bin/corbel.dart repl

# Or start the HTTP server and dashboard
dart bin/corbel.dart server --port 9200 --dir ./corbel_data
```

Once running, navigate to `http://localhost:9200/_dashboard` in your browser.

---

### 2. Programmatic Usage in Dart

```dart
import 'package:corbel/corbel.dart';

void main() {
  final dir = RAMDirectory();
  final engine = CorbelEngine(baseDirectory: dir);

  final schema = Schema(
    fields: {
      'title': FieldDefinition.text('title'),
      'body': FieldDefinition.text('body'),
      'price': FieldDefinition.int64('price', docValues: true),
    },
  );

  final index = engine.createIndex('products', schema);

  index.index({
    '_id': 'p1',
    'title': 'High performance search engine',
    'body': 'Corbel combines inverted index and vector search in pure Dart.',
    'price': 99,
  });
  index.commit();

  final results = index.search('title:performance AND body:vector', topN: 10);
  for (final hit in results.scoreDocs) {
    print('Hit: \${hit.id} (Score: \${hit.score})');
  }

  engine.close();
}
```

---

### 3. Python SDK Client

```python
from corbel import CorbelClient, Query

client = CorbelClient("http://localhost:9200")

# Index document
client.index("products", {
    "title": "Distributed search engine in Dart",
    "price": 120,
}, doc_id="prod_1")

# Search
results = client.search("products", "title:distributed", size=10)
print(results)
```

---

## Repository Structure

```
corbel/
├── .github/workflows/ci.yml         # GitHub Actions automated test & analysis workflow
├── bin/
│   └── corbel.dart                  # Command-line interface and interactive REPL
├── clients/
│   └── python/                      # Official Python client SDK, bulk helpers, and tests
├── docs/
│   ├── architecture.md              # Deep technical subsystem architecture
│   ├── storage_specification.md     # Bit-level segment file format specifications
│   ├── fst_internals.md             # Finite State Transducer compilation theory
│   └── bug_ledger.md                # Regression bug ledger and reproductions
├── native/
│   ├── CMakeLists.txt               # Native SIMD build configuration
│   ├── include/corbel_simd.h        # C SIMD vector kernel headers
│   └── src/corbel_simd.c            # ARM Neon and AVX2 vector implementations
├── tool/
│   └── audit_em_dashes.py           # Automated em-dash and en-dash static validator
├── lib/
│   ├── corbel.dart                  # Root library export
│   └── src/
│       ├── aggregation/             # Columnar facet aggregations & T-Digest
│       ├── analysis/                # Tokenizers, stemmers, and Double Metaphone
│       ├── cluster/                 # Raft consensus, TCP replication, and sharding
│       ├── concurrency/             # Isolate worker pool for multi-core search
│       ├── core/                    # Document model, field types, and schema
│       ├── engine/                  # IndexWriter, IndexSearcher, and CorbelEngine
│       ├── index/                   # FST, Postings, DocValues, and Compaction
│       ├── native/                  # Dart FFI bindings for C SIMD acceleration
│       ├── query/                   # BM25, Spans, WAND, FunctionScore, and LTR
│       ├── server/                  # HTTP REST server, Bulk NDJSON, Dashboard
│       ├── spatial/                 # BKD-Tree, Geohash, Haversine, and Vincenty
│       ├── storage/                 # 2Q Buffer Pool, Codecs, RoaringBitmap, WAL
│       ├── suggest/                 # SymSpell, Direct FST, and Weighted Trie
│       └── vector/                  # HNSW graph, IVF-PQ, K-Means, and SQ8/PQ
├── bench/                           # Micro-benchmark suites (Indexing, Search, Vectors)
└── test/                            # Comprehensive unit, bug, and integration tests
```

---

## Verification and Testing

```bash
# Run all unit, regression, and integration tests
dart test

# Run static analysis
dart analyze --fatal-infos
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
