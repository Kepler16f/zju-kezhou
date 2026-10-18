// test/plan_pdf_parse_test.dart — 方案 PDF 结构化解析单测（合成数据 + 真实 PDF）。
import 'dart:io';
import 'package:test/test.dart';
import 'package:compass_app/data/pdf_text_extractor.dart';
import 'package:compass_app/data/plan_pdf_parse.dart';

void main() {
  group('合成数据', () {
    test('四级层级 + 课程表 + 修读说明', () {
      const text = '''
课程设置与学分分布
一、通识课程                72.5学分
1.通识必修课程              62学分
(1)思政类                14学分
   1)必修课程                12学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)
MARX1005G 新时代实践教育 2.0 +2 64 一(短)
   2)选修课程                2学分
    在思政类“选择性必修课程”中至少修读2学分，建议一年级学生修读。
(2)军体类                11.5学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
ADMN1001G 军训 2.0 +3 168 一(秋)
二、专业课程                40.5学分
(1)专业必修课程                24.5学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
BEFS1039M 食品科学导论* 1.5 1.5-0.0 24 一(夏)
''';
      final r = parsePlanPdfText(text);
      final titles = r.sections.map((s) => s.title).toList();
      expect(titles, ['通识课程', '通识必修课程', '思政类', '必修课程', '选修课程', '军体类', '专业课程', '专业必修课程']);

      // 层级与上级链
      expect(r.sections[0].level, 1);
      expect(r.sections[0].creditsRaw, '72.5');
      expect(r.sections[3].level, 4);
      expect(r.sections[3].parentPath, '通识课程 · 通识必修课程 · 思政类');
      expect(r.topCount, 2);

      // 课程归属：各归其最近的板块
      expect(r.sections[3].courses.map((c) => c.code), ['MARX1004G', 'MARX1005G']);
      expect(r.sections[3].courses[0].name, '大学生思想文化素养');
      expect(r.sections[3].courses[0].semester, '一(秋冬)');
      expect(r.sections[3].courses[1].hours, '+2');
      expect(r.sections[5].courses.single.code, 'ADMN1001G');
      expect(r.sections[7].courses.single.name, '食品科学导论*');
      expect(r.courseCount, 4);

      // 修读说明归到 2)选修课程（提到"思政类"但该板块已在前）
      expect(r.sections[4].notes.single, contains('选择性必修课程'));
      // 学分区间
      expect(r.sections.where((s) => s.title == '军体类').single.creditsRaw, '11.5');
    });

    test('空输入安全', () {
      final r = parsePlanPdfText('');
      expect(r.isEmpty, isTrue);
      expect(r.qualityNotes, isNotEmpty);
    });

    test('乱码行跳过', () {
      const text = '''
一、通识课程 10学分
  1)必修课程 12学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
ßTÁyÑ[fN]åz\\^NßTÁyÑ[f0uT}yÑ[f0Q[f0S
MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)
''';
      final r = parsePlanPdfText(text);
      final courses = r.sections.expand((s) => s.courses).toList();
      expect(courses.length, 1);
      expect(courses.single.name, '大学生思想文化素养');
    });

    test('说明行先于板块标题出现（双栏版式）归后一板块', () {
      const text = '''
一、通识课程 10学分
1.通识必修课程 10学分
(1)军体类 6学分
    学生应于前三年在体育课中选修6学分。详见《浙江大学本科生体育课程修读办法》。
(2)外语类 3-6学分
    外语类课程实行阶梯式学分修读要求，根据学生英语能力划分为 L1、L2、L3 层次。
''';
      final r = parsePlanPdfText(text);
      final pe = r.sections.firstWhere((s) => s.title == '体育课', orElse: () => r.sections.first);
      // 军体类说明里的"外语类"出现在紧随其后的标题里 → 归外语类
      final wai = r.sections.firstWhere((s) => s.title == '外语类');
      expect(wai.notes.single, contains('阶梯式'));
      // "体育课"说明留在军体类
      final jun = r.sections.firstWhere((s) => s.title == '军体类');
      expect(jun.notes.single, contains('体育课'));
      expect(pe, isNotNull);
    });

    test('无前置板块时课程不落地（不会挂错）', () {
      const text = '课程号 课程名称 学分 周学时 总学时 建议学年学期\n'
          'MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)';
      final r = parsePlanPdfText(text);
      expect(r.courseCount, 0);
    });

    test('通识选修「N门」子规则行：各成板块、课程按紧邻归属', () {
      const text = '''
课程设置与学分分布
一、通识课程                72.5学分
2.通识选修课程                10.5学分
    通识选修课程修读要求为：
   1)至少修读1门通识核心课程                1门
   2)至少修读1门“博雅技艺”类课程；本专业要求在以下《大学写作》课程中必修1门                1门
课程号 课程名称 学分 周学时 总学时 建议学年学期
PHIL0701G 大学写作——写作・人 1.5 1.0-1.0 32 一(秋冬)
   3)理工农医学生在人文社科等四类中至少修读2门                2门
课程号 课程名称 学分 周学时 总学时 建议学年学期
HUMN1001G 人文示例课 2.0 2.0-0.0 32 一(秋冬)
SOCN1002G 社科示例课 2.0 2.0-0.0 32 二(春夏)
''';
      final r = parsePlanPdfText(text);
      final titles = r.sections.map((s) => s.title).toList();
      expect(titles, [
        '通识课程',
        '通识选修课程',
        '至少修读1门通识核心课程',
        '至少修读1门“博雅技艺”类课程；本专业要求在以下《大学写作》课程中必修1门',
        '理工农医学生在人文社科等四类中至少修读2门',
      ]);

      // 层级与上级链：门规则行仍走四级槽位
      final gen = r.sections[1];
      final r1 = r.sections[2], r2 = r.sections[3], r3 = r.sections[4];
      expect(gen.level, 2);
      for (final s in [r1, r2, r3]) {
        expect(s.level, 4, reason: s.title);
        expect(s.parentPath, '通识课程 · 通识选修课程', reason: s.title);
      }

      // 单位标记：父板块是学分，门子规则是"门"
      expect(gen.creditsUnit, '学分');
      expect(gen.isCountRule, isFalse);
      for (final s in [r1, r2, r3]) {
        expect(s.creditsUnit, '门', reason: s.title);
        expect(s.isCountRule, isTrue, reason: s.title);
      }
      expect(r1.creditsRaw, '1');
      expect(r3.creditsRaw, '2');

      // 课程表紧邻归属：不全并到父板块
      expect(r1.courses, isEmpty, reason: '规则1无自己的课程表 → 空课程板块');
      expect(r1.title, '至少修读1门通识核心课程'); // 要求文字保留在标题里
      expect(r2.courses.map((c) => c.code), ['PHIL0701G']);
      expect(r3.courses.map((c) => c.code), ['HUMN1001G', 'SOCN1002G']);
      expect(gen.courses, isEmpty);
      expect(gen.notes.single, contains('通识选修课程修读要求为'));
    });

    test('以「N门」收尾的正文说明句不误判为子规则板块', () {
      const text = '''
一、通识课程 72.5学分
2.通识选修课程 10.5学分
学生应修读若干门课程，详见《通识选修课程修读说明》。
2)跨专业课程须经学院审核认定，总计不超过 6 门
这一句正文说明很长中间没有任何句读逗号句号都没有只是恰好以一个数字加一个门字收尾用来验证长度防护应当把这类行拒绝掉而不是识别成子规则板块 4门
1)至少修读1门通识核心课程 1门
''';
      final r = parsePlanPdfText(text);
      final titles = r.sections.map((s) => s.title).toList();
      expect(titles, ['通识课程', '通识选修课程', '至少修读1门通识核心课程']);
      // 被拒的正文行留在父板块说明里
      final gen = r.sections[1];
      final notes = gen.notes.join('\n');
      expect(notes, contains('详见《通识选修课程修读说明》'));
      expect(notes, contains('跨专业课程'));
      expect(notes, contains('长度防护'));
    });

    test('「学分」收尾的四级行不受影响（creditsUnit 默认学分）', () {
      const text = '''
一、通识课程 72.5学分
1.通识必修课程 62学分
(1)思政类 14学分
   1)必修课程 12学分
课程号 课程名称 学分 周学时 总学时 建议学年学期
MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)
''';
      final r = parsePlanPdfText(text);
      final s = r.sections[3];
      expect(s.title, '必修课程');
      expect(s.creditsUnit, '学分');
      expect(s.isCountRule, isFalse);
      expect(s.credits, 12);
      expect(s.courses.single.code, 'MARX1004G');
    });

    test('无中文序号版式：「N门」规则行随层级自适应上移（四级→三级）', () {
      const text = '''
1.通识选修课程 10.5学分
   1)至少修读1门通识核心课程 1门
''';
      final r = parsePlanPdfText(text);
      expect(r.sections[0].level, 1);
      expect(r.sections[1].level, 3);
      expect(r.sections[1].creditsUnit, '门');
      expect(r.sections[1].isCountRule, isTrue);
    });
  });

  group('真实方案 PDF', skip: !File(
          'C:/Users/胡天泽/AppData/Roaming/edu.zju.compass/compass_app/compass/cache_planpdf_20261321.pdf')
      .existsSync() ? '沙箱无缓存 PDF' : false, () {
    test('完整抽取+解析（用户诉求：各板块修读要求齐全）', () {
      final bytes = File(
              'C:/Users/胡天泽/AppData/Roaming/edu.zju.compass/compass_app/compass/cache_planpdf_20261321.pdf')
          .readAsBytesSync();
      final text = extractPdfText(bytes);
      final r = parsePlanPdfText(text);
      print('板块层级条目: ${r.sections.length}（一级 ${r.topCount}）');
      for (final s in r.sections) {
        print('  [L${s.level}] ${s.label} ${s.creditsRaw}学分 '
            '课程${s.courses.length}门 说明${s.notes.length}条');
      }
      print('课程数: ${r.courseCount}');

      // 一级板块：通识课程/专业基础课程/专业课程/个性修读课程/其他必修环节/第二三 四课堂
      expect(r.topCount, greaterThanOrEqualTo(6), reason: '一级板块不足');
      final topTitles = r.sections.where((s) => s.level == 1).map((s) => s.title);
      expect(topTitles, contains('通识课程'));
      expect(topTitles, contains('专业基础课程'));
      expect(topTitles, contains('专业课程'));
      expect(topTitles, contains('个性修读课程'));

      // 通识课程下的类目（用户点名的"通识课程的修读要求"）
      final inGeneral = r.sections.where((s) => s.parentPath.startsWith('通识课程'));
      expect(inGeneral.map((s) => s.title), contains('思政类'));
      expect(inGeneral.map((s) => s.title), contains('自然科学通识类'));

      // 修读要求说明（含外语类层次说明、通识选修要求）
      final allNotes = r.sections.expand((s) => s.notes).join('\n');
      expect(allNotes, contains('选择性必修课程'));
      expect(allNotes, contains('通识核心课程'));
      expect(allNotes, contains('L1应修6学分'));

      // 课程表按板块归属
      expect(r.courseCount, greaterThan(60), reason: '课程行不足');
      final withCourses = r.sections.where((s) => s.courses.isNotEmpty).length;
      expect(withCourses, greaterThanOrEqualTo(8), reason: '带课程表的板块不足');

      // 抽查：思政类必修 = MARX 课表
      final marx = r.sections.firstWhere((s) => s.courses.any((c) => c.code == 'MARX1004G'));
      expect(marx.courses.map((c) => c.code), contains('MARX1005G'));
      // 抽查：专业必修含食品化学
      final food = r.sections.firstWhere((s) => s.courses.any((c) => c.name.contains('食品化学')));
      expect(food.parentPath, contains('专业课程'));
    });
  });

  group('全角括号标题（#1 军体/思政、美育/劳育并块修复）', () {
    test('（2）军体类（8学分）式标题被识别为独立板块', () {
      const text = """
一、通识课程（72.5学分）
1.通识必修课程（62学分）
（1）思政类（14学分）
1)必修课程（12学分）
课程号 课程名称 学分 周学时 总学时 建议学年学期
MARX1004G 大学生思想文化素养 2.0 2.0-0.0 32 一(秋冬)
（2）军体类（11.5学分）
课程号 课程名称 学分 周学时 总学时 建议学年学期
ADMN1001G 军训 2.0 +3 168 一(秋)
二、其他必修环节（6学分）
（1）美育类（2学分）
（2）劳育类（2学分）
""";
      final r = parsePlanPdfText(text);
      final titles = r.sections.map((s) => s.title).toList();
      expect(titles, containsAll(['思政类', '军体类', '美育类', '劳育类']));
      final sizheng = r.sections.firstWhere((s) => s.title == '思政类');
      expect(sizheng.creditsRaw, '14');
      final junti = r.sections.firstWhere((s) => s.title == '军体类');
      expect(junti.level, 3);
      expect(junti.creditsRaw, '11.5');
      expect(junti.parentPath, '通识课程 · 通识必修课程');
      // 军体课不再并进思政类
      expect(sizheng.courses, isEmpty);
      final sizhengRequired = r.sections.firstWhere((s) =>
          s.title == '必修课程' && s.parentPath.endsWith('思政类'));
      expect(sizhengRequired.courses.map((c) => c.code), ['MARX1004G']);
      expect(junti.courses.map((c) => c.code), ['ADMN1001G']);
      final meiyu = r.sections.firstWhere((s) => s.title == '美育类');
      final laoyu = r.sections.firstWhere((s) => s.title == '劳育类');
      expect(meiyu.parentPath, '其他必修环节');
      expect(laoyu.parentPath, '其他必修环节');
    });
  });
}
