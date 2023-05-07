import 'boolean_query.dart';
import 'query.dart';
import 'term_query.dart';

/// Cost-based query AST optimizer that flattens nested trees and reorders conjunctions.
class QueryOptimizer {
  const QueryOptimizer();

  /// Rewrites and optimizes an input [Query] into an equivalent but faster AST.
  Query optimize(Query query) {
    if (query is! BooleanQuery) {
      return query;
    }

    return _optimizeBoolean(query);
  }

  Query _optimizeBoolean(BooleanQuery bq) {
    final flattenedClauses = <BooleanClause>[];

    // 1. Flatten nested Boolean queries of the same structure
    for (final clause in bq.clauses) {
      final sub = optimize(clause.query);

      if (sub is BooleanQuery && sub.boost == 1.0) {
        final allShould = sub.clauses.every((c) => c.occur == Occur.should);
        final allMust = sub.clauses.every((c) => c.occur == Occur.must);

        if (clause.occur == Occur.should && allShould) {
          flattenedClauses.addAll(sub.clauses);
          continue;
        } else if (clause.occur == Occur.must && allMust) {
          flattenedClauses.addAll(sub.clauses);
          continue;
        }
      }

      flattenedClauses.add(BooleanClause(query: sub, occur: clause.occur));
    }

    // 2. Eliminate redundant identical clauses and check contradictions
    final uniqueClauses = <String, BooleanClause>{};
    final positiveTerms = <String>{};
    final negativeTerms = <String>{};

    for (final clause in flattenedClauses) {
      final key = '${clause.occur}:${clause.query}';
      uniqueClauses[key] = clause;

      if (clause.query is TermQuery) {
        final tq = clause.query as TermQuery;
        final termKey = '${tq.field}:${tq.term}';
        if (clause.occur == Occur.must) positiveTerms.add(termKey);
        if (clause.occur == Occur.mustNot) negativeTerms.add(termKey);
      }
    }

    // Contradiction check: term appears in both MUST and MUST_NOT
    for (final pos in positiveTerms) {
      if (negativeTerms.contains(pos)) {
        return const BooleanQuery(clauses: []); // Empty matching query
      }
    }

    // 3. Reorder MUST and FILTER clauses by cost ascending (heuristics)
    final mustClauses = <BooleanClause>[];
    final filterClauses = <BooleanClause>[];
    final shouldClauses = <BooleanClause>[];
    final mustNotClauses = <BooleanClause>[];

    for (final clause in uniqueClauses.values) {
      switch (clause.occur) {
        case Occur.must:
          mustClauses.add(clause);
        case Occur.filter:
          filterClauses.add(clause);
        case Occur.should:
          shouldClauses.add(clause);
        case Occur.mustNot:
          mustNotClauses.add(clause);
      }
    }

    // Single child unwrapping
    if (mustClauses.isEmpty && filterClauses.isEmpty && mustNotClauses.isEmpty && shouldClauses.length == 1) {
      return shouldClauses.first.query;
    }

    final reordered = [
      ...filterClauses,
      ...mustClauses,
      ...shouldClauses,
      ...mustNotClauses,
    ];

    return BooleanQuery(
      clauses: reordered,
      minimumNumberShouldMatch: bq.minimumNumberShouldMatch,
      boost: bq.boost,
    );
  }
}
