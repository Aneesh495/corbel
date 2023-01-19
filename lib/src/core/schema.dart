/// Defines field types, indexing configurations, and schema rules for Corbel documents.
library;

/// Supported field types within the engine.
enum FieldType {
  /// Analyzed full-text field supporting inverted indexing, phrase matching, and positions.
  text,

  /// Exact-match keyword field without tokenization (case-preserved or normalized).
  string,

  /// Signed 64-bit integer, optimized for fast columnar range queries and sorting.
  int64,

  /// Double precision 64-bit IEEE 754 float, supporting numeric DocValues.
  float64,

  /// Boolean flag stored as compact bit.
  boolean,

  /// Epoch millisecond timestamp, supporting date histograms and range queries.
  date,

  /// High-dimensional dense float vector for approximate nearest neighbor search.
  vector,

  /// Raw byte buffer stored without inverted indexing.
  binary,

  /// Semi-structured JSON object stored as string or payload.
  json,
}

/// Level of inverted index detail captured for a given field.
enum IndexOptions {
  /// Field is not indexed in the inverted index.
  none,

  /// Only document IDs are indexed (presence/match only).
  docs,

  /// Document IDs and term frequencies are indexed (supports BM25 scoring).
  docsAndFreqs,

  /// Document IDs, term frequencies, and token positions are indexed (supports phrase queries).
  docsAndFreqsAndPositions,

  /// Document IDs, term frequencies, positions, and character offsets (supports highlighting).
  docsAndFreqsAndPositionsAndOffsets,
}

/// Storage layout for columnar DocValues.
enum DocValuesType {
  /// No DocValues generated for this field.
  none,

  /// Single 64-bit integer or double per document, supporting fast aggregations and sorting.
  numeric,

  /// Variable-length byte sequence per document.
  binary,

  /// Multi-valued set of string ordinals per document for facet aggregations.
  sortedSet,
}

/// Vector distance metric configured for dense vector fields.
enum VectorDistanceMetric {
  /// Squared Euclidean distance (L2 norm).
  l2,

  /// Cosine similarity: normalized inner product between vectors.
  cosine,

  /// Unnormalized dot product: optimal when vectors are pre-normalized to unit sphere.
  dotProduct,

  /// Manhattan distance (L1 norm).
  manhattan,
}

/// Specification for a single field in a document schema.
class FieldDefinition {
  /// Name of the field.
  final String name;

  /// Underlying data type of the field.
  final FieldType type;

  /// Level of inverted indexing enabled for this field.
  final IndexOptions indexOptions;

  /// Whether raw field contents are stored in the block-compressed stored fields.
  final bool stored;

  /// Type of columnar DocValues generated for sorting and aggregations.
  final DocValuesType docValuesType;

  /// Name of the text analyzer associated with text fields (e.g., 'standard', 'english', 'code').
  final String? analyzer;

  /// Dimensionality for vector fields (required when type is FieldType.vector).
  final int? vectorDimension;

  /// Distance metric for vector fields (defaults to cosine).
  final VectorDistanceMetric vectorMetric;

  /// Fast constructor for field definitions.
  const FieldDefinition({
    required this.name,
    required this.type,
    this.indexOptions = IndexOptions.docsAndFreqs,
    this.stored = true,
    this.docValuesType = DocValuesType.none,
    this.analyzer,
    this.vectorDimension,
    this.vectorMetric = VectorDistanceMetric.cosine,
  });

  /// Factory helper for creating full-text fields.
  factory FieldDefinition.text(
    String name, {
    bool stored = true,
    String analyzer = 'standard',
    bool withPositions = true,
    bool withOffsets = true,
  }) {
    final IndexOptions options;
    if (withOffsets) {
      options = IndexOptions.docsAndFreqsAndPositionsAndOffsets;
    } else if (withPositions) {
      options = IndexOptions.docsAndFreqsAndPositions;
    } else {
      options = IndexOptions.docsAndFreqs;
    }

    return FieldDefinition(
      name: name,
      type: FieldType.text,
      indexOptions: options,
      stored: stored,
      docValuesType: DocValuesType.none,
      analyzer: analyzer,
    );
  }

  /// Factory helper for creating keyword string fields.
  factory FieldDefinition.string(
    String name, {
    bool stored = true,
    bool indexed = true,
    bool docValues = true,
  }) {
    return FieldDefinition(
      name: name,
      type: FieldType.string,
      indexOptions: indexed ? IndexOptions.docs : IndexOptions.none,
      stored: stored,
      docValuesType: docValues ? DocValuesType.sortedSet : DocValuesType.none,
    );
  }

  /// Factory helper for creating 64-bit integer fields with numeric DocValues.
  factory FieldDefinition.int64(
    String name, {
    bool stored = true,
    bool indexed = true,
    bool docValues = true,
  }) {
    return FieldDefinition(
      name: name,
      type: FieldType.int64,
      indexOptions: indexed ? IndexOptions.docs : IndexOptions.none,
      stored: stored,
      docValuesType: docValues ? DocValuesType.numeric : DocValuesType.none,
    );
  }

  /// Factory helper for creating 64-bit float fields with numeric DocValues.
  factory FieldDefinition.float64(
    String name, {
    bool stored = true,
    bool indexed = true,
    bool docValues = true,
  }) {
    return FieldDefinition(
      name: name,
      type: FieldType.float64,
      indexOptions: indexed ? IndexOptions.docs : IndexOptions.none,
      stored: stored,
      docValuesType: docValues ? DocValuesType.numeric : DocValuesType.none,
    );
  }

  /// Factory helper for dense vector fields.
  factory FieldDefinition.vector(
    String name, {
    required int dimension,
    VectorDistanceMetric metric = VectorDistanceMetric.cosine,
    bool stored = true,
  }) {
    return FieldDefinition(
      name: name,
      type: FieldType.vector,
      indexOptions: IndexOptions.none,
      stored: stored,
      docValuesType: DocValuesType.binary,
      vectorDimension: dimension,
      vectorMetric: metric,
    );
  }

  /// Checks whether inverted indexing is enabled.
  bool get isIndexed => indexOptions != IndexOptions.none;

  /// Checks whether token positions are recorded.
  bool get hasPositions =>
      indexOptions == IndexOptions.docsAndFreqsAndPositions ||
      indexOptions == IndexOptions.docsAndFreqsAndPositionsAndOffsets;

  /// Checks whether character offsets are recorded.
  bool get hasOffsets =>
      indexOptions == IndexOptions.docsAndFreqsAndPositionsAndOffsets;

  /// Checks whether term frequencies are recorded.
  bool get hasFreqs =>
      indexOptions != IndexOptions.none && indexOptions != IndexOptions.docs;

  /// Checks whether DocValues are enabled.
  bool get hasDocValues => docValuesType != DocValuesType.none;

  /// Converts field definition to JSON map.
  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type.name,
        'index_options': indexOptions.name,
        'stored': stored,
        'doc_values_type': docValuesType.name,
        if (analyzer != null) 'analyzer': analyzer,
        if (vectorDimension != null) 'vector_dimension': vectorDimension,
        'vector_metric': vectorMetric.name,
      };

  /// Parses field definition from JSON map.
  factory FieldDefinition.fromJson(Map<String, dynamic> json) {
    return FieldDefinition(
      name: json['name'] as String,
      type: FieldType.values.byName(json['type'] as String),
      indexOptions: json.containsKey('index_options')
          ? IndexOptions.values.byName(json['index_options'] as String)
          : IndexOptions.docsAndFreqs,
      stored: json['stored'] as bool? ?? true,
      docValuesType: json.containsKey('doc_values_type')
          ? DocValuesType.values.byName(json['doc_values_type'] as String)
          : DocValuesType.none,
      analyzer: json['analyzer'] as String?,
      vectorDimension: json['vector_dimension'] as int?,
      vectorMetric: json.containsKey('vector_metric')
          ? VectorDistanceMetric.values
              .byName(json['vector_metric'] as String)
          : VectorDistanceMetric.cosine,
    );
  }
}

/// Immutable schema defining the complete field topology of an index.
class Schema {
  /// Name of the primary identifier field.
  final String idFieldName;

  /// Registered field definitions mapped by field name.
  final Map<String, FieldDefinition> fields;

  /// Constructs a schema with mandatory ID field and custom fields.
  Schema({
    this.idFieldName = '_id',
    Map<String, FieldDefinition>? fields,
  }) : fields = Map.unmodifiable({
          idFieldName: FieldDefinition.string(idFieldName,
              stored: true, indexed: true, docValues: true),
          ...?fields,
        });

  /// Retrieves field definition by name.
  FieldDefinition? getField(String name) => fields[name];

  /// Checks if field is registered in this schema.
  bool containsField(String name) => fields.containsKey(name);

  /// Validates a map of field values against this schema.
  void validate(Map<String, dynamic> documentData) {
    for (final entry in documentData.entries) {
      final fieldDef = fields[entry.key];
      if (fieldDef == null) {
        // Unknown field: permitted for dynamic payloads if stored, but flagged.
        continue;
      }
      final value = entry.value;
      if (value == null) continue;

      switch (fieldDef.type) {
        case FieldType.text:
        case FieldType.string:
          if (value is! String && value is! List<String>) {
            throw ArgumentError(
                "Field '${entry.key}' expects String or List<String>, got ${value.runtimeType}");
          }
          break;
        case FieldType.int64:
        case FieldType.date:
          if (value is! int) {
            throw ArgumentError(
                "Field '${entry.key}' expects int, got ${value.runtimeType}");
          }
          break;
        case FieldType.float64:
          if (value is! num) {
            throw ArgumentError(
                "Field '${entry.key}' expects num, got ${value.runtimeType}");
          }
          break;
        case FieldType.boolean:
          if (value is! bool) {
            throw ArgumentError(
                "Field '${entry.key}' expects bool, got ${value.runtimeType}");
          }
          break;
        case FieldType.vector:
          if (value is! List<double> && value is! List<num>) {
            throw ArgumentError(
                "Field '${entry.key}' expects List<double>, got ${value.runtimeType}");
          }
          final list = value as List<dynamic>;
          if (fieldDef.vectorDimension != null &&
              list.length != fieldDef.vectorDimension) {
            throw ArgumentError(
                "Field '${entry.key}' dimension mismatch: expected ${fieldDef.vectorDimension}, got ${list.length}");
          }
          break;
        case FieldType.binary:
        case FieldType.json:
          break;
      }
    }
  }

  /// Converts schema to JSON map.
  Map<String, dynamic> toJson() => {
        'id_field_name': idFieldName,
        'fields': fields.map((k, v) => MapEntry(k, v.toJson())),
      };

  /// Parses schema from JSON map.
  factory Schema.fromJson(Map<String, dynamic> json) {
    final idField = json['id_field_name'] as String? ?? '_id';
    final fieldsRaw = json['fields'] as Map<String, dynamic>? ?? {};
    final parsedFields = <String, FieldDefinition>{};
    for (final entry in fieldsRaw.entries) {
      parsedFields[entry.key] =
          FieldDefinition.fromJson(entry.value as Map<String, dynamic>);
    }
    return Schema(
      idFieldName: idField,
      fields: parsedFields,
    );
  }
}
