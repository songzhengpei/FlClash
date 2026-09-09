import 'package:fl_clash/views/proxies/list_layout.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('large expanded groups and collapsed groups retain row boundaries', () {
    final layout = ProxyListLayout(
      nodeCounts: [10000, 0, 3],
      headerHeight: 40,
      nodeHeight: 60,
    );
    expect(layout.rowCount, 10006);
    expect(layout.headerOffsets, [0, 600040, 600080]);
    expect(layout.rowAt(0), (groupIndex: 0, proxyIndex: -1));
    expect(layout.rowAt(10000), (groupIndex: 0, proxyIndex: 9999));
    expect(layout.rowAt(10001), (groupIndex: 1, proxyIndex: -1));
    expect(layout.rowAt(10002), (groupIndex: 2, proxyIndex: -1));
    expect(layout.rowAt(10005), (groupIndex: 2, proxyIndex: 2));
    expect(() => layout.rowAt(10006), throwsRangeError);
  });
}
