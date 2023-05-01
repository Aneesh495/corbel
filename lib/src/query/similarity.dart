import 'dart:math' as math;
import 'explanation.dart';

/// Abstract contract for scoring ranking models.
abstract class Similarity {
  const Similarity();

  /// Calculates inverse document frequency (IDF).
  double computeIdf(int docFreq, int totalDocs);

  /// Computes final relevance score for a matching term occurrence.
  double score({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  });

  /// Explains score breakdown for diagnostics and explain plans.
  Explanation explain({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  });
}

/// Okapi BM25 probabilistic relevance model with non-linear term frequency saturation.
class BM25Similarity extends Similarity {
  /// Term frequency saturation parameter (standard range: 1.2 to 2.0).
  final double k1;

  /// Document length normalization parameter (standard range: 0.5 to 0.8).
  final double b;

  const BM25Similarity({
    this.k1 = 1.2,
    this.b = 0.75,
  })  : assert(k1 >= 0.0, 'k1 must be non-negative'),
        assert(b >= 0.0 && b <= 1.0, 'b must be between 0.0 and 1.0');

  @override
  double computeIdf(int docFreq, int totalDocs) {
    if (totalDocs <= 0) return 0.0;
    // Robertson-Spärck Jones formulation with smoothing
    final num = totalDocs - docFreq + 0.5;
    final den = docFreq + 0.5;
    return math.max(0.0, math.log(1.0 + (num / den)));
  }

  @override
  double score({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  }) {
    if (freq <= 0.0) return 0.0;

    final norm = avgDocLength > 0.0 ? docLength / avgDocLength : 1.0;
    final tf = (freq * (k1 + 1.0)) / (freq + k1 * (1.0 - b + b * norm));
    return idf * tf;
  }

  @override
  Explanation explain({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  }) {
    final norm = avgDocLength > 0.0 ? docLength / avgDocLength : 1.0;
    final tfDenominator = freq + k1 * (1.0 - b + b * norm);
    final tf = (freq * (k1 + 1.0)) / tfDenominator;
    final finalScore = idf * tf;

    return Explanation.match(
      finalScore,
      'BM25 score (k1=$k1, b=$b)',
      [
        Explanation.match(idf, 'idf, computed as log(1 + (N - n + 0.5) / (n + 0.5))'),
        Explanation.match(
          tf,
          'tf, computed as (freq * (k1 + 1)) / (freq + k1 * (1 - b + b * (docLen / avgDocLen)))',
          [
            Explanation.match(freq, 'term frequency (freq)'),
            Explanation.match(docLength, 'document length (docLength)'),
            Explanation.match(avgDocLength, 'average document length (avgDocLength)'),
          ],
        ),
      ],
    );
  }
}

/// Classic vector space TF-IDF similarity model.
class ClassicTfIdfSimilarity extends Similarity {
  const ClassicTfIdfSimilarity();

  @override
  double computeIdf(int docFreq, int totalDocs) {
    if (totalDocs <= 0) return 0.0;
    return 1.0 + math.log(totalDocs / (docFreq + 1.0));
  }

  @override
  double score({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  }) {
    if (freq <= 0.0) return 0.0;
    final tf = math.sqrt(freq);
    final lengthNorm = docLength > 0.0 ? 1.0 / math.sqrt(docLength) : 1.0;
    return idf * tf * lengthNorm;
  }

  @override
  Explanation explain({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  }) {
    final s = score(
      freq: freq,
      docLength: docLength,
      avgDocLength: avgDocLength,
      idf: idf,
    );
    return Explanation.match(
      s,
      'TF-IDF score (tf=sqrt(freq), idf, lengthNorm=1/sqrt(docLen))',
      [
        Explanation.match(idf, 'idf'),
        Explanation.match(math.sqrt(freq), 'tf=sqrt(freq) with freq=$freq'),
      ],
    );
  }
}

/// Boolean similarity model where any match scores 1.0.
class BooleanSimilarity extends Similarity {
  const BooleanSimilarity();

  @override
  double computeIdf(int docFreq, int totalDocs) => 1.0;

  @override
  double score({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  }) {
    return freq > 0 ? 1.0 : 0.0;
  }

  @override
  Explanation explain({
    required double freq,
    required double docLength,
    required double avgDocLength,
    required double idf,
  }) {
    return Explanation.match(freq > 0 ? 1.0 : 0.0, 'Boolean match');
  }
}
