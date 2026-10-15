// test/plan_models_test.dart — 培养方案匹配器纯函数单测（0.10.7 取数修复的回归护栏）。
//
// 关键回归点：旧实现的三大 bug 各自对应下面一个用例——
//  1. 列表接口参数用了 zymc/njdm_id（服务端不认）→ 响应是 HTML 错误页；
//  2. 年级取行政班"末两位"（2606 → 2006）→ 年级一错、方案全错；
//  3. pickBestPlan 只认 pyfa_id/id，而接口给的是 pyfaxx_id/jxjhh → 永远挑不到方案。
import 'package:test/test.dart';

import 'package:compass_app/data/plan_models.dart';

/// 一条真实的方案行（字段名与正方 pyfaxxcx_cxPyfaxscxIndex 返回完全一致）。
Map<String, dynamic> planRow({
  String zymc = '信息安全',
  String zydm = '2116',
  String synj = '2026',
  String jxjhh = '20262116100',
  String pyfaxxId = '800001',
  String xymc = '计算机科学与技术学院',
  String dlbsmc = '专业',
  double zdbyxf = 140.5,
  String zydlmc = '工科试验班（计算机）',
}) =>
    <String, dynamic>{
      'pyfaxx_id': pyfaxxId,
      'jxjhh': jxjhh,
      'zymc': zymc,
      'zydm': zydm,
      'xymc': xymc,
      'xydm': '21',
      'zydlmc': zydlmc,
      'zydlmc2': zydlmc,
      'zydldm': '1103',
      'dlbsmc': dlbsmc,
      'synj': synj,
      'xz': '4',
      'syxw': '工学',
      'xqmc': '玉泉校区',
      'gjzymc': '信息安全',
      'xkzylb': '计算机类',
      'tjzt': '已审核',
      'zdbyxf': zdbyxf,
      'kcdlxfyq': zdbyxf,
      'dektxf': '4',
      'dektxf3': '2',
      'dektxf4': '2',
      'fxxf': '26.5',
      'exwxf': '67',
      'wfxxf': '11',
      'rs': 270,
      'sjrs': 255,
      'pymb': '本专业培养信息安全领域的高素质人才。',
      'pyyq': '掌握密码学、系统安全、网络安全等基本理论。',
      'bz': '微辅修11学分……',
      'dektbz': '第二课堂要求……',
      'zyhxkc': '密码学  网络安全  操作系统  计算机网络  数据结构基础',
      'zyhxsjkc': '信息安全综合实践Ⅰ  信息安全综合实践Ⅱ',
      'qywkc': '网络空间安全导论',
    };

