/// widgets/exam_sprint_card.dart — 考试周冲刺卡（Helechron 同款能力，视觉用本仓组件）：
/// 21 天内置顶：最近一场倒计时（30s 自刷）+ 排考冲突红警 + 同日连考橙警 + 考场信息一键复制。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engine/exam.dart';
import 'scholar_cards.dart';

class ExamSprintCard extends StatefulWidget {
  final List<ExamInfo> exams; // 全量考试；窗口筛选在卡片内完成
  const ExamSprintCard({super.key, required this.exams});

  @override
  State<ExamSprintCard> createState() => _ExamSprintCardState();
}

class _ExamSprintCardState extends State<ExamSprintCard> {
  Timer? _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 30),
        (_) => setState(() => _now = DateTime.now()));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = examSprint(widget.exams, _now);
    final next = s.next;
    if (next == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;

    return ForeheadCard(
      foreheadColor: const Color(0xFFFCA5A5),
      icon: Icons.timer_outlined,
      title: '考试周冲刺',
      trailing: '${s.upcoming.length} 场在途',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('下一场：${next.name}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text('距离开考还有 ${countdownText(next.start.difference(_now))}',
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: scheme.primary)),
          const SizedBox(height: 4),
          Text('${_fmt(next.start)} ～ ${_hm(next.end)}｜${next.locationFull}',
              style: const TextStyle(fontSize: 12)),
          for (final (a, b) in s.conflicts)
            _warnRow(context, Icons.dangerous_outlined, Colors.red.shade700,
                '时间冲突！${a.name} 与 ${b.name} 重叠（${_hm(a.start)}～${_hm(a.end)} / ${_hm(b.start)}～${_hm(b.end)}）'),
          for (final (a, b) in s.sameDayRush)
            _warnRow(context, Icons.swap_horiz, Colors.orange.shade800,
                '同日连考：${a.name} → ${b.name}，间隔仅 ${b.start.difference(a.end).inMinutes} 分钟，提前规划转场'),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final e in s.upcoming)
                ActionChip(
                  avatar: const Icon(Icons.copy, size: 14),
                  label: Text('${e.name} ${_hm(e.start)}',
                      style: const TextStyle(fontSize: 11)),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                        text: '${e.name}｜${_fmt(e.start)}～${_hm(e.end)}'
                            '｜${e.locationFull}'));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('已复制「${e.name}」考场信息'),
                              duration: const Duration(seconds: 2)));
                    }
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _warnRow(BuildContext context, IconData icon, Color color, String text) =>
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 4),
            Expanded(
                child: Text(text,
                    style: TextStyle(fontSize: 12, color: color))),
          ],
        ),
      );

  String _fmt(DateTime d) =>
      '${d.month} 月 ${d.day} 日 ${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';
  String _hm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
