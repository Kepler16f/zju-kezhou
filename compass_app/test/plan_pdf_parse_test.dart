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
}
