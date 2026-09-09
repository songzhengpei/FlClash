/// Indexes only group boundaries; nodes are materialized by the viewport.
class ProxyListLayout {
  ProxyListLayout({
    required List<int> nodeCounts,
    required double headerHeight,
    required double nodeHeight,
  }) {
    var offset = 0.0;
    for (final count in nodeCounts) {
      _starts.add(rowCount);
      headerOffsets.add(offset);
      rowCount += 1 + count;
      offset += headerHeight + count * nodeHeight;
    }
  }

  final _starts = <int>[];
  final headerOffsets = <double>[];
  int rowCount = 0;

  ({int groupIndex, int proxyIndex}) rowAt(int index) {
    RangeError.checkValidIndex(index, this, 'index', rowCount);
    var low = 0;
    var high = _starts.length;
    while (low + 1 < high) {
      final mid = (low + high) ~/ 2;
      if (_starts[mid] <= index) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return (groupIndex: low, proxyIndex: index - _starts[low] - 1);
  }
}
