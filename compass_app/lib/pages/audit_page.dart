/// pages/audit_page.dart — 审计页：方案质量提示 + 三色达成度报告。
library;

import 'package:flutter/material.dart';

import '../widgets/report_view.dart';

class AuditPage extends StatelessWidget {
  final Map<String, dynamic>? report;
  final String? planQuality;
  const AuditPage({super.key, required this.report, this.planQuality});

  @override
  Widget build(BuildContext context) {
    if (report == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            '暂无审计报告\n\n切到「我的」页运行审计后，这里展示三色达成度报告',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }
    return Column(
      children: [
        if (planQuality != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.tertiaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('培养方案：$planQuality',
                style: const TextStyle(fontSize: 12)),
          ),
        Expanded(child: ReportView(report: report!)),
      ],
    );
  }
}
