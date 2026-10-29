/// pages/privacy_gate.dart — 首启隐私同意门禁（未同意前不渲染任何业务页面）。
///
/// 行为：
///  - 启动时读 ConsentStore：已同意 → 直接放行业务页（child）；
///  - 未同意 → 展示 PrivacyConsentPage，用户点「同意并继续」才落盘并放行；
///  - 用户点「不同意并退出」→ 展示终态说明页（不收集任何数据），可重新查看政策或退出。
///
/// 设计约束：
///  - 门禁本身不联网、不采集任何数据；同意状态只落本机沙箱（见 ConsentStore）。
///  - 读取异常一律按"未同意"处理（fail-closed）：读不到状态不等于用户已同意。
///    这在测试环境（path_provider mock 返回 null）下会表现为门禁常驻，因此
///    测试用 KeZhouApp(requireConsent: false) 显式跳过门禁。
///  - 退出流程不依赖具体平台 API：默认走 SystemNavigator.pop() + exit(0)，
///    可通过 onExit 注入以适配宿主或测试。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/consent_store.dart';
import 'privacy_consent_page.dart';
import 'privacy_policy_page.dart';

/// 隐私同意门禁。
class PrivacyGate extends StatefulWidget {
  const PrivacyGate({super.key, required this.child, this.store, this.onExit});

  /// 同意后展示的业务页面。
  final Widget child;

  /// 同意状态存储（测试可注入沙箱目录）。
  final ConsentStore? store;

  /// 退出回调（默认 SystemNavigator.pop + exit(0)）。
  final Future<void> Function()? onExit;

  @override
  State<PrivacyGate> createState() => _PrivacyGateState();
}

class _PrivacyGateState extends State<PrivacyGate> {
  /// null = 尚未判定；true = 已同意；false = 未同意。
  bool? _accepted;
  bool _declined = false;

  late final ConsentStore _store = widget.store ?? ConsentStore();

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    bool ok;
    try {
      ok = await _store.isAccepted();
    } catch (_) {
      ok = false; // fail-closed：读不到状态 ≠ 已同意
    }
    if (!mounted) return;
    setState(() => _accepted = ok);
  }

  Future<void> _accept() async {
    try {
      await _store.accept();
    } catch (_) {
      // 落盘失败不阻断流程：本机存储异常不应把用户永久挡在门外。
    }
    if (!mounted) return;
    setState(() => _accepted = true);
  }

  Future<void> _quit() async {
    final cb = widget.onExit;
    if (cb != null) {
      await cb();
      return;
    }
    try {
      await SystemNavigator.pop();
    } catch (_) {
      // 某些平台不支持 pop，继续走 exit
    }
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final accepted = _accepted;
    if (accepted == null) {
      return const _GateSplash();
    }
    if (accepted) return widget.child;
    if (_declined) {
      return _DeclinedView(
        onReconsider: () => setState(() => _declined = false),
        onQuit: _quit,
      );
    }
    return PrivacyConsentPage(
      onAccept: _accept,
      onDecline: () async => setState(() => _declined = true),
      onViewPolicy: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const PrivacyPolicyPage(),
        ),
      ),
    );
  }
}

/// 判定同意状态期间的启动页（不展示任何业务内容）。
class _GateSplash extends StatelessWidget {
  const _GateSplash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.school_outlined, size: 48),
            SizedBox(height: 16),
            Text('课舟 ClassArk'),
            SizedBox(height: 16),
            SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// 用户明确「不同意」后的终态：不采集任何数据，可回看政策或退出。
class _DeclinedView extends StatelessWidget {
  const _DeclinedView({required this.onReconsider, required this.onQuit});

  final VoidCallback onReconsider;
  final Future<void> Function() onQuit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, size: 44),
              const SizedBox(height: 14),
              const Text(
                '未同意隐私政策，课舟无法继续使用',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              const Text(
                '课舟需要读取本机存储来保存你的登录状态与方案分析结果，'
                '需要联网以只读查询教务数据。这些都受隐私政策约束。\n'
                '我们不会在未同意的情况下收集任何数据。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, height: 1.6),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PrivacyPolicyPage(),
                  ),
                ),
                child: const Text('查看完整隐私政策'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => onReconsider(),
                child: const Text('重新选择'),
              ),
              TextButton(
                onPressed: () => onQuit(),
                child: const Text('退出课舟'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
