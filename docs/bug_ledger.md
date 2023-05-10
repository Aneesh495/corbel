# Corbel Bug Ledger and Regression Tracking

This ledger documents internal bugs uncovered during development, including their root causes, mechanical reproductions, resolutions, and permanent regression test suites.

---

### Bug 00: BitVector Trailing Zeros Bit-Shift Sign Corruption
- **Component**: `lib/src/utils/bit_vector.dart`
- **Symptom**: `BitVector.nextSetBit` returned an erroneous bit index (12 instead of 10) on 64-bit integer masks.
- **Root Cause**: Dart represents integers as 64-bit two's complement. The lowest-bit isolation expression `i & -i` triggered integer sign overflow when `i` equaled `-9223372036854775808` (`0x8000000000000000`), corrupting the bit length calculation in `_numberOfTrailingZeros64`.
- **Resolution**: Added explicit 64-bit sign guard and optimized lowest-bit isolation: `if (val == -9223372036854775808) return 63; return (val & -val).bitLength - 1;`.
- **Regression Test**: `test/bugs/bug_00_bit_vector_trailing_zeros_test.dart`

---

### Bug 01: WriteAheadLog Header Overwrite on Multi-Session Reopen
- **Component**: `lib/src/storage/wal.dart`
- **Symptom**: `WriteAheadLog.recover()` returned 0 entries after appending records and reopening the log.
- **Root Cause**: `WriteAheadLog.open()` invoked `directory.createOutput()` unconditionally, which truncates the underlying file to 0 bytes and overwrote the magic header and prior records.
- **Resolution**: Updated `open()` to verify whether the log file already exists in `Directory`. If existing, preserve prior byte length and open in append mode; only write the 8-byte magic header when creating a fresh log file.
- **Regression Test**: `test/bugs/bug_01_wal_overwrite_header_test.dart`

---

### Bug 02: CJKTokenizer Trailing Redundant Unigram Generation
- **Component**: `lib/src/analysis/tokenizers/cjk_tokenizer.dart`
- **Symptom**: In multi-character CJK character sequences, the final character was emitted both as the second half of a bi-gram and as an isolated unigram.
- **Root Cause**: Missing boundary condition check when concluding a contiguous CJK run.
- **Resolution**: Added condition to only emit single-character unigrams when the character is standalone (surrounded by non-CJK characters or at text boundaries).
- **Regression Test**: `test/bugs/bug_02_cjk_unigram_redundancy_test.dart`

---

### Bug 03: HNSW Missing Adjacency Map on Layer Promotion
- **Component**: `lib/src/vector/hnsw_graph.dart`
- **Symptom**: `Null check operator used on a null value` at `_layers[l][docId]!` when inserting nodes whose randomly sampled layer exceeded the current `_maxLayer`.
- **Root Cause**: When a newly inserted node became the new graph entry point, `_layers` grew to `level`, but intermediate layer maps between `_maxLayer + 1` and `level` did not have empty adjacency lists initialized for `docId`.
- **Resolution**: Explicitly populated `_layers[l][docId] = []` for all layers from 0 to `level` before updating `_maxLayer` and `_entryPoint`.
- **Regression Test**: `test/bugs/bug_03_hnsw_level_promotion_test.dart`

---

### Bug 04: KnnVectorScorer NeighborPair Distance Attribute Access
- **Component**: `lib/src/query/knn_vector_query.dart`
- **Symptom**: `NoSuchMethodError: Class 'NeighborPair' has no instance getter 'similarity'` during hybrid query execution.
- **Root Cause**: `KnnVectorScorer.score()` assumed elements returned by `VectorIndex.search()` had a `.similarity` field, whereas `NeighborPair` stores `.distance`.
- **Resolution**: Computed bounded similarity score dynamically from distance: `final sim = 1.0 / (1.0 + dist)`.
- **Regression Test**: `test/bugs/bug_04_knn_scorer_neighbor_pair_test.dart`
