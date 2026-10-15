/// widgets/gpa_tools_view.dart — GPA 工具：学期走势折线图 + GPA 模拟器（what-if + 目标反推）。
library;

import 'package:flutter/material.dart';

import '../engine/analytics.dart';
import 'line_chart.dart';

class GpaToolsView extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  const GpaToolsView({super.key, required this.courses});

  @override
  State<GpaToolsView> createState() => _GpaToolsViewState();
}

class _GpaToolsViewState extends State<GpaToolsView> {
  final _planned = <Map<String, dynamic>>[];
  double _targetFour = 3.8;
  double _remainingCredits = 30;

  @override
  Widget build(BuildContext context) {
    final trend = Analytics.semesterTrend(widget.courses);
    final points = [
      for (var i = 0; i < trend.length; i++)
        TrendPoint(_label(trend[i]), trend[i]['four']!, trend[i]['cumulative_four']!)
    ];
    final currentFour = Analytics.overall(widget.courses)['four']!;
    final projected = Analytics.simulateGpa(widget.courses, _planned);
    final required = Analytics.requiredFiveForTarget(
        widget.courses, _targetFour, _remainingCredits);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const Text('学期走势（4.3 制）',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: points.isEmpty
                ? const SizedBox(height: 180, child: Center(child: Text('暂无数据')))
                : Column(
                    children: [
                      TrendChart(points: points),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _legend(scheme.primary, '累计 GPA'),
                          const SizedBox(width: 12),
                          _legend(scheme.tertiary, '学期 GPA'),
                        ],
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 12),
        const Text('GPA 模拟器', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前 4.3 制 GPA：${currentFour.toStringAsFixed(2)}',
                    style: const TextStyle(fontSize: 13)),
                if (_planned.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text('模拟后：${projected.toStringAsFixed(2)}（${projected >= currentFour ? "↑" : "↓"}'
                      '${(projected - currentFour).abs().toStringAsFixed(2)}）',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: projected >= currentFour
                              ? Colors.green.shade700
                              : Colors.red.shade700)),
                ],
                const SizedBox(height: 8),
                for (var i = 0; i < _planned.length; i++)
                  _plannedRow(i),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () => setState(() => _planned.add({
                            'name': '计划课程 ${_planned.length + 1}',
                            'credits': 3.0,
                            'five_point': 4.5,
                          })),
                      icon: const Icon(Icons.add),
                      label: const Text('加一门计划课'),
                    ),
                    if (_planned.isNotEmpty)
                      TextButton(
                          onPressed: () => setState(() => _planned.clear()),
                          child: const Text('清空')),
                  ],
                ),
                const Divider(),
                Text('目标反推：剩余 $_remainingCredits 学分，想达到 $_targetFour',
                    style: const TextStyle(fontSize: 13)),
                Slider(
                  value: _targetFour,
                  min: 2.0,
                  max: 4.3,
                  divisions: 23,
                  label: _targetFour.toStringAsFixed(1),
                  onChanged: (v) => setState(() => _targetFour = v),
                ),
                Slider(
                  value: _remainingCredits,
                  min: 5,
                  max: 80,
                  divisions: 15,
                  label: '$_remainingCredits 学分',
                  onChanged: (v) => setState(() => _remainingCredits = v),
                ),
                Text(
                  required == null
                      ? '该目标在剩余学分内无法达到（上限 4.3）'
                      : '需要剩余课程平均五分绩点 ≥ $required'
                          '（约 ${_fiveToHint(required)} 分制成绩）',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: required == null ? Colors.red.shade700 : scheme.primary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('模拟为确定性算术（Σ绩点×学分/Σ学分），不含重修覆盖等教务规则；'
            '正式认定以教务为准。',
            style: TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  String _label(Map<String, double> t) {
    final idx = t['semester_idx']!;
    if (idx < 0) return '?';
    final y = (idx / 2).floor();
    return '$y-${idx % 2 == 0 ? 'A' : 'B'}';
  }

  String _fiveToHint(double five) {
    if (five >= 5.0) return '95+';
    if (five >= 4.8) return '90+';
    if (five >= 4.5) return '85+';
    if (five >= 4.2) return '82+';
    if (five >= 4.0) return '78+';
    if (five >= 3.7) return '75+';
    if (five >= 3.3) return '72+';
    if (five >= 3.0) return '68+';
    if (five >= 2.3) return '64+';
    if (five >= 1.7) return '60+';
    return '<60';
  }

  Widget _legend(Color c, String label) => Row(
        children: [
          Container(width: 18, height: 3, color: c),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 11)),
        ],
      );

  Widget _plannedRow(int i) {
    final p = _planned[i];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text('${p['name']}（${(p['credits'] as num).toStringAsFixed(1)} 学分）',
                style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            flex: 2,
            child: Slider(
              value: (p['five_point'] as num).toDouble(),
              min: 0,
              max: 5,
              divisions: 10,
              label: (p['five_point'] as num).toStringAsFixed(1),
              onChanged: (v) => setState(() => p['five_point'] = v),
            ),
          ),
          SizedBox(
              width: 34,
              child: Text((p['five_point'] as num).toStringAsFixed(1),
                  style: const TextStyle(fontSize: 12))),
          IconButton(
              icon: const Icon(Icons.close, size: 16),
              onPressed: () => setState(() => _planned.removeAt(i))),
        ],
      ),
    );
  }
}
