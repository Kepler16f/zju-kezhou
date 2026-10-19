// test/teacher_rating_test.dart — 教师评分本地表：加载/归一/未命中/脏数据健壮性。
//
// 红线：零网络——本文件只验证本地表解析；资产灌入由主线负责，格式见 assets/data/teacher_ratings.json。
import 'package:flutter_test/flutter_test.dart';

import 'package:compass_app/data/teacher_rating.dart';

void main() {
  group('normalizeTeacherName', () {
    test('trim + 去多余空白（含全角）+ 小写', () {
      expect(normalizeTeacherName('  张三 '), '张三');
      expect(normalizeTeacherName('张 三\u3000\t李'), '张三李');
      expect(normalizeTeacherName('Zhang San'), 'zhangsan');
      expect(normalizeTeacherName('ZHANGSAN'), 'zhangsan');
      expect(normalizeTeacherName(''), '');
    });
  });

  group('TeacherRatingStore.fromJson', () {
    test('结构示例加载：键归一化入表，lookup 精确/归一化都命中', () {
      final store = TeacherRatingStore.fromJson(const {
        '示例教师': {'avg': 4.2, 'count': 10, 'tags': <String>[], 'source': '查老师'},
        ' 张 三 ': {'avg': 3.8, 'count': 25, 'tags': ['给分好']},
      });
      expect(store.length, 2);
      expect(store.lookup('示例教师', null)?.avg, 4.2);
      expect(store.lookup('张三', '数据结构')?.avg, 3.8); // 归一化命中
      expect(store.lookup('张三', null)?.count, 25);
      expect(store.lookup('张三', null)?.tags, ['给分好']);
      expect(store.lookup('张三', null)?.source, '查老师');
    });

    test('lookup 未命中返回 null（空/空白教师名同样 null）', () {
      final store = TeacherRatingStore.fromJson(const {
        '张三': {'avg': 4.0},
      });
      expect(store.lookup('李四', null), isNull);
      expect(store.lookup('', null), isNull);
      expect(store.lookup('   ', null), isNull);
      expect(TeacherRatingStore.empty.lookup('张三', '任意课'), isNull);
    });

    test('lookupAny：多教师串（<br> 清洗后的 /、顿号、逗号）逐个命中', () {
      final store = TeacherRatingStore.fromJson(const {
        '祝一虹': {'avg': 9.1, 'count': 30},
      });
      expect(store.lookupAny('谭芸 / 祝一虹', null)?.avg, 9.1);
      expect(store.lookupAny('谭芸、祝一虹', null)?.avg, 9.1);
      expect(store.lookupAny('谭芸,祝一虹', null)?.avg, 9.1);
      expect(store.lookupAny('谭芸 / 李四', null), isNull);
      expect(store.lookupAny('', null), isNull);
    });

    test('脏数据逐条跳过、绝不抛：非 Map / avg 缺失 / 越界 / 非数值 / NaN / Infinity',
        () {
      final store = TeacherRatingStore.fromJson(const {
        '脏1': 'not-a-map', // 值非 Map
        '脏2': {'avg': null}, // avg 缺失
        '脏3': {'avg': 10.1}, // 越界（>10，站点十分制上限）
        '脏4': {'avg': -1}, // 越界（<0）
        '脏5': {'avg': 'abc'}, // 非数值
        '': {'avg': 4.0}, // 空教师名
        '好1': {'avg': '9.39', 'count': '422'}, // 字符串数值：可解析则收
        '好2': {'avg': 8}, // int 分：收；count 缺省 → 0
      });
      expect(store.length, 2);
      expect(store.lookup('好1', null)?.avg, 9.39);
      expect(store.lookup('好1', null)?.count, 422);
      expect(store.lookup('好2', null)?.count, 0);
    });

    test('NaN/Infinity 等浮点脏值丢弃（非 const 场景）', () {
      final store = TeacherRatingStore.fromJson({
        'nan': {'avg': double.nan},
        'inf': {'avg': double.infinity},
        'ok': {'avg': 4.0, 'count': double.nan}, // count 脏 → 按 0
      });
      expect(store.length, 1);
      expect(store.lookup('ok', null)?.count, 0);
    });

    test('顶层非 Map（List/String/null）→ 空表', () {
      expect(TeacherRatingStore.fromJson(const [1, 2]).length, 0);
      expect(TeacherRatingStore.fromJson('abc').length, 0);
      expect(TeacherRatingStore.fromJson(null).length, 0);
    });

    test('fromSerialized：坏 JSON / null → 空表且不抛', () {
      expect(TeacherRatingStore.fromSerialized('{坏JSON').isEmpty, isTrue);
      expect(TeacherRatingStore.fromSerialized(null).isEmpty, isTrue);
      expect(
          TeacherRatingStore.fromSerialized('{"张三":{"avg":4.2,"count":10}}')
              .lookup('张三', null)
              ?.avg,
          4.2);
    });

    test('source 缺省/空串 → 统一「查老师」', () {
      final store = TeacherRatingStore.fromJson(const {
        'a': {'avg': 4.0},
        'b': {'avg': 4.0, 'source': '  '},
      });
      expect(store.lookup('a', null)?.source, kTeacherRatingSource);
      expect(store.lookup('b', null)?.source, kTeacherRatingSource);
    });
  });

  group('displayText 展示口径', () {
    test('命中：评分 9.4/10（422 人评 · 查老师）', () {
      const r = TeacherRating(teacher: '毕惟红', avg: 9.4, count: 422);
      expect(r.displayText, '评分 9.4/10（422 人评 · 查老师）');
    });
    test('整数分保留一位小数（十分制直取不折算）', () {
      const r = TeacherRating(teacher: '张三', avg: 8, count: 3);
      expect(r.displayText, '评分 8.0/10（3 人评 · 查老师）');
    });
  });
}
