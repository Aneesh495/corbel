import 'dart:convert';
import 'dart:typed_data';
import '../spatial/geo_point.dart';
import 'schema.dart';

/// Single typed field within a document.
class Field {
  /// Name of the field.
  final String name;

  /// Field data type.
  final FieldType type;

  /// Stored raw value.
  final Object? value;

  /// Boost factor applied to this field during inverted indexing.
  final double boost;

  /// Creates a typed field.
  const Field({
    required this.name,
    required this.type,
    required this.value,
    this.boost = 1.0,
  });

  /// Factory helper for text field.
  factory Field.text(String name, String value, {double boost = 1.0}) {
    return Field(
        name: name, type: FieldType.text, value: value, boost: boost);
  }

  /// Factory helper for keyword string field.
  factory Field.string(String name, String value) {
    return Field(name: name, type: FieldType.string, value: value);
  }

  /// Factory helper for 64-bit integer field.
  factory Field.int64(String name, int value) {
    return Field(name: name, type: FieldType.int64, value: value);
  }

  /// Factory helper for 64-bit float field.
  factory Field.float64(String name, double value) {
    return Field(name: name, type: FieldType.float64, value: value);
  }

  /// Factory helper for boolean field.
  factory Field.boolean(String name, bool value) {
    return Field(name: name, type: FieldType.boolean, value: value);
  }

  /// Factory helper for date millisecond timestamp field.
  factory Field.date(String name, int epochMs) {
    return Field(name: name, type: FieldType.date, value: epochMs);
  }

  /// Factory helper for dense vector field.
  factory Field.vector(String name, Float32List vector) {
    return Field(name: name, type: FieldType.vector, value: vector);
  }

  /// Factory helper for raw binary field.
  factory Field.binary(String name, Uint8List bytes) {
    return Field(name: name, type: FieldType.binary, value: bytes);
  }

  /// Factory helper for geographic coordinate field.
  factory Field.geoPoint(String name, GeoPoint point) {
    return Field(name: name, type: FieldType.geoPoint, value: point);
  }

  /// Factory helper for JSON field.
  factory Field.json(String name, Object jsonObject) {
    return Field(name: name, type: FieldType.json, value: jsonObject);
  }

  /// String value representation.
  String? get stringValue => value?.toString();

  /// Int value representation.
  int? get intValue => value is int ? value as int : null;

  /// Double value representation.
  double? get doubleValue =>
      value is num ? (value as num).toDouble() : null;

  /// Vector value representation.
  Float32List? get vectorValue {
    if (value is Float32List) return value as Float32List;
    if (value is List<double>) {
      return Float32List.fromList(value as List<double>);
    }
    if (value is List<num>) {
      return Float32List.fromList(
          (value as List<num>).map((e) => e.toDouble()).toList());
    }
    return null;
  }

  /// Binary byte value representation.
  Uint8List? get binaryValue {
    if (value is Uint8List) return value as Uint8List;
    if (value is List<int>) return Uint8List.fromList(value as List<int>);
    return null;
  }

  /// Geographic coordinate value representation.
  GeoPoint? get geoPointValue {
    if (value is GeoPoint) return value as GeoPoint;
    if (value is Map<String, dynamic>) {
      return GeoPoint.fromJson(value as Map<String, dynamic>);
    }
    return null;
  }

  @override
  String toString() => 'Field(name: $name, type: ${type.name}, value: $value)';
}

/// In-memory document containing a unique identifier and a collection of fields.
class Document {
  /// Unique document identifier.
  final String id;

  /// List of fields associated with this document.
  final List<Field> fields;

  /// Fast lookup cache for fields by name.
  final Map<String, Field> _fieldMap;

  /// Constructs an in-memory document.
  Document({
    required this.id,
    List<Field>? fields,
  })  : fields = List.unmodifiable(fields ?? const []),
        _fieldMap = {
          for (final f in fields ?? const <Field>[]) f.name: f,
        };

