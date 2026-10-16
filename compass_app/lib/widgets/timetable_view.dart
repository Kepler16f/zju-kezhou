/// widgets/timetable_view.dart — 课表周视图（诉求 #15 课表要可见；#4 秋/冬分开）。
///
/// 顶部子学期分段（全部/秋/冬/短），主体为周一..周日 × 第1..13节网格：
/// - 「秋」显示 subTerm∈{秋,秋冬}；「冬」∈{冬,秋冬}；「短」=='短'；
///   春/夏与未标注行只在「全部」出现（真实数据 '秋冬' 贯穿秋+冬两个子学期）。
/// - 列横向可滚（SingleChildScrollView 横向），行首「节次」列固定、不随横滚。
/// - 同日同节次区间多门课 → 格内纵向堆叠小卡片（名称粗体 11.5 / 教师·地点 / 第a-b周·单双）；
///   同格 ≥2 门视为冲突，卡片描 error 色 1.5 边框（纯视觉标记）。
/// 零新增依赖；配色复用 scholar_cards 浅色盘（只读参考，不改它）。
library;

import 'package:flutter/material.dart';

import '../data/xk_parse.dart';
import 'scholar_cards.dart';

// ── 网格几何（节次行高 / 总节数 / 单日列宽 / 固定标签列宽）──
const double _kCellH = 44.0;
const double _kHeadH = 28.0;
const double _kDayW = 110.0;
const double _kGutterW = 40.0;
const int _kPeriods = 13;
const int _kDays = 7;

const List<String> _kFilters = ['', '秋', '冬', '短'];
const List<String> _kFilterLabels = ['全部', '秋', '冬', '短'];
const List<String> _kDayLabels = ['一', '二', '三', '四', '五', '六', '日'];

class TimetableView extends StatefulWidget {
  final List<TimetableRow> rows;

  /// 初始子学期筛选：'' 全部 / '秋' / '冬' / '短'；非法值回退「全部」。
  final String initialSubTerm;

  const TimetableView({
    super.key,
    required this.rows,
    this.initialSubTerm = '',
  });

  @override
  State<TimetableView> createState() => _TimetableViewState();
}

class _TimetableViewState extends State<TimetableView> {
  late String _subTerm =
      _kFilters.contains(widget.initialSubTerm) ? widget.initialSubTerm : '';

