/// widgets/gpa_simulator.dart — GPA 模拟器（what-if + 目标反推），学业页内嵌卡片。
/// 从原「工具」页签合并而来（诉求 #2）；默认五分制口径（任务包 B），副行保留 4.3 制对照。
library;

import 'package:flutter/material.dart';

import '../engine/analytics.dart';

class GpaSimulatorCard extends StatefulWidget {
  final List<Map<String, dynamic>> courses;
  const GpaSimulatorCard({super.key, required this.courses});

  @override
  State<GpaSimulatorCard> createState() => _GpaSimulatorCardState();
}

class _GpaSimulatorCardState extends State<GpaSimulatorCard> {
  final _planned = <Map<String, dynamic>>[];
  double _targetFive = 4.5; // 五分制目标（≈ 原 4.3 制默认 3.8 的档位）
  double _remainingCredits = 30;

  @override
  Widget build(BuildContext context) {
    final o = Analytics.overall(widget.courses);
    final currentFive = o['five']!;
    final currentFour = o['four']!;
    final projectedFive = Analytics.simulateFiveGpa(widget.courses, _planned);
    final projectedFour = Analytics.simulateGpa(widget.courses, _planned);
    final required = Analytics.requiredFiveForTargetFive(
        widget.courses, _targetFive, _remainingCredits);
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        // 去掉 ExpansionTile 展开区默认内衬，自管 padding。
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          shape: const Border(),
          leading: Icon(Icons.calculate_outlined, color: scheme.primary),
          title: const Text('GPA 模拟器',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          subtitle: Text(
              '当前五分制 ${currentFive.toStringAsFixed(2)}'
              '（4.3 制 ${currentFour.toStringAsFixed(2)}）'
              '${_planned.isNotEmpty ? ' → 模拟后 ${projectedFive.toStringAsFixed(2)}（${projectedFive >= currentFive ? "↑" : "↓"}${(projectedFive - currentFive).abs().toStringAsFixed(2)}，4.3 制 ${projectedFour.toStringAsFixed(2)}）' : ''}',
              style: const TextStyle(fontSize: 12)),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_planned.isNotEmpty)
              for (var i = 0; i < _planned.length; i++) _plannedRow(i),
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
            Text('目标反推：剩余 ${_remainingCredits.round()} 学分，想达到五分制 ${_targetFive.toStringAsFixed(1)}',
                style: const TextStyle(fontSize: 13)),
            Slider(
              value: _targetFive,
              min: 3.0,
              max: 5.0,
              divisions: 20,
              label: _targetFive.toStringAsFixed(1),
              onChanged: (v) => setState(() => _targetFive = v),
            ),
            Slider(
              value: _remainingCredits,
              min: 5,
              max: 80,
              divisions: 15,
              label: '${_remainingCredits.round()} 学分',
              onChanged: (v) => setState(() => _remainingCredits = v),
            ),
            Text(
              required == null
                  ? '该目标在剩余学分内无法达到（五分制上限 5.0）'
                  : '需要剩余课程平均五分绩点 ≥ ${required.toStringAsFixed(2)}（约 ${_fiveToHint(required)} 分制成绩）',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: required == null ? Colors.red.shade700 : scheme.primary),
            ),
            const SizedBox(height: 6),
            const Text('模拟为确定性算术（Σ绩点×学分/Σ学分），不含重修覆盖等教务规则；'
                '正式认定以教务为准。',
                style: TextStyle(fontSize: 10, color: Colors.grey)),
          ],
        ),
      ),
    );
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
