/// test/course_variant_match_test.dart — 课程变体（H / I / II / 上 / 下…）隔离。
///
/// 用户反馈：大学英语（I）、大学英语（II）、大学英语（H）是不同课程；
/// 只修/只选了其中一门时，不允许把另一门也匹配成已修。
/// 纯 Dart 引擎测试（matching.dart / course_state.dart 均不依赖 Flutter）。
library;

import 'package:compass_app/engine/course_state.dart';
import 'package:compass_app/engine/matching.dart';
import 'package:test/test.dart';

Map<String, dynamic> planCourse(String name) => <String, dynamic>{
      'course_id': '',
      'name': name,
      'credits': 2.0,
      'module_id': 'm1',
    };

Map<String, dynamic> recordRow(String name) => <String, dynamic>{
      'course_id': '',
      'name': name,
      'credits': 2.0,
      'grade': 90,
      'semester': '2025-A',
    };

Map<String, dynamic> planOf(List<String> names) => <String, dynamic>{
      'meta': const {'major': 'm', 'grade': '2023'},
      'modules': const [
        {'module_id': 'm1', 'path': '通识教育/外语类', 'required_credits': 8.0}
      ],
      'courses': names.map(planCourse).toList(),
    };

void main() {
  group('courseVariantSignature：H / I / II 是不同变体', () {
    test('括号与末尾写法归一', () {
      expect(courseVariantSignature('大学英语（I）'), '1');
      expect(courseVariantSignature('大学英语（II）'), '2');
      expect(courseVariantSignature('大学英语（H）'), 'h');
      expect(courseVariantSignature('大学英语II'), '2');
      expect(courseVariantSignature('大学英语Ⅱ'), '2');
      expect(courseVariantSignature('大学英语2'), '2');
      expect(courseVariantSignature('高等数学（上）'), '上');
      expect(courseVariantSignature('高等数学（下）'), '下');
      expect(courseVariantSignature('概率论与数理统计乙'), '乙');
    });

    test('普通课程无变体签名（英文单词尾部字母不算）', () {
      expect(courseVariantSignature('数据结构'), '');
      expect(courseVariantSignature('Python'), '');
      expect(courseVariantSignature('C语言'), '');
    });
  });

  group('bestVariantAwareMatch：绝不跨变体替代', () {
    const variants = ['大学英语（I）', '大学英语（II）', '大学英语（H）'];

    test('同名变体精确命中', () {
      expect(bestVariantAwareMatch('大学英语（I）', variants), '大学英语（I）');
      expect(bestVariantAwareMatch('大学英语（II）', variants), '大学英语（II）');
      expect(bestVariantAwareMatch('大学英语（H）', variants), '大学英语（H）');
    });

    test('只修 I 时，II / H 不会被选中（即便相似度 ≥0.85）', () {
      expect(
          bestVariantAwareMatch('大学英语（I）', ['大学英语（II）', '大学英语（H）']),
          isNull);
    });

    test('写法差异但同变体仍可命中（II ↔ （II））', () {
      expect(bestVariantAwareMatch('大学英语II', ['大学英语（II）']), '大学英语（II）');
      // 全角罗马 Ⅱ 与 ASCII II 相似度不足 0.85，走的是 matchRecordToPlan
      // 的归一化兜底（见下方 matchRecordToPlan 组），不是模糊通道。
      expect(courseVariantSignature('大学英语（Ⅱ）'), '2');
    });

    test('泛名同时指向 I/II：判歧义，不猜', () {
      expect(bestVariantAwareMatch('大学英语', ['大学英语（I）', '大学英语（II）']),
          isNull);
    });
  });

  group('matchRecordToPlan：一条成绩只对应一个变体', () {
    test('修了 I：只匹配 I，II/H 保持未修', () {
      final (matched, unmatched) = matchRecordToPlan(
        [recordRow('大学英语（I）')],
        planOf(['大学英语（I）', '大学英语（II）', '大学英语（H）']),
      );
      expect(unmatched, isEmpty);
      expect(matched, hasLength(1));
      expect((matched.single[1] as Map)['name'], '大学英语（I）');
    });

    test('修了 I 且方案只有 II/H：不匹配任何课', () {
      final (matched, unmatched) = matchRecordToPlan(
        [recordRow('大学英语（I）')],
        planOf(['大学英语（II）', '大学英语（H）']),
      );
      expect(matched, isEmpty);
      expect(unmatched, hasLength(1));
    });
  });

  group('resolvePassedNames：方案页「已修」标记不串变体', () {
    test('只修 I：只有 I 标已修，II/H 保持未修', () {
      final out = resolvePassedNames(
        ['大学英语（I）', '大学英语（II）', '大学英语（H）'],
        {'大学英语（I）'},
      );
      expect(out, {'大学英语（I）'});
    });

    test('成绩单写法略有出入（无括号）：同变体仍标已修', () {
      expect(
        resolvePassedNames(['大学英语（II）'], {'大学英语II'}),
        {'大学英语（II）'},
      );
    });
  });
}