  /// Constructs a document directly from raw map data and an optional schema.
  factory Document.fromMap(
    String id,
    Map<String, dynamic> data, {
    Schema? schema,
  }) {
    if (schema != null) {
      schema.validate(data);
    }

    final fields = <Field>[];
    for (final entry in data.entries) {
      final name = entry.key;
      final val = entry.value;
      if (val == null) continue;

      final fieldDef = schema?.getField(name);
      final FieldType type;
      if (fieldDef != null) {
        type = fieldDef.type;
      } else {
        // Infer field type dynamically
        if (val is int) {
          type = FieldType.int64;
        } else if (val is double) {
          type = FieldType.float64;
        } else if (val is bool) {
          type = FieldType.boolean;
        } else if (val is Float32List ||
            (val is List && val.isNotEmpty && val.first is double)) {
          type = FieldType.vector;
        } else if (val is Uint8List) {
          type = FieldType.binary;
        } else if (val is Map || val is List) {
          type = FieldType.json;
        } else {
          type = FieldType.text;
        }
      }

      switch (type) {
        case FieldType.text:
          fields.add(Field.text(name, val.toString()));
          break;
        case FieldType.string:
          fields.add(Field.string(name, val.toString()));
          break;
        case FieldType.int64:
        case FieldType.date:
          fields.add(Field(name: name, type: type, value: val as int));
          break;
        case FieldType.float64:
          fields.add(Field.float64(name, (val as num).toDouble()));
          break;
        case FieldType.boolean:
          fields.add(Field.boolean(name, val as bool));
          break;
        case FieldType.vector:
          final Float32List vec;
          if (val is Float32List) {
            vec = val;
          } else {
            final list = val as List<dynamic>;
            vec = Float32List.fromList(
                list.map((e) => (e as num).toDouble()).toList());
          }
          fields.add(Field.vector(name, vec));
          break;
        case FieldType.binary:
          fields.add(Field.binary(
              name,
              val is Uint8List
                  ? val
                  : Uint8List.fromList(val as List<int>)));
          break;
        case FieldType.json:
          fields.add(Field.json(name, val as Object));
          break;
        case FieldType.geoPoint:
          if (val is GeoPoint) {
            fields.add(Field.geoPoint(name, val));
          } else if (val is Map<String, dynamic>) {
            fields.add(Field.geoPoint(name, GeoPoint.fromJson(val)));
          } else if (val is Map) {
            fields.add(Field.geoPoint(
                name, GeoPoint.fromJson(Map<String, dynamic>.from(val))));
          }
          break;
      }
    }

    return Document(id: id, fields: fields);
  }

  /// Retrieves field by name.
  Field? getField(String name) => _fieldMap[name];

  /// Retrieves text or string value for field.
  String? getString(String name) => _fieldMap[name]?.stringValue;

  /// Retrieves integer value for field.
  int? getInt(String name) => _fieldMap[name]?.intValue;

  /// Retrieves double value for field.
  double? getDouble(String name) => _fieldMap[name]?.doubleValue;

  /// Retrieves vector value for field.
  Float32List? getVector(String name) => _fieldMap[name]?.vectorValue;

  /// Retrieves geographic coordinate value for field.
  GeoPoint? getGeoPoint(String name) => _fieldMap[name]?.geoPointValue;

  /// Retrieves binary value for field.
  Uint8List? getBinary(String name) => _fieldMap[name]?.binaryValue;

  /// Converts stored document fields back to a map representation.
  Map<String, dynamic> toMap() {
    final map = <String, dynamic>{'_id': id};
    for (final field in fields) {
      if (field.value is Float32List) {
        map[field.name] = (field.value as Float32List).toList();
      } else if (field.value is Uint8List) {
        map[field.name] = base64Encode(field.value as Uint8List);
      } else {
        map[field.name] = field.value;
      }
    }
    return map;
  }

  @override
  String toString() => 'Document(id: $id, fields: ${fields.length})';
}
