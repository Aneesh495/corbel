import 'package:corbel/corbel.dart';
import 'package:test/test.dart';

class _Candidate {
  final int id;
  final double distance;
  _Candidate(this.id, this.distance);
}

void main() {
  test('Bug 05: BoundedPriorityQueue distance minimization comparator preserves lowest distances', () {
    // When tracking the top-k lowest distances in a bounded min-heap,
    // the root element must be the candidate with the LARGEST distance among the top-k.
    // Therefore, comparator(newCandidate, top) must return > 0 when newCandidate.distance < top.distance.
    final pq = BoundedPriorityQueue<_Candidate>(
      3,
      (_Candidate a, _Candidate b) => b.distance.compareTo(a.distance),
    );

    pq.insertWithOverflow(_Candidate(1, 10.5));
    pq.insertWithOverflow(_Candidate(2, 2.1));
    pq.insertWithOverflow(_Candidate(3, 8.4));
    pq.insertWithOverflow(_Candidate(4, 1.2)); // Should evict 10.5
    pq.insertWithOverflow(_Candidate(5, 5.0)); // Should evict 8.4

    final top3 = pq.drainToListDescending();
    expect(top3.length, equals(3));

    // Results from best (lowest distance) to worst
    expect(top3[0].id, equals(4)); // distance 1.2
    expect(top3[1].id, equals(2)); // distance 2.1
    expect(top3[2].id, equals(5)); // distance 5.0
  });
}
