// test/plan_display_refactor_test.dart — 方案页展示重构的解析层回归（任务 #3/#6）。
//
//  1. isOverallRequirement 表驱动：总体要求/整章总述 → true；板块级修读要求 →
//     false（宁缺勿猜，误删真实要求的代价远大于多显示一行）。
//  2. declaredCreditsFromNotes：认定类板块（creditsRaw 空、学分写在说明里）
//     抽出「修读N学分」；门数板块/已有 creditsRaw/学时 一律 null（不冒充）。
import 'package:compass_app/data/plan_pdf_parse.dart';
import 'package:test/test.dart';

void main() {
  group('isOverallRequirement 总体要求判据（#3）', () {
    test('总括口径句 → true（隐藏）', () {
      expect(isOverallRequirement('以上各类课程总学分不低于毕业要求总学分'), isTrue);
      expect(isOverallRequirement('毕业要求总学分合计170学分'), isTrue);
      expect(isOverallRequirement('共计需修读以上各类课程'), isTrue);
      expect(isOverallRequirement('各类课程修读要求详见各板块说明'), isTrue);
      // 中文序号起头的整章总述行
      expect(
          isOverallRequirement(
              '一、通识课程板块坚持价值塑造、能力培养、知识传授三位一体的育人理念，'
              '全面落实学校人才培养总体要求，培养学生综合素质与跨学科视野'),
          isTrue);
    });

    test('板块级真实修读要求 → false（保留）', () {
      expect(isOverallRequirement('每门 2 学分'), isFalse);
      expect(isOverallRequirement('要求学生修读2学分美育类课程'), isFalse);
      expect(isOverallRequirement('选修3门以上即可满足要求'), isFalse); // 「3门以上」是数量下限
      expect(isOverallRequirement('该板块课程均为考查课，成绩按五级制记载'), isFalse);
      expect(isOverallRequirement(''), isFalse);
      expect(isOverallRequirement('   '), isFalse);
    });
  });

  group('declaredCreditsFromNotes 说明学分兜底（#6）', () {
    const plain = PdfModuleSection(
        title: '其他必修环节',
        level: 3,
        creditsRaw: '',
        notes: ['要求学生修读6学分'],
        courses: []);
    const withRaw = PdfModuleSection(
        title: '美育类',
        level: 3,
        creditsRaw: '2',
        notes: ['修读2学分'],
        courses: []);
    const hours = PdfModuleSection(
        title: '劳育类',
        level: 3,
        creditsRaw: '',
        notes: ['要求学生修读32学时劳动教育类课程'],
        courses: []);
    const none = PdfModuleSection(
        title: '某板块',
        level: 3,
        creditsRaw: '',
        notes: ['没有学分数字'],
        courses: []);

    test('creditsRaw 空且说明含「修读N学分」→ 抽 N；已有 creditsRaw/学时/无数字 → null', () {
      expect(plain.declaredCreditsFromNotes, '6');
      expect(withRaw.declaredCreditsFromNotes, isNull);
      expect(hours.declaredCreditsFromNotes, isNull); // 学时不是学分
      expect(none.declaredCreditsFromNotes, isNull);
    });

    test('门数板块（isCountRule）绝不冒充学分', () {
      const count = PdfModuleSection(
          title: '选修课程',
          level: 4,
          creditsRaw: '2',
          creditsUnit: '门',
          notes: ['修读2学分'],
          courses: []);
      expect(count.declaredCreditsFromNotes, isNull);
    });
  });
}
