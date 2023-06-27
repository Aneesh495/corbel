import 'dart:math' as math;
import '../../index/segment_reader.dart';

/// Modifier applied to raw numeric field values in FieldValueFactor.
enum Modifier {
  none,
  log,
  log1p,
  log2p,
  ln,
  ln1p,
  ln2p,
  square,
  sqrt,
  reciprocal,
}

/// Abstract function calculating score modifiers for documents.
abstract class ScoreFunction {
  double score(SegmentReader segmentReader, int docId, double subQueryScore);
}

/// Boosts documents based on a numeric field's value (e.g. popularity, view count, votes).
class FieldValueFactorFunction extends ScoreFunction {
  final String field;
  final double factor;
  final Modifier modifier;
  final double missing;

  FieldValueFactorFunction({
    required this.field,
    this.factor = 1.0,
    this.modifier = Modifier.none,
    this.missing = 1.0,
  });

  @override
  double score(SegmentReader segmentReader, int docId, double subQueryScore) {
    var rawValue = missing;
    final ndv = segmentReader.getNumericDocValues(field);
    if (ndv != null) {
      rawValue = ndv.get(docId).toDouble();
    } else {
      try {
        final doc = segmentReader.document(docId);
        final val = doc[field];
        if (val is num) rawValue = val.toDouble();
      } catch (_) {}
    }

    final val = rawValue * factor;
    switch (modifier) {
      case Modifier.none:
        return val;
      case Modifier.log:
        return val > 0 ? math.log(val) / math.ln10 : 0.0;
      case Modifier.log1p:
        return val + 1.0 > 0 ? math.log(val + 1.0) / math.ln10 : 0.0;
      case Modifier.log2p:
        return val + 2.0 > 0 ? math.log(val + 2.0) / math.ln10 : 0.0;
      case Modifier.ln:
        return val > 0 ? math.log(val) : 0.0;
      case Modifier.ln1p:
        return val + 1.0 > 0 ? math.log(val + 1.0) : 0.0;
      case Modifier.ln2p:
        return val + 2.0 > 0 ? math.log(val + 2.0) : 0.0;
      case Modifier.square:
        return val * val;
      case Modifier.sqrt:
        return val >= 0 ? math.sqrt(val) : 0.0;
      case Modifier.reciprocal:
        return val != 0 ? 1.0 / val : 0.0;
    }
  }
}

/// Supported decay curve formulas.
enum DecayType {
  gauss,
  exponential,
  linear,
}

/// Decays document relevance score as a function of distance from an ideal [origin].
/// Commonly used for recency decay (dates), price affinity, and spatial distance.
class DecayFunction extends ScoreFunction {
  final String field;
  final double origin;
  final double scale;
  final double offset;
  final double decay;
  final DecayType decayType;

  DecayFunction({
    required this.field,
    required this.origin,
    required this.scale,
    this.offset = 0.0,
    this.decay = 0.5,
    this.decayType = DecayType.gauss,
  }) : assert(scale > 0, 'Scale must be strictly positive'),
       assert(decay > 0 && decay < 1.0, 'Decay rate must be between 0 and 1');

  @override
  double score(SegmentReader segmentReader, int docId, double subQueryScore) {
    var docVal = origin;
    final ndv = segmentReader.getNumericDocValues(field);
    if (ndv != null) {
      docVal = ndv.get(docId).toDouble();
    } else {
      try {
        final doc = segmentReader.document(docId);
        final val = doc[field];
        if (val is num) docVal = val.toDouble();
      } catch (_) {}
    }

    final rawDistance = (docVal - origin).abs();
    final distance = math.max(0.0, rawDistance - offset);

    if (distance == 0.0) return 1.0;

    switch (decayType) {
      case DecayType.gauss:
        // sigma = -scale^2 / (2 * ln(decay))
        final sigmaSq = -scale * scale / (2.0 * math.log(decay));
        return math.exp(-distance * distance / (2.0 * sigmaSq));

      case DecayType.exponential:
        // lambda = ln(decay) / scale
        final lambda = math.log(decay) / scale;
        return math.exp(lambda * distance);

      case DecayType.linear:
        // s = (1 - decay) / scale
        final slope = (1.0 - decay) / scale;
        return math.max(0.0, 1.0 - slope * distance);
    }
  }
}

/// Constant weight multiplier score function.
class WeightScoreFunction extends ScoreFunction {
  final double weight;

  WeightScoreFunction(this.weight);

  @override
  double score(SegmentReader segmentReader, int docId, double subQueryScore) =>
      weight;
}