void main() {
  group('splitCourseNames / normalizePlanName', () {
    test('两个以上空格分隔的课程名串', () {
      expect(splitCourseNames('密码学  网络安全  操作系统'),
          ['密码学', '网络安全', '操作系统']);
    });
    test('只有单空格时退回顿号/逗号分隔（避免把长课程名切开）', () {
      expect(splitCourseNames('密码学、网络安全｜操作系统'.replaceAll('｜', ',')),
          ['密码学', '网络安全', '操作系统']);
    });
    test('空串与全空白', () {
      expect(splitCourseNames('   '), isEmpty);
    });
    test('归一化：全角括号/空白/大小写差异不影响相等', () {
      expect(normalizePlanName('工科试验班（计算机）'),
          normalizePlanName(' 工科试验班 ( 计算机 ) '));
    });
  });

  group('gradeFromClassName（旧实现把 2606 读成 2006）', () {
    test('行政班尾四位 = 年级 + 班号', () {
      expect(gradeFromClassName('工科试验班（计算机）2606'), '2026');
      expect(gradeFromClassName('信息安全2401'), '2024');
      expect(gradeFromClassName('软件工程（信息）2202班'), '2022');
    });
    test('没有尾四位数字时为 null', () {
      expect(gradeFromClassName('工科试验班'), isNull);
      expect(gradeFromClassName(null), isNull);
    });
  });

  group('PlanSummary.fromRow', () {
    test('字段/列表/数字都解析出来', () {
      final p = PlanSummary.fromRow(planRow());
      expect(p.zymc, '信息安全');
      expect(p.zydm, '2116');
      expect(p.id, '800001');
      expect(p.synj, '2026');
      expect(p.zdbyxf, 140.5);
      expect(p.creditsLabel, '140.5 学分');
      expect(p.xz, '4');
      expect(p.isMajorPlan, isTrue);
      expect(p.zyhxkc.length, 5);
      expect(p.zyhxsjkc, ['信息安全综合实践Ⅰ', '信息安全综合实践Ⅱ']);
      expect(p.rs, 270);
      expect(p.subtitle.contains('2026 级'), isTrue);
    });
    test('未知/空占位值不残留', () {
      final p = PlanSummary.fromRow({'zymc': '信息安全', 'xymc': '未知', 'xz': '  '});
      expect(p.xymc, '');
      expect(p.xz, '');
      expect(p.id, ''); // 无 id 的行会被目录解析丢弃
    });
    test('辅修方案不算主修方案', () {
      final p = PlanSummary.fromRow(planRow(dlbsmc: '辅修'));
      expect(p.isMajorPlan, isFalse);
    });
  });

  group('matchPlans', () {
    final catalog = [
      PlanSummary.fromRow(planRow()),
      PlanSummary.fromRow(planRow(synj: '2024', jxjhh: '20242116100', pyfaxxId: '800002')),
      PlanSummary.fromRow(planRow(
          zymc: '信息安全（数字安全方向）',
          synj: '2026',
          jxjhh: '20262116200',
          pyfaxxId: '800003')),
      PlanSummary.fromRow(planRow(
          zymc: '计算机科学与技术', zydm: '2112', synj: '2026', jxjhh: '20262112100', pyfaxxId: '800004')),
      PlanSummary.fromRow(planRow(
          zymc: '工科试验班（计算机）',
          zydm: '1103',
          synj: '2026',
          jxjhh: '20261103100',
          pyfaxxId: '800005')),
      PlanSummary.fromRow(planRow(
          zymc: '软件工程', zydm: '2113', synj: '2026', jxjhh: '20262113100', pyfaxxId: '800006')),
    ];

    test('专业全称 + 本人年级 排第一', () {
      final r = matchPlans(catalog, majorName: '信息安全', grade: '2026');
      expect(r.best!.plan.zymc, '信息安全');
      expect(r.best!.plan.synj, '2026');
      expect(r.best!.level, PlanMatchLevel.exact);
      expect(r.best!.gradeMatch, isTrue);
      expect(r.isEmpty, isFalse);
    });

    test('同年级前缀变体（方向班）也在候选里，且不抢走全称第一位', () {
      final r = matchPlans(catalog, majorName: '信息安全', grade: '2026');
      final names = r.candidates.map((c) => c.plan.zymc).toList();
      expect(names.first, '信息安全');
      expect(names.contains('信息安全（数字安全方向）'), isTrue);
      expect(names.contains('软件工程'), isFalse);
    });

    test('本人年级没有方案时退到往届并给出提示', () {
      final only2024 = [
        PlanSummary.fromRow(planRow(synj: '2024', jxjhh: '20242116100')),
      ];
      final r = matchPlans(only2024, majorName: '信息安全', grade: '2026');
      expect(r.best!.plan.synj, '2024');
      expect(r.best!.gradeMatch, isFalse);
      expect(r.notes.any((n) => n.contains('往届')), isTrue);
    });

    test('名称指向前缀的相近方案 → 判为歧义（需要用户点选）', () {
      final two = [
        PlanSummary.fromRow(planRow(jxjhh: 'A1', pyfaxxId: 'A')),
        PlanSummary.fromRow(planRow(
            zymc: '信息安全（数字安全方向）', jxjhh: 'B1', pyfaxxId: 'B')),
      ];
      final r = matchPlans(two, majorName: '信息安全', grade: '2026');
      expect(r.candidates.length, 2);
      expect(r.ambiguous, isTrue);
      expect(r.alternatives.length, 1);
      expect(r.notes.any((n) => n.contains('相近方案') && n.contains('点选确认')), isTrue);
    });

    // 两种情形必须分开断言（2026-10-15 修正：原用例把它们混在一起，互相矛盾）：
    //  * 专业方案只是“在大类名里出现” → category（绝不能冒充专业全称命中）；
    //  * 方案名与查询名逐字相同 → exact，即使这个名字本身是大类名。
    //    若降级为 category，大类方案会输给“大类名命中 + 主修加成”的专业方案，
    //    反而把按大类招生的学生错配到某个具体专业方案上。
    test('专业方案只在大类名里命中 → category（不误判为专业全称）', () {
      final r = matchPlans(catalog, majorName: '工科试验班（计算机）', grade: '2026');
      final infoSec = r.candidates.firstWhere((c) => c.plan.zymc == '信息安全');
      expect(infoSec.level, PlanMatchLevel.category);
      expect(infoSec.plan.zydm, '2116');
    });

    test('方案名与查询名逐字相同 → exact（即使该名是大类名）', () {
      final r = matchPlans(catalog, majorName: '工科试验班（计算机）', grade: '2026');
      expect(r.best!.plan.zydm, '1103');
      expect(r.best!.level, PlanMatchLevel.exact);
    });

    test('完全不相关 → 空候选 + 可读提示', () {
      final r = matchPlans(catalog, majorName: '临床医学', grade: '2026');
      expect(r.isEmpty, isTrue);
      expect(r.best, isNull);
      expect(r.notes.first.contains('临床医学'), isTrue);
    });

    test('专业名为空 → 不返回任何候选（不猜）', () {
      final r = matchPlans(catalog, majorName: '', grade: '2026');
      expect(r.isEmpty, isTrue);
    });

    test('同一方案重复出现只保留一条', () {
      final dup = [
        PlanSummary.fromRow(planRow()),
        PlanSummary.fromRow(planRow()),
      ];
      expect(matchPlans(dup, majorName: '信息安全', grade: '2026').candidates.length, 1);
    });
  });

  group('searchPlans / findPlanById', () {
    // 软件工程这条必须显式覆盖 gjzymc/zydlmc：planRow 默认值里
    // gjzymc='信息安全'、zydlmc='工科试验班（计算机）'，否则它会“蹭”上
    // 「信息安全」这个关键词，把“按专业名搜索”的断言带偏。
    final catalog = [
      PlanSummary.fromRow(planRow()),
      PlanSummary.fromRow(planRow(
              zymc: '软件工程', zydm: '2113', jxjhh: '20262113100', xymc: '软件学院')
          ..['gjzymc'] = '软件工程'
          ..['zydlmc'] = '软件工程类'
          ..['zydlmc2'] = '软件工程类'),
    ];
    test('按专业名搜索', () {
      expect(searchPlans(catalog, '信息安全').length, 1);
    });
    test('按学院搜索', () {
      expect(searchPlans(catalog, '软件学院').first.zymc, '软件工程');
    });
    test('按教学计划号精确取', () {
      expect(findPlanById(catalog, '20262113100')!.zymc, '软件工程');
      expect(findPlanById(catalog, '不存在的号'), isNull);
    });
  });

  group('planFileFromSummary（摘要 → 审计 PlanFile）', () {
    test('核心课进 major_core、实践课进 intensive_practice', () {
      final p = PlanSummary.fromRow(planRow());
      final file = planFileFromSummary(p, grade: '2026');
      final modules = (file['modules'] as List).cast<Map<String, dynamic>>();
      final ids = modules.map((m) => m['module_id']).toList();
      expect(ids.contains('major_core'), isTrue);
      expect(ids.contains('intensive_practice'), isTrue);
      final courses = (file['courses'] as List).cast<Map<String, dynamic>>();
      expect(courses.length, 8); // 5 核心 + 2 实践 + 1 前沿
      expect(file['meta']['total_credits'], 140.5);
      expect(file['meta']['verified'], isFalse);
      expect((file['meta']['quality'] as List).length, greaterThan(0));
    });

    test('成绩单同名课程补真实学分，未修课程记 0 分并在质量里说明', () {
      final p = PlanSummary.fromRow(planRow());
      final file = planFileFromSummary(p, grade: '2026', transcript: [
        {'name': '密码学', 'credits': 3.0},
        {'name': '操作系统', 'credits': 4.5},
      ]);
      final courses = (file['courses'] as List).cast<Map<String, dynamic>>();
      final byName = {for (final c in courses) c['name'] as String: c};
      expect((byName['密码学']!['credits'] as num).toDouble(), 3.0);
      expect((byName['操作系统']!['credits'] as num).toDouble(), 4.5);
      expect((byName['数据结构基础']!['credits'] as num).toDouble(), 0.0);
      expect(
          (file['meta']['quality'] as List)
              .any((q) => q.toString().contains('学分未知')),
          isTrue);
    });
  });

  group('StudentProfile', () {
    test('课表接口平铺字段 + 年级推断', () {
      final p = StudentProfile.fromJson({
        'zy': '信息安全',
        'xy': '求是学院云峰学园',
        'xzb': '工科试验班（计算机）2606',
        'xh': '3260009999',
        'xm': '某同学',
        'xnm': '2026-2027',
        'xqm': '3',
      });
      expect(p.majorName, '信息安全');
      expect(p.college, '求是学院云峰学园');
      expect(p.grade, '2026');
      expect(p.semester, '2026-2027-3');
      expect(p.isEmpty, isFalse);
    });
    test('xsxx 嵌套形态也能解析（老实例）', () {
      final p = StudentProfile.fromJson({
        'xsxx': {'zy': '软件工程', 'xzb': '软件工程2201'},
      });
      expect(p.majorName, '软件工程');
      expect(p.grade, '2022');
    });
    test('空响应', () {
      expect(StudentProfile.fromJson(const {}).isEmpty, isTrue);
    });
  });

  group('PlanCourseRow', () {
    test('教务键名归一化', () {
      final r = PlanCourseRow.fromRow({
        'kcmc': '密码学',
        'kcdm': 'CS3001',
        'xf': '3.0',
        'kkxq': '秋冬',
        'kcxzmc': '专业必修',
        'jsxm': '张三',
      });
      expect(r.name, '密码学');
      expect(r.code, 'CS3001');
      expect(r.credits, 3.0);
      expect(r.semester, '秋冬');
      expect(r.nature, '专业必修');
      expect(r.teacher, '张三');
      expect(r.isEmpty, isFalse);
    });
    test('没有课程名 → isEmpty（用于过滤无权限的空包）', () {
      expect(PlanCourseRow.fromRow(const {'xf': '3'}).isEmpty, isTrue);
    });
  });
}