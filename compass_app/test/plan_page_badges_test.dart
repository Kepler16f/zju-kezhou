// test/plan_page_badges_test.dart — 方案页「N选M」徽章文案纯函数小测（诉求 #2/#11）。
//
// choiceBadgeText 定义在 lib/pages/curriculum_plan_page.dart（依赖 material），
// 因此本文件属 Flutter 测试：不加入 .github/workflows/_engine-check.yml 的
// dart test 纯 Dart 白名单（该 CI 通道只收无 Flutter 依赖的用例），
// 由 `flutter test --no-pub` 全量覆盖。
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:compass_app/pages/curriculum_plan_page.dart';

void main() {
  test('choiceBadgeText：说明命中「二选一」→ 返回「规则：二选一」', () {
    const s = PdfModuleSection(
      title: '交叉复合类',
      level: 3,
      notes: ['以下两组课程二选一，具体以学院当学年通知为准'],
    );
    expect(choiceBadgeText(s), '规则：二选一');
  });

  test('choiceBadgeText：普通修读说明（无数量约束）→ null', () {
    const s = PdfModuleSection(
      title: '通识必修课程',
      level: 2,
      notes: ['按培养计划修读', '合计 12 学分'],
    );
    expect(choiceBadgeText(s), isNull);
  });

  test('choiceBadgeText：无说明 → null（空输入不抛异常）', () {
    const s = PdfModuleSection(title: '实践环节', level: 1);
    expect(choiceBadgeText(s), isNull);
  });

  test('choiceBadgeText：多选一 → 明确「选 1 门即满足整块」', () {
    const s = PdfModuleSection(
      title: '通识核心课程组',
      level: 3,
      notes: ['本组课程多选一，修读1门即满足本组要求。'],
    );
    expect(choiceBadgeText(s), '规则：多选一（选 1 门即满足整块）');
  });
}