  bool _matches(TimetableRow r) {
    switch (_subTerm) {
      case '秋':
        return r.subTerm == '秋' || r.subTerm == '秋冬';
      case '冬':
        return r.subTerm == '冬' || r.subTerm == '秋冬';
      case '短':
        return r.subTerm == '短';
      default:
        return true; // 全部：春/夏/未标注也在此
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = widget.rows.where(_matches).toList(growable: false);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
          child: SegmentedButton<String>(
            segments: [
              for (var i = 0; i < _kFilters.length; i++)
                ButtonSegment(
                    value: _kFilters[i], label: Text(_kFilterLabels[i])),
            ],
            selected: {_subTerm},
            onSelectionChanged: (s) => setState(() => _subTerm = s.first),
          ),
        ),
        if (rows.isEmpty)
          SizedBox(
            height: 220,
            child: Center(
              child: Text(
                '本学期暂无课表数据',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
            ),
          )
        else
          SizedBox(
            height: _kHeadH + _kPeriods * _kCellH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _gutterColumn(scheme),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var d = 1; d <= _kDays; d++)
                          _dayColumn(d, rows, scheme),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 行首固定「节次」列：表头 + 1..13，不随横向滚动。
  Widget _gutterColumn(ColorScheme scheme) {
    return SizedBox(
      width: _kGutterW,
      child: Column(
        children: [
          SizedBox(
            height: _kHeadH,
            child: const Center(
              child: Text('节次',
                  style:
                      TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
            ),
          ),
          for (var p = 1; p <= _kPeriods; p++)
            SizedBox(
              height: _kCellH,
              child: Center(
                child: Text('$p',
                    style:
                        TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
              ),
            ),
        ],
      ),
    );
  }

  /// 单日列：星期表头 + 网格线背景 + 课程卡片（同格堆叠 / 重叠块分栏 / 冲突描边）。
  Widget _dayColumn(int day, List<TimetableRow> rows, ColorScheme scheme) {
    final blocks = _pack(rows.where((r) => r.day == day).toList());
    final laneCount = blocks.isEmpty
        ? 1
        : blocks.map((b) => b.lane).reduce((a, b) => a > b ? a : b) + 1;
    final laneW = (_kDayW - 4) / laneCount;
    final dark = scheme.brightness == Brightness.dark;
    final lineColor =
        scheme.onSurfaceVariant.withValues(alpha: dark ? 0.20 : 0.14);
    final vLineColor =
        scheme.onSurfaceVariant.withValues(alpha: dark ? 0.16 : 0.10);

    return SizedBox(
      width: _kDayW,
      child: Column(
        children: [
          SizedBox(
            height: _kHeadH,
            child: Center(
              child: Text('周${_kDayLabels[day - 1]}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ),
          SizedBox(
            height: _kPeriods * _kCellH,
            child: Stack(
              children: [
                Positioned.fill(
                  child: Column(
                    children: [
                      for (var p = 1; p <= _kPeriods; p++)
                        Container(
                          height: _kCellH,
                          decoration: BoxDecoration(
                            border: Border(
                              bottom:
                                  BorderSide(color: lineColor, width: 0.5),
                              right:
                                  BorderSide(color: vLineColor, width: 0.5),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                for (final b in blocks)
                  for (var i = 0; i < b.rows.length; i++)
                    Positioned(
                      top: (b.start - 1) * _kCellH + 2 +
                          i * (b.slotH + 2),
                      left: 2 + b.lane * laneW,
                      width: laneW - 3,
                      height: b.slotH,
                      child: _CourseCard(b.rows[i], conflict: b.conflict),
                    ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── 布局装箱与卡片 ─────────────────────────

/// 同日行按节次区间聚块：完全同 (start,end) 的多门课入同一块（格内纵向堆叠，
/// 块内 ≥2 门即冲突）；区间重叠但不同的块横向分栏（lane），互不遮挡。
class _Block {
  final int start;
  final int end;
  final List<TimetableRow> rows = [];
  int lane = 0;
  double slotH = 0;
  _Block(this.start, this.end);
  bool get conflict => rows.length >= 2;
  bool overlaps(_Block o) => start <= o.end && o.start <= end;
}

List<_Block> _pack(List<TimetableRow> dayRows) {
  final groups = <String, _Block>{};
  for (final r in dayRows) {
    final s = r.start.clamp(1, _kPeriods);
    final e = r.end.clamp(s, _kPeriods);
    groups.putIfAbsent('$s-$e', () => _Block(s, e)).rows.add(r);
  }
  final blocks = groups.values.toList()
    ..sort((a, b) =>
        a.start != b.start ? a.start.compareTo(b.start) : a.end.compareTo(b.end));
  // lane 贪心装箱：放入第一个与已排块均不重叠的泳道
  final lanes = <List<_Block>>[];
  for (final b in blocks) {
    var placed = false;
    for (var i = 0; i < lanes.length && !placed; i++) {
      if (!lanes[i].any((o) => b.overlaps(o))) {
        b.lane = i;
        lanes[i].add(b);
        placed = true;
      }
    }
    if (!placed) {
      b.lane = lanes.length;
      lanes.add([b]);
    }
  }
  // 格内堆叠：块可用高均分给各门课（留 2px 间距），保底 20 高（名称仍可读）。
  for (final b in blocks) {
    final h = (b.end - b.start + 1) * _kCellH - 4;
    b.slotH =
        ((h - (b.rows.length - 1) * 2) / b.rows.length).clamp(20.0, h);
  }
  return blocks;
}

/// 课程名哈希定色（复用 scholar_cards 浅色盘，稳定且零配置）。
const List<Color> _kPalette = [
  ScholarPalette.cyan,
  ScholarPalette.peach,
  ScholarPalette.spring,
  ScholarPalette.sakura,
  ScholarPalette.sand,
  ScholarPalette.magenta,
];

Color _courseColor(String name) {
  var h = 0;
  for (final r in name.runes) {
    h = (h * 31 + r) & 0x7FFFFFFF;
  }
  return _kPalette[h % _kPalette.length];
}

class _CourseCard extends StatelessWidget {
  final TimetableRow row;
  final bool conflict;
  const _CourseCard(this.row, {required this.conflict});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final base = _courseColor(row.name);
    final parity = row.parity == 1 ? '单' : (row.parity == 2 ? '双' : '');
    final meta = [
      if (row.teacher.isNotEmpty) row.teacher,
      if (row.place.isNotEmpty) row.place,
    ].join('·');
    // 卡高可能小于一列三行文本（同格挤多门）：OverflowBox 自然排版 + ClipRect 裁切，
    // 装不下的行不可见、绝不溢出报错。
    return ClipRect(
      child: Container(
        decoration: BoxDecoration(
          color: base.withValues(alpha: dark ? 0.20 : 0.30),
          borderRadius: BorderRadius.circular(8),
          border:
              conflict ? Border.all(color: scheme.error, width: 1.5) : null,
        ),
        padding: const EdgeInsets.fromLTRB(4, 1, 4, 1),
        child: OverflowBox(
          alignment: Alignment.topLeft,
          maxHeight: double.infinity,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.bold),
              ),
              if (meta.isNotEmpty)
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 9.5, color: scheme.onSurfaceVariant),
                ),
              Text(
                '第${row.weekStart}-${row.weekEnd}周'
                '${parity.isEmpty ? '' : '·$parity'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 9.5, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
