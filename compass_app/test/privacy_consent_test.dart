// test/privacy_consent_test.dart — 隐私同意门禁（ConsentStore + 首启同意页）与政策正文页。
//
// 锁定的行为：
//  - ConsentStore：accept → isAccepted 为 true；withdraw → false；
//    目录缺失 / 坏 JSON / 字段缺失 一律 false 且不抛异常（启动早期绝不能崩）。
//  - kConsentPolicySha 必须等于随包政策正文 assets/privacy_policy.md 的 sha256 前 12 位
//    （否则"同意记录"与"正文"脱钩，审计无法自证）。
//  - 首启同意页：页内有「同意并继续」「不同意并退出」两个明确选项；
//    同意 → onAccept；不同意 → 弹确认框 → 确认后 onDecline。
//  - 政策正文渲染：标题/段落/列表/加粗/行内代码/围栏代码块可用，
//    表格降级为"单元格以 ｜ 连接"的段落，未知语法降级为纯文本且不抛异常。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:compass_app/data/consent_store.dart';
import 'package:compass_app/pages/privacy_consent_page.dart';
import 'package:compass_app/pages/privacy_policy_page.dart';

/// 同意页测试壳：与生产一致的 M3 主题（深蓝 #1F4E79）。
Widget _wrapConsent({
  required Future<void> Function() onAccept,
  required Future<void> Function() onDecline,
  VoidCallback? onViewPolicy,
}) =>
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4E79)),
        useMaterial3: true,
      ),
      home: PrivacyConsentPage(
        onAccept: onAccept,
        onDecline: onDecline,
        onViewPolicy: onViewPolicy,
      ),
    );

Widget _wrapBody(Widget child) => MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// 取首个包含 [text] 的文本节点的样式（Text 或 RichText 都兼容）。
/// 找不到返回 null——调用方据此断言失败，而不是抛异常掩盖真实原因。
TextStyle? _spanStyle(WidgetTester tester, String text) {
  final finder = find.textContaining(text, findRichText: true);
  if (finder.evaluate().isEmpty) return null;
  final w = tester.widget(finder.first);
  if (w is Text) return w.style;
  if (w is RichText) {
    // Text.rich 的样式落在内部 span 上，外层 RichText.style 只是默认文本样式。
    TextStyle? found;
    void walk(InlineSpan span) {
      if (found != null) return;
      if (span is TextSpan) {
        if (span.text != null && span.text!.contains(text)) {
          found = span.style;
          return;
        }
        for (final c in span.children ?? const <InlineSpan>[]) {
          walk(c);
        }
      }
    }

    walk(w.text);
    return found;
  }
  return null;
}

/// 定位包根目录（含 pubspec.yaml）：从当前工作目录逐级上溯。
Directory _packageRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current;
}

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xffffffff;

/// 极简 SHA-256（纯 Dart，约 50 行）：用来核对 [kConsentPolicySha] 与随包政策正文一致。
/// 刻意不引 crypto 包——pubspec 里没有它（别处代理在改 pubspec.yaml），自写实现避免
/// depend_on_referenced_packages 告警；标准向量在测试里自检。
String _sha256Hex(List<int> data) {
  const List<int> k = <int>[
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];
  final List<int> h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  final List<int> msg = List<int>.from(data);
  final int bitLen = data.length * 8;
  msg.add(0x80);
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (var i = 7; i >= 0; i--) {
    msg.add((bitLen >> (8 * i)) & 0xff);
  }
  final List<int> w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < msg.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final int j = chunk + 4 * i;
      w[i] = ((msg[j] << 24) |
              (msg[j + 1] << 16) |
              (msg[j + 2] << 8) |
              msg[j + 3]) &
          0xffffffff;
    }
    for (var i = 16; i < 64; i++) {
      final int s0 =
          _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 =
          _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }
    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final int t1 = (hh + s1 + ch + k[i] + w[i]) & 0xffffffff;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & 0xffffffff;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }
    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }
  return h.map((e) => e.toRadixString(16).padLeft(8, '0')).join();
}

