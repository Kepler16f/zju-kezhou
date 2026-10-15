/// widgets/dashboard_view.dart — 学业看板：GPA 总览卡 + 学分分类看板 + 课堂分（素拓）卡。
library;

import 'package:flutter/material.dart';

import '../engine/analytics.dart';

class DashboardView extends StatelessWidget {
  final List<Map<String, dynamic>> courses;
  final Map<String, double> practice; // 第二/三/四课堂
  final String? planQuality; // 教务方案数据质量提示（可空）
  const DashboardView(
      {super.key, required this.courses, required this.practice, this.planQuality});

  @override
  Widget build(BuildContext context) {
    final o = Analytics.overall(courses);
    final cats = Analytics.creditByCategory(courses);
    final maxCat = cats.isEmpty ? 1.0 : (cats.first['credits'] as double);
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (planQuality != null)
          Card(
            color: scheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text('培养方案：$planQuality', style: const TextStyle(fontSize: 12)),
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _big('4.3 制', o['four'], 'GPA'),
                _big('五分制', o['five'], 'GPA'),
                _big('加权', o['weighted'], '分'),
                _big('已获', o['earned_credits'], '学分'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('学分看板（按课程性质）',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        if (cats.isEmpty)
          const Card(child: ListTile(title: Text('暂无已修课程数据'))),
        for (final cat in cats)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                    width: 110,
                    child: Text(cat['category'] as String,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis)),
                Expanded(
                  child: LinearProgressIndicator(
                    value: (cat['credits'] as double) / maxCat,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                SizedBox(
                    width: 52,
                    child: Text('${cat['credits']}',
                        textAlign: TextAlign.right,
                        style: const TextStyle(fontSize: 12))),
              ],
            ),
          ),
        const SizedBox(height: 10),
        const Text('课堂分（素拓）', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 4),
        Card(
          child: practice.isEmpty
              ? const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('未获取（教务网模式登录后自动拉取）'),
                  subtitle: Text('第二/三/四课堂记点，毕业要求以学院口径为准', style: TextStyle(fontSize: 11)))
              : Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    for (final e in practice.entries)
                      Column(
                        children: [
                          Text(e.value.toStringAsFixed(1),
                              style: const TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.bold)),
                          Text(e.key, style: const TextStyle(fontSize: 11)),
                        ],
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 8),
        const Text('口径说明：GPA 排除弃修/待录/缓考/二级制/线上课；五分绩点取教务 jd 值，'
            '缺失时用参考换算；正式认定以教务为准。',
            style: TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  Widget _big(String label, double? v, String unit) => Column(
        children: [
          Text(v?.toStringAsFixed(2) ?? '—',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text('$label$unit', style: const TextStyle(fontSize: 11)),
        ],
      );
}
