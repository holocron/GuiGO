/// The pixel split of a CFW splitter (SAPGUI.SplitterCtrl /
/// com.sap.platin.cet.GuiSplitterShell) — a port of the SAP GUI for Java's
/// layout (platinr3S.jar com.sap.platin.r3.cet.splitter.GuiSplitterLayout
/// doGuiLayout → layoutRelative / layoutAbsolute, and Splitter.setRowHeight
/// / GuiSplitterLayout.setRowValue for what a SetRowHeight stores). The
/// composition works in cells (`composeScreen`'s `_shares`, the reference client's
/// splitter_layout._shares); this is the real control's arithmetic in its
/// own pixels, pinned against the cell split in the tests.
///
/// What the jar does, bytecode for bytecode:
/// * setGrid fills every row / column value with -1 (unset);
/// setRowHeight rejects a value below -1 (`-101`, nothing stored: the
/// server's `SetRowHeight(2, -104)` on the 1 x 1 splitter 120 of
/// /AIF/IFMON) and an out-of-range row (`-104`); setRowValue stores -1
/// on a 1-row splitter whatever the value;
/// * the extent shared is the container's minus one sash
/// ([splitterSashPx], `UIManager Divider.size`, else 6) per VISIBLE
/// sash;
/// * RELATIVE (mode 1, the default): with S the sum of the set values and
/// U the unset count, a set value v takes `total * v / 100` when S <=
/// 100 and U > 0, else `total * v / S` (0 when S is 0) — Java's
/// truncating int division; the unset ones share the rest equally; the
/// leftover pixels of that division go one each to the FIRST rows, set
/// or not;
/// * ABSOLUTE (mode 0): a set value takes min(value, what is left), the
/// unset ones share the rest, the remainder one each to the first
/// unset ones.
library;

import 'dart:math' as math;

/// The jar's sash thickness when the look and feel sets none
/// (GuiSplitterLayout.<init>: `Divider.size` > 0 ? it : 6).
const int splitterSashPx = 6;

/// The value a SetRowHeight / SetColumnWidth of [value] leaves in a
/// splitter of [count] rows (columns) that held [old]: [old] when the jar
/// rejects it (below -1), -1 on a single-row splitter, else [value].
int splitterStoredValue(int old, int value, int count) {
  if (value < -1) return old;
  return count > 1 ? value : -1;
}

/// The pixel extents of a splitter's rows (columns) holding [values] (-1 =
/// unset) over [size] pixels with [visibleSashes] sashes of [sashPx] each,
/// in [mode] (1 relative, 0 absolute) — GuiSplitterLayout.layoutRelative /
/// layoutAbsolute.
List<int> splitterSpansPx(
  List<int> values,
  int size, {
  int mode = 1,
  int visibleSashes = 0,
  int sashPx = splitterSashPx,
}) {
  final n = values.length;
  final spans = List<int>.filled(n, 0);
  final total = size - visibleSashes * sashPx;
  if (mode != 1) {
    var avail = total;
    var unset = 0;
    for (var i = 0; i < n; i++) {
      if (values[i] >= 0) {
        spans[i] = math.min(avail, values[i]);
        avail = math.max(avail - spans[i], 0);
      } else {
        unset++;
      }
    }
    if (unset > 0) {
      final share = avail ~/ unset;
      var rem = avail.remainder(unset);
      for (var i = 0; i < n; i++) {
        if (values[i] >= 0) continue;
        if (rem > 0) {
          spans[i] = share + 1;
          rem--;
        } else {
          spans[i] = share;
        }
      }
    }
    return spans;
  }
  var sum = 0, unset = 0;
  for (final v in values) {
    if (v != -1) {
      sum += v;
    } else {
      unset++;
    }
  }
  var acc = 0;
  for (var i = 0; i < n; i++) {
    final v = values[i];
    if (v == -1) continue;
    if (sum <= 100 && unset != 0) {
      spans[i] = _jdiv(total * v, 100);
    } else if (sum > 0) {
      spans[i] = _jdiv(total * v, sum);
    } else {
      spans[i] = 0;
    }
    acc += spans[i];
  }
  final rest = total - acc;
  final share = unset > 0 ? _jdiv(rest, unset) : 0;
  var rem = rest - share * unset;
  for (var i = 0; i < n; i++) {
    if (values[i] == -1) spans[i] = share;
    if (rem != 0) {
      spans[i]++;
      rem--;
    }
  }
  return spans;
}

/// Java's int division (truncates toward zero).
int _jdiv(int a, int b) => a ~/ b;