void main() {
  group('ConsentStore', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('compass_consent_test');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {/* 忽略清理失败 */}
    });

    test('accept → isAccepted 为 true；withdraw → false', () async {
      final store = ConsentStore(sandboxDir: tmp.path);
      expect(await store.isAccepted(), isFalse);

      await store.accept();
      expect(await store.isAccepted(), isTrue);

      await store.withdraw();
      expect(await store.isAccepted(), isFalse);
    });

    test('accept 写入版本 / 同意时间 / 正文摘要三个字段', () async {
      final store = ConsentStore(sandboxDir: tmp.path);
      await store.accept();

      final f = File(p.join(tmp.path, 'consent.json'));
      expect(f.existsSync(), isTrue);
      final raw = jsonDecode(f.readAsStringSync());
      expect(raw, isA<Map<String, dynamic>>());
      final map = raw as Map<String, dynamic>;
      expect(map['policyVersion'], kConsentPolicyVersion);
      expect(map['policySha'], kConsentPolicySha);
      expect(map['acceptedAt'], isA<String>());
      expect((map['acceptedAt'] as String).isNotEmpty, isTrue);
    });

    test('目录不存在时 isAccepted 为 false 且不抛异常', () async {
      final missing = Directory(p.join(tmp.path, 'not_exist_dir'));
      final store = ConsentStore(sandboxDir: missing.path);
      expect(await store.isAccepted(), isFalse);
    });

    test('损坏 JSON 时 isAccepted 为 false 且不抛异常', () async {
      File(p.join(tmp.path, 'consent.json')).writeAsStringSync('{ 这不是 JSON');
      final store = ConsentStore(sandboxDir: tmp.path);
      expect(await store.isAccepted(), isFalse);
    });

    test('字段缺失时 isAccepted 为 false', () async {
      File(p.join(tmp.path, 'consent.json')).writeAsStringSync(
          jsonEncode(<String, Object?>{'policyVersion': kConsentPolicyVersion}));
      final store = ConsentStore(sandboxDir: tmp.path);
      expect(await store.isAccepted(), isFalse);
    });

    test('旧版本政策（policyVersion 不匹配）视为未同意', () async {
      File(p.join(tmp.path, 'consent.json')).writeAsStringSync(jsonEncode(
          <String, Object?>{
            'policyVersion': '0.9',
            'acceptedAt': '2026-10-21T00:00:00.000Z',
            'policySha': kConsentPolicySha,
          }));
      final store = ConsentStore(sandboxDir: tmp.path);
      expect(await store.isAccepted(), isFalse);
    });

    test('withdraw 在文件不存在时不抛异常', () async {
      final store = ConsentStore(sandboxDir: tmp.path);
      await store.withdraw();
      expect(await store.isAccepted(), isFalse);
    });
  });

  group('kConsentPolicySha 与随包政策正文', () {
    test('SHA-256 实现自检（标准向量）', () {
      expect(_sha256Hex(const <int>[]),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(_sha256Hex('abc'.codeUnits),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    test('常量等于 assets/privacy_policy.md 的 sha256 前 12 位', () {
      expect(kConsentPolicySha.length, 12);
      final f = File(p.join(_packageRoot().path, 'assets', 'privacy_policy.md'));
      expect(f.existsSync(), isTrue,
          reason: '缺少随包政策正文 assets/privacy_policy.md');
      final sha = _sha256Hex(f.readAsBytesSync());
      expect(sha.substring(0, 12), kConsentPolicySha);
    });

    test('随包正文与仓库 docs/隐私政策.md 逐字节一致（防漂移）', () {
      final pkg = _packageRoot();
      final bundled =
          File(p.join(pkg.path, 'assets', 'privacy_policy.md')).readAsBytesSync();
      final repo = File(p.join(pkg.path, '..', 'docs', '隐私政策.md'));
      expect(repo.existsSync(), isTrue,
          reason: '缺少仓库版政策正文 docs/隐私政策.md');
      expect(bundled, repo.readAsBytesSync(),
          reason: 'assets/privacy_policy.md 与 docs/隐私政策.md 不一致：'
              '改完政策请同步两份（同步后需重算 kConsentPolicySha）');
    });
  });

  group('PrivacyConsentPage', () {
    testWidgets('页内有明确的同意 / 不同意两个选项', (tester) async {
      await tester.pumpWidget(_wrapConsent(
          onAccept: () async {}, onDecline: () async {}));
      await tester.pumpAndSettle();

      expect(find.text('课舟 ClassArk'), findsOneWidget);
      expect(find.text('隐私政策与数据使用说明'), findsOneWidget);
      expect(find.text('同意并继续'), findsOneWidget);
      expect(find.text('不同意并退出'), findsOneWidget);
      // 五条要点都在页面上（只读接入 / 凭证本机 / AI 可关 / OCR 需同意 / 分享包自愿）
      expect(find.text('只读接入教务网'), findsOneWidget);
      expect(find.text('账号密码仅存本机沙箱（混淆编码），会话 Cookie 仅驻内存、进程退出即消失；'
              '设置页可一键清除全部本地数据。'),
          findsOneWidget);
      expect(find.text('AI 解读可完全关闭'), findsOneWidget);
      expect(find.text('屏幕识别需单独同意'), findsOneWidget);
      expect(find.text('导师分享包由你自愿导出'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「同意并继续」调用 onAccept', (tester) async {
      var accepted = false;
      await tester.pumpWidget(_wrapConsent(
        onAccept: () async {
          accepted = true;
        },
        onDecline: () async {},
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('同意并继续'));
      await tester.pumpAndSettle();

      expect(accepted, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('点「不同意并退出」弹确认框，确认后调用 onDecline', (tester) async {
      var declined = false;
      await tester.pumpWidget(_wrapConsent(
        onAccept: () async {},
        onDecline: () async {
          declined = true;
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('不同意并退出'));
      await tester.pumpAndSettle();

      // 先弹确认框（不直接退出）
      expect(find.text('确认退出应用？'), findsOneWidget);
      expect(find.text('确认退出'), findsOneWidget);
      expect(declined, isFalse);

      await tester.tap(find.text('确认退出'));
      await tester.pumpAndSettle();

      expect(declined, isTrue);
      expect(tester.takeException(), isNull);
    });

    testWidgets('确认框点「返回」不调用 onDecline', (tester) async {
      var declined = false;
      await tester.pumpWidget(_wrapConsent(
        onAccept: () async {},
        onDecline: () async {
          declined = true;
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('不同意并退出'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();

      expect(declined, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('「查看完整隐私政策」触发 onViewPolicy', (tester) async {
      var viewed = false;
      await tester.pumpWidget(_wrapConsent(
        onAccept: () async {},
        onDecline: () async {},
        onViewPolicy: () {
          viewed = true;
        },
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('查看完整隐私政策'));
      await tester.pumpAndSettle();

      expect(viewed, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('PolicyMarkdownBody（自研 Markdown 渲染）', () {
    testWidgets('标题 / 段落 / 有序无序列表 / 加粗 / 行内码渲染且不抛异常',
        (tester) async {
      await tester.pumpWidget(_wrapBody(const PolicyMarkdownBody(
        '# 一级标题\n\n'
        '正文段落，含 **加粗** 与 `行内码`。\n\n'
        '- 甲项\n- 乙项\n\n'
        '1. 第一步\n2. 第二步\n',
      )));
      await tester.pump();

      expect(find.textContaining('一级标题'), findsOneWidget);
      expect(find.textContaining('正文段落'), findsOneWidget);
      expect(find.textContaining('加粗'), findsOneWidget);
      expect(find.textContaining('行内码'), findsOneWidget);
      expect(find.textContaining('甲项'), findsOneWidget);
      expect(find.textContaining('乙项'), findsOneWidget);
      expect(find.textContaining('第一步'), findsOneWidget);
      expect(find.textContaining('第二步'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('一级 / 二级标题使用主题色 #1F4E79', (tester) async {
      await tester.pumpWidget(_wrapBody(const PolicyMarkdownBody(
        '# 一级标题\n\n## 二级标题\n',
      )));
      await tester.pump();

      final h1 = _spanStyle(tester, '一级标题');
      final h2 = _spanStyle(tester, '二级标题');
      expect(h1?.color, const Color(0xFF1F4E79));
      expect(h2?.color, const Color(0xFF1F4E79));
      expect(h1?.fontWeight, FontWeight.bold);
      expect(tester.takeException(), isNull);
    });

    testWidgets('表格降级为「单元格以 ｜ 连接」的段落', (tester) async {
      await tester.pumpWidget(_wrapBody(const PolicyMarkdownBody(
        '| 信息项 | 收集目的 | 存储位置 |\n'
        '| --- | --- | --- |\n'
        '| 成绩与绩点 | 学分看板 | 本机沙箱 |\n',
      )));
      await tester.pump();

      expect(find.textContaining('｜'), findsWidgets);
      expect(find.textContaining('信息项 ｜ 收集目的 ｜ 存储位置'), findsOneWidget);
      expect(find.textContaining('成绩与绩点 ｜ 学分看板 ｜ 本机沙箱'),
          findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('围栏代码块按等宽样式渲染', (tester) async {
      await tester.pumpWidget(_wrapBody(const PolicyMarkdownBody(
        '示例：\n```dart\nvoid main() {\n  run();\n}\n```\n',
      )));
      await tester.pump();

      expect(find.textContaining('void main()'), findsOneWidget);
      expect(find.textContaining('run();'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未知语法降级为纯文本段落：不抛异常、不丢内容', (tester) async {
      await tester.pumpWidget(_wrapBody(const PolicyMarkdownBody(
        '<div class="x">自定义块内容</div>\n\n'
        '::: 未知容器\n内部文字\n:::\n\n'
        '普通段落仍在。\n',
      )));
      await tester.pump();

      expect(find.textContaining('普通段落仍在。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('PrivacyPolicyPage', () {
    testWidgets('加载失败显示错误与重试按钮，重试后渲染正文', (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: PrivacyPolicyPage(loader: () async {
          calls++;
          if (calls == 1) throw StateError('模拟加载失败');
          return '# 政策标题\n\n政策正文内容。\n';
        }),
      ));
      await tester.pumpAndSettle();

      expect(find.text('隐私政策'), findsOneWidget); // AppBar 标题
      expect(find.text('隐私政策正文加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.textContaining('政策正文内容。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('页脚固定说明含生效日期', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: PrivacyPolicyPage(loader: () async => '正文\n'),
      ));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('本政策与开源仓库中的实现一致，可对照代码复核 · 生效日期 2026-10-21'),
        findsOneWidget,
      );
      expect(PrivacyPolicyPage.assetPath, 'assets/privacy_policy.md');
      expect(tester.takeException(), isNull);
    });
  });
}
