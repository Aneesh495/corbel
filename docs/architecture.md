# Corbel Architecture and Subsystem Internals

Corbel is a high-throughput, embedded search and vector-relational retrieval engine written in Dart with C SIMD native acceleration. It combines Lucene-style inverted indexes, finite state transducers (FST), columnar doc values, roaring bitmaps, and Hierarchical Navigable Small World (HNSW) vector graphs into a unified runtime.

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
+-------------------------------------------------------------------------+
                                 |
                                 v
+-------------------------------------------------------------------------+
|                           Storage Abstraction                           |
|               (RAMDirectory, DiskDirectory, Memory Mapped)              |
+-------------------------------------------------------------------------+
```

---

## 1. Storage and Encoding Engine

Corbel decouples high-level retrieval from file I/O via the `Directory` abstraction:
- **`RAMDirectory`**: Zero-allocation in-memory byte buffer directory, optimal for unit tests, ephemeral caches, and ultra-low latency testing.
- **`DiskDirectory`**: Direct persistent storage leveraging random access file pointers with CRC32C checksum integrity guards on every frame.

### Integer Compression Codecs
1. **VByte / LEB128**: Variable-length integer encoding where the lowest 7 bits of each byte store payload data, and the most significant bit (MSB) acts as a continuation flag.
2. **Frame of Reference (FoR)**: Packs fixed-width blocks of 128 integers by computing block minima and bit-packing residuals into tight bit-widths.
3. **Elias-Fano Quasi-Succinct Monotone Encoding**: Compresses sorted monotonically increasing sequences (such as posting list document IDs) using high-bit unary representations paired with low-bit dense bit-vectors.
4. **Roaring Bitmaps**: Hybrid bitmap container layout featuring `ArrayContainer` (for sparse data, < 4096 elements), `BitmapContainer` (fixed 8 KB dense bitset), and `RunContainer` (run-length encoded intervals), enabling $O(1)$ set intersection and union operations for soft deletions.

---

## 2. Text Analysis Pipeline

Corbel features an extensible token analysis engine:
- **Tokenizers**:
  - `StandardTokenizer`: Unicode punctuation boundary decomposition.
  - `WhitespaceTokenizer`: Simple space/tab/newline token emission.
  - `PatternTokenizer`: Custom regular expression boundary splitting.
  - `NGramTokenizer`: Sliding character n-gram window generation for substring matching.
  - `CJKTokenizer`: Overlapping bi-gram synthesis for East Asian scripts (Chinese, Japanese, Korean).
  - `CodeTokenizer`: Source code token extraction with camelCase, PascalCase, and snake_case identifier decomposition.
- **Token Filters**:
  - `LowerCaseFilter`, `AsciiFoldingFilter` (diacritics removal).
  - `StopFilter` (common stop-word elimination).
  - `PorterStemmer` and `SnowballStemmer` (algorithmic morphological suffix reduction).
  - `SynonymFilter` (multi-word synonym expansion at index and query time).
  - `ShingleFilter` (adjacent word n-gram combination for phrase indexing).

---

## 3. Inverted Index and Term Dictionary

Each immutable segment is organized into specialized index components:
- **Finite State Transducers (FST)**: Minimal acyclic directed automata storing terms with suffix sharing and output accumulation. Supports exact match in $O(L)$, prefix traversal in $O(P)$, and Levenshtein fuzzy expansion within edit distance 1 or 2.
- **Postings Lists with Leapfrog Skip Lists**: Stores doc delta gaps, term frequencies, token positions, and character offsets. Skip entries placed every 16 or 64 documents enable sub-linear leapfrog skipping during conjunctions.
- **Columnar DocValues**:
  - `NumericDocValues`: Single-valued integers compressed via delta and Greatest Common Divisor (GCD) bitpacking.
  - `BinaryDocValues`: Variable-length byte arrays with contiguous prefix offset tables.
  - `SortedSetDocValues`: Multi-valued categorical strings with global segment dictionaries and compact ordinal arrays for facet aggregations.
- **Stored Fields**: Block-compressed document storage grouping documents into 64-record chunks with direct index offsets.

---

## 4. Vector Retrieval and HNSW Graph

Approximate nearest neighbor (ANN) search is powered by Hierarchical Navigable Small World (HNSW) graphs:
- Multi-layer graph topology where top layers contain long-range highway links and layer 0 contains all indexed vectors.
- Distance kernels supporting Cosine Similarity, Squared Euclidean (L2), Dot Product, and Manhattan metrics.
- Vector Quantization:
  - **Scalar Quantization (SQ8)**: Compresses 32-bit floats into 8-bit integers via dynamic min-max normalization, reducing memory footprint by 75% with minimal recall degradation.
  - **Product Quantization (PQ)**: Decomposes high-dimensional vectors into $m$ orthogonal subspaces with k-means centroids and asymmetric distance computation (ADC).
- Native SIMD C Acceleration: Binds ARM Neon and x86 AVX2 vector instructions via `dart:ffi`.

---

## 5. Query Engine and Ranking Models

- **Ranking Models**:
  - Okapi BM25: Non-linear term frequency saturation ($k_1$) and document length normalization ($b$).
  - Classic TF-IDF: Vector space model with square root term frequency and length normalization.
- **AST Query Hierarchy**:
  - `TermQuery`, `PhraseQuery` (with configurable slop tolerance), `PrefixQuery`, `WildcardQuery`, `FuzzyQuery`.
  - `NumericRangeQuery`, `TermRangeQuery`.
  - `BooleanQuery` with MUST (conjunction), SHOULD (disjunction), MUST_NOT (exclusion), and FILTER (unscored caching) coordination.
  - `DisjunctionMaxQuery` (DisMax) with configurable tie-breaker multiplier.
  - `KnnVectorQuery` with pre-filtering predicates.
  - `HybridQuery` uniting lexical keyword retrieval and vector search via Reciprocal Rank Fusion (RRF) and linear score interpolation.
- **Optimizations**:
  - `QueryOptimizer`: Rewrites nested AST structures, flattens boolean clauses, resolves contradictions, and orders conjunctions by posting list cost.
  - `WandScorer`: Implements Weak AND (WAND) dynamic pruning, computing cumulative upper-bound scores to leapfrog non-competitive documents.

---

## 6. Concurrency and Snapshot Isolation

- **Point-in-Time Reader Snapshots**: `IndexSnapshot` freezes an immutable view of segment readers and deletion vectors. Concurrent writes and flushes proceed independently without blocking active queries.
- **IsolateWorkerPool**: Fan-out query execution across background Dart Isolates, utilizing multi-core parallelism for heavy vector distance evaluations and multi-segment scans.
- **Tiered Merge Compactor**: Log-structured background merge worker consolidating small segment tiers into unified segments while physically purging soft-deleted tombstones.

---

## 7. Distributed Consensus and Clustering

- **Raft Consensus Engine**: Implements the Raft distributed consensus protocol:
  - Role state machine: Follower, Candidate, Leader.
  - Randomized election timers and heartbeat maintenance.
  - Replicated transaction log with commit index advancement and quorum verification.
- **TCP Segment Streaming**: Replicates immutable segment files across cluster nodes over binary TCP streams with streaming CRC32C verification and resumable chunking.
