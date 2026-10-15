// test/zju_parse_ext_test.dart — 专业识别/方案匹配/打印页解析/实践分单测。
import 'package:test/test.dart';

import 'package:compass_app/data/zju_parse_ext.dart';

void main() {
  group('专业识别', () {
    test('键值对提取（过滤院系值）', () {
      final m = majorFromKeyValuePairs({
        '学院': '计算机学院', '专业名称': '计算机科学与技术', '班级': '计算机2301',
      });
      expect(m, '计算机科学与技术');
    });
    test('班级名兜底（归一化到全称）', () {
      expect(majorFromClassName('2023级软件工程02班'), '软件工程');
      expect(majorFromClassName('计算机2301'), '计算机科学与技术');
      expect(majorFromClassName('2023级工科试验班（信息）2601班'), '工科试验班(信息)');
      expect(majorFromClassName('工信2601'), '工科试验班(信息)');
      expect(majorFromClassName('软件工程(丹青)2302班'), '软件工程');
      expect(majorFromClassName('未知'), isNull);
    });
    test('Bootstrap label+form-control-static 解析（N105515 版式）', () {
      const html = '''
      <div class="form-group">
        <label class="col-sm-2">专业名称 :</label>
        <p class="col-sm-10 form-control-static">软件工程</p>
      </div>
      <div class="form-group">
        <label>年级 :</label>
        <p class="form-control-static">2023</p>
      </div>''';
      final pairs = parseHtmlKeyValuePairs(html);
      expect(pairs['专业名称'], '软件工程');
      expect(majorFromKeyValuePairs(pairs), '软件工程');
    });
    test('th/td 跨行键值对解析', () {
      const html = '<table><tr><th>专业</th></tr><tr><td>计算机科学与技术</td></tr></table>';
      expect(majorFromKeyValuePairs(parseHtmlKeyValuePairs(html)),
          '计算机科学与技术');
    });
    test('归一化与方案匹配', () {
      expect(normalizeMajorName('计科'), '计算机科学与技术');
      expect(normalizeMajorName('2023级软工'), '软件工程');
      expect(normalizeMajorName('软件工程2201班'), '软件工程');
      expect(normalizeMajorName('社科'), '社会科学试验班');
      expect(matchPlanKey('计算机科学与技术', ['computer_science', 'software_engineering']),
          'computer_science');
      expect(matchPlanKey('软件工程', ['computer_science', 'software_engineering']),
          'software_engineering');
      expect(matchPlanKey('物理学', ['computer_science']), isNull);
    });
  });

  group('方案列表匹配', () {
    test('年级+名称择优', () {
      final items = [
        {'pyfa_id': '1', 'zymc': '计算机科学与技术', 'nj': '2022'},
        {'pyfa_id': '2', 'zymc': '计算机科学与技术', 'nj': '2023'},
        {'pyfa_id': '3', 'zymc': '软件工程', 'nj': '2023'},
      ];
      final best = pickBestPlan(items, grade: '2023', majorName: '计算机科学与技术');
      expect(best!['pyfa_id'], '2');
    });
    test('名称无交集不选', () {
      final items = [
        {'pyfa_id': '1', 'zymc': '软件工程', 'nj': '2023'},
      ];
      expect(pickBestPlan(items, majorName: '物理学'), isNull);
    });
    test('试验班核心名匹配 + 往届方案偏好', () {
      final items = [
        {'pyfa_id': '1', 'zymc': '计算机科学与技术', 'njdm_id': '2021'},
        {'pyfa_id': '2', 'zymc': '计算机', 'njdm_id': '2022'},
        {'pyfa_id': '3', 'zymc': '工科试验班', 'njdm_id': '2023'},
      ];
      // 目标"计算机科学与技术"，年级 2023：1 号名称完全匹配(100)往届(+15)=115；
      // 3 号名称无关不参选。应选 1 号。
      final best = pickBestPlan(items,
          majorName: '计算机科学与技术', grade: '2023');
      expect(best!['pyfa_id'], '1');
    });
    test('pyfamc 方案名包含匹配', () {
      final items = [
        {'pyfa_id': '9', 'zymc': '', 'pyfamc': '2023级软件工程培养方案'},
      ];
      final best = pickBestPlan(items, majorName: '软件工程', grade: '2023');
      expect(best!['pyfa_id'], '9');
    });
  });

  group('变体与评分', () {
    test('括号变体', () {
      expect(majorNameVariants('工科试验班(信息)'),
          contains('工科试验班（信息）'));
      expect(majorNameVariants('软件工程').length, 1);
    });
    test('planScore 未来年级惩罚', () {
      final s = planScore({'zymc': '软件工程', 'njdm_id': '2025'},
          targetMajor: '软件工程', targetGrade: '2023');
      expect(s, closeTo(100 - 20, 0.01)); // 名称完美 100，未来年级 -20
    });
    test('planScore 无关专业返回负', () {
      expect(planScore({'zymc': '数学'}, targetMajor: '物理'), -1);
    });
  });

  group('打印页解析', () {
    final html = '''
      <html><body>
      <div>计算机科学与技术专业培养方案（2023级）</div>
      <div>最低毕业学分：160</div>
      <div>通识必修课 34学分 专业必修课 45学分 集中实践 16学分</div>
      <table>
        <tr><td>序号</td><td>课程名称</td><td>学分</td><td>开课学期</td></tr>
        <tr><td>1</td><td>程序设计基础</td><td>4</td><td>秋</td></tr>
        <tr><td>2</td><td>数据结构与算法</td><td>4</td><td>春</td></tr>
        <tr><td>3</td><td>体育（基础）</td><td>1</td><td>秋</td></tr>
        <tr><td>4</td><td>生产实习</td><td>2</td><td>春</td></tr>
      </table>
      </body></html>''';

    test('总学分+模块声明+课程行', () {
      final plan = parsePlanPrintHtml(html, pyfaId: 'P1', majorName: '计算机科学与技术');
      expect(plan['meta']['total_credits'], 160);
      final modules = (plan['modules'] as List).cast<Map<String, dynamic>>();
      final byId = {for (final m in modules) m['module_id'] as String: m};
      expect(byId['general_required']!['required_credits'], 34.0);
      expect(byId['major_core']!['required_credits'], 45.0);
      expect(byId['intensive_practice']!['required_credits'], 16.0);
      final courses = (plan['courses'] as List).cast<Map<String, dynamic>>();
      expect(courses.length, 4);
      final names = courses.map((c) => c['name']).toSet();
      expect(names.contains('程序设计基础'), isTrue);
      expect(names.contains('体育（基础）'), isTrue);
      // 模块归类：体育→通识必修，生产实习→集中实践
      final pe = courses.firstWhere((c) => c['name'] == '体育（基础）');
      expect(pe['module_id'], 'general_required');
      final sx = courses.firstWhere((c) => c['name'] == '生产实习');
      expect(sx['module_id'], 'intensive_practice');
      // 4 门课 < 15 → 正确触发"疑似不完整"质量警告（真实方案几十门）
      expect(plan['meta']['verified'], isFalse);
      expect((plan['meta']['quality'] as List).join(';'), contains('疑似不完整'));
    });

    test('空页面产出质量警告', () {
      final plan = parsePlanPrintHtml('<html><body>空</body></html>', pyfaId: 'X');
      expect((plan['meta']['quality'] as List).length, greaterThanOrEqualTo(2));
      expect((plan['courses'] as List).isEmpty, isTrue);
    });
  });

  group('实践分解析', () {
    test('表格行主模式', () {
      final html = '''
        <table>
        <tr><td>项目</td><td>分数</td></tr>
        <tr><td>第二课堂</td><td>2.5</td></tr>
        <tr><td>第三课堂</td><td>1.8</td></tr>
        <tr><td>第四课堂</td><td>0.6</td></tr>
        </table>''';
      final s = parsePracticeScores(html);
      expect(s['第二课堂'], 2.5);
      expect(s['第三课堂'], 1.8);
      expect(s['第四课堂'], 0.6);
    });
    test('兜底模式（td 相邻）', () {
      final html = '<table><tr><td>第二课堂</td><td>3.0</td></tr></table>';
      final s = parsePracticeScores(html);
      expect(s['第二课堂'], 3.0);
    });
  });
}
