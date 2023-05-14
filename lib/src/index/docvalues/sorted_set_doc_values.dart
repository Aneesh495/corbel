import '../../storage/index_input.dart';
import '../../storage/index_output.dart';

/// Multi-valued sorted set DocValues for categorical terms and facet aggregations.
class SortedSetDocValues {
  final int count;
  final List<String> dictionary;
  final List<List<int>> _docOrds;

  SortedSetDocValues._(this.count, this.dictionary, this._docOrds);

  /// Writes SortedSetDocValues to output stream.
  static void write(IndexOutput out, List<List<String>> docTerms) {
    final count = docTerms.length;
    out.writeVInt(count);
    if (count == 0) return;

    // Build global sorted dictionary of unique terms
    final uniqueTerms = <String>{};
    for (final terms in docTerms) {
      uniqueTerms.addAll(terms);
    }
    final sortedDict = uniqueTerms.toList()..sort();
    final termToOrd = <String, int>{};
    for (var i = 0; i < sortedDict.length; i++) {
      termToOrd[sortedDict[i]] = i;
    }

    // Write dictionary
    out.writeVInt(sortedDict.length);
    for (final term in sortedDict) {
      out.writeString(term);
    }

    // Write ordinals per document
    for (final terms in docTerms) {
      final ords = terms.map((t) => termToOrd[t]!).toList()..sort();
      out.writeVInt(ords.length);
      var prev = 0;
      for (final ord in ords) {
        out.writeVInt(ord - prev);
        prev = ord;
      }
    }
  }

  /// Reads SortedSetDocValues from input stream.
  static SortedSetDocValues read(IndexInput inp) {
    final count = inp.readVInt();
    if (count == 0) {
      return SortedSetDocValues._(0, const [], const []);
    }

    final dictLen = inp.readVInt();
    final dict = List<String>.filled(dictLen, '');
    for (var i = 0; i < dictLen; i++) {
      dict[i] = inp.readString();
    }

    final docOrds = List<List<int>>.generate(count, (_) => []);
    for (var d = 0; d < count; d++) {
      final numOrds = inp.readVInt();
      final ords = List<int>.filled(numOrds, 0);
      var acc = 0;
      for (var o = 0; o < numOrds; o++) {
        acc += inp.readVInt();
        ords[o] = acc;
      }
      docOrds[d] = ords;
    }

    return SortedSetDocValues._(count, dict, docOrds);
  }

  /// Looks up term string by ordinal value.
  String lookupOrd(int ord) {
    if (ord < 0 || ord >= dictionary.length) {
      throw RangeError.index(ord, this, 'ord', 'Ordinal out of bounds', dictionary.length);
    }
    return dictionary[ord];
  }

  /// Returns sorted list of ordinals associated with document [docId].
  List<int> getOrds(int docId) {
    if (docId < 0 || docId >= count) {
      throw RangeError.index(docId, this, 'docId', 'Document ID out of bounds', count);
    }
    return _docOrds[docId];
  }

  /// Alias for [getOrds] providing Lucene-style naming convention.
  List<int> getOrdinals(int docId) => getOrds(docId);
}
