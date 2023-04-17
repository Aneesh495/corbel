/// Explanation tree providing deep visibility into score calculations.
class Explanation {
  final double value;
  final String description;
  final List<Explanation> details;
  final bool isMatch;

  const Explanation({
    required this.value,
    required this.description,
    this.details = const [],
    this.isMatch = true,
  });

  /// Factory for non-matching explanation.
  factory Explanation.noMatch(String description, [List<Explanation> details = const []]) {
    return Explanation(
      value: 0.0,
      description: description,
      details: details,
      isMatch: false,
    );
  }

  /// Factory for matching explanation.
  factory Explanation.match(double value, String description, [List<Explanation> details = const []]) {
    return Explanation(
      value: value,
      description: description,
      details: details,
      isMatch: true,
    );
  }

  /// Renders formatted multi-line ASCII tree.
  String toTreeString([int depth = 0]) {
    final indent = '  ' * depth;
    final matchMarker = isMatch ? '(*)' : '( )';
    final buf = StringBuffer();
    buf.writeln('$indent$matchMarker ${value.toStringAsFixed(4)}: $description');
    for (final child in details) {
      buf.write(child.toTreeString(depth + 1));
    }
    return buf.toString();
  }

  @override
  String toString() => '$description ($value)';
}
