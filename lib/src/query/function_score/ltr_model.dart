import 'dart:convert';
import 'dart:typed_data';

import '../../engine/index_searcher.dart';

/// Extracted feature vector representation for a query-document candidate pair.
class FeatureVector {
  final int docId;
  final Float64List values;
  final List<String> featureNames;

  FeatureVector({
    required this.docId,
    required this.values,
    required this.featureNames,
  });

  double operator [](int index) => values[index];
  void operator []=(int index, double val) => values[index] = val;

  double? getNamed(String name) {
    final idx = featureNames.indexOf(name);
    if (idx < 0) return null;
    return values[idx];
  }

  Map<String, double> toMap() {
    final map = <String, double>{};
    for (var i = 0; i < featureNames.length; i++) {
      map[featureNames[i]] = values[i];
    }
    return map;
  }
}

/// Abstract model capable of predicting relevance scores from feature vectors.
abstract class LtrModel {
  double predict(FeatureVector features);
}

/// Linear scoring model assigning learned weights to each feature.
class LinearLtrModel implements LtrModel {
  final List<double> weights;
  final double bias;

  const LinearLtrModel({
    required this.weights,
    this.bias = 0.0,
  });

  factory LinearLtrModel.fromMap(Map<String, double> featureWeights, List<String> featureOrder, {double bias = 0.0}) {
    final w = List<double>.generate(
      featureOrder.length,
      (i) => featureWeights[featureOrder[i]] ?? 0.0,
    );
    return LinearLtrModel(weights: w, bias: bias);
  }

  @override
  double predict(FeatureVector features) {
    var score = bias;
    final len = weights.length < features.values.length ? weights.length : features.values.length;
    for (var i = 0; i < len; i++) {
      score += weights[i] * features.values[i];
    }
    return score;
  }

  Map<String, dynamic> toJson() => {
    'type': 'linear',
    'weights': weights,
    'bias': bias,
  };

  factory LinearLtrModel.fromJson(Map<String, dynamic> json) {
    final rawWeights = (json['weights'] as List).map((e) => (e as num).toDouble()).toList();
    final bias = (json['bias'] as num?)?.toDouble() ?? 0.0;
    return LinearLtrModel(weights: rawWeights, bias: bias);
  }
}

/// Node in a regression decision tree.
class TreeNode {
  final int featureIndex;
  final double threshold;
  final double? leafValue;
  final TreeNode? left;
  final TreeNode? right;

  const TreeNode.leaf(this.leafValue)
      : featureIndex = -1,
        threshold = 0.0,
        left = null,
        right = null;

  const TreeNode.split({
    required this.featureIndex,
    required this.threshold,
    required this.left,
    required this.right,
  }) : leafValue = null;

  bool get isLeaf => leafValue != null;

  double evaluate(FeatureVector features) {
    if (isLeaf) return leafValue!;
    if (features.values[featureIndex] <= threshold) {
      return left!.evaluate(features);
    } else {
      return right!.evaluate(features);
    }
  }

  Map<String, dynamic> toJson() {
    if (isLeaf) {
      return {'leaf': leafValue};
    }
    return {
      'feature': featureIndex,
      'threshold': threshold,
      'left': left!.toJson(),
      'right': right!.toJson(),
    };
  }

  factory TreeNode.fromJson(Map<String, dynamic> json) {
    if (json.containsKey('leaf')) {
      return TreeNode.leaf((json['leaf'] as num).toDouble());
    }
    return TreeNode.split(
      featureIndex: json['feature'] as int,
      threshold: (json['threshold'] as num).toDouble(),
      left: TreeNode.fromJson(json['left'] as Map<String, dynamic>),
      right: TreeNode.fromJson(json['right'] as Map<String, dynamic>),
    );
  }
}

/// Ensemble of regression decision trees trained via Gradient Boosted Decision Trees (GBDT).
/// Matches standard LambdaMART / LightGBM scoring pipelines.
class GbdtModel implements LtrModel {
  final List<TreeNode> trees;
  final double learningRate;
  final double baseScore;

  const GbdtModel({
    required this.trees,
    this.learningRate = 0.1,
    this.baseScore = 0.0,
  });

  @override
  double predict(FeatureVector features) {
    var total = baseScore;
    for (final tree in trees) {
      total += learningRate * tree.evaluate(features);
    }
    return total;
  }

  Map<String, dynamic> toJson() => {
    'type': 'gbdt',
    'learningRate': learningRate,
    'baseScore': baseScore,
    'trees': trees.map((t) => t.toJson()).toList(),
  };

  factory GbdtModel.fromJson(Map<String, dynamic> json) {
    final lr = (json['learningRate'] as num?)?.toDouble() ?? 0.1;
    final base = (json['baseScore'] as num?)?.toDouble() ?? 0.0;
    final treeList = (json['trees'] as List)
        .map((t) => TreeNode.fromJson(t as Map<String, dynamic>))
        .toList();
    return GbdtModel(trees: treeList, learningRate: lr, baseScore: base);
  }

  String serialize() => jsonEncode(toJson());

  factory GbdtModel.deserialize(String jsonString) =>
      GbdtModel.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
}

/// Candidate document with extracted features and LTR prediction score.
class RankedCandidate {
  final ScoreDoc originalDoc;
  final FeatureVector features;
  final double rerankScore;

  RankedCandidate({
    required this.originalDoc,
    required this.features,
    required this.rerankScore,
  });
}

/// Learning-to-Rank (LTR) two-stage reranker.
/// Re-ranks top-K retrieved candidates using learned feature combinations.
class LtrReranker {
  final LtrModel model;
  final List<String> featureNames;

  LtrReranker({
    required this.model,
    required this.featureNames,
  });

  /// Re-scores candidates, sorting descending by the LTR model's prediction.
  List<RankedCandidate> rerank(List<ScoreDoc> candidates, List<FeatureVector> features) {
    assert(candidates.length == features.length, 'Candidate and feature counts must match');

    final ranked = <RankedCandidate>[];
    for (var i = 0; i < candidates.length; i++) {
      final feat = features[i];
      final score = model.predict(feat);
      ranked.add(RankedCandidate(
        originalDoc: candidates[i],
        features: feat,
        rerankScore: score,
      ));
    }

    // Sort descending by LTR score
    ranked.sort((a, b) => b.rerankScore.compareTo(a.rerankScore));
    return ranked;
  }
}
