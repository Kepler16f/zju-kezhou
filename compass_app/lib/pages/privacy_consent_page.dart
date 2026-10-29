/// pages/privacy_consent_page.dart — 首启隐私同意门禁页。
///
/// 设计约束：
///  - **同意必须是页内明确选项**（不用系统弹窗）：用户能一眼看完要点，再点「同意并继续」；
///    「不同意并退出」点一次后弹确认对话框说明后果，确认才调用 [onDecline]。
///  - 页面文案必须与实现一致（教务只读、凭证本机、AI 可关闭且白名单脱敏、OCR 需显式同意、
///    分享包自愿导出），与《隐私政策》(assets/privacy_policy.md) 口径统一。
///  - 页面本身不落盘、不联网：同意结果由调用方写入 ConsentStore，导航由调用方接管。
library;

import 'package:flutter/material.dart';

/// 一条要点（图标 + 标题 + 说明）。
class _ConsentPoint {
  const _ConsentPoint(this.icon, this.title, this.detail);

  final IconData icon;
  final String title;
  final String detail;
}

/// 首启隐私同意页。
class PrivacyConsentPage extends StatelessWidget {
  const PrivacyConsentPage({
    super.key,
    required this.onAccept,
    required this.onDecline,
    this.onViewPolicy,
  });

  /// 用户同意：由调用方负责落盘（ConsentStore.accept）并放行进入应用。
  final Future<void> Function() onAccept;

  /// 用户不同意并退出：由调用方负责退出应用（不收集任何数据）。
  final Future<void> Function() onDecline;

  /// 查看完整隐私政策（跳转到隐私政策页）；为空时按钮置灰。
  final VoidCallback? onViewPolicy;

  /// 政策主题色：深蓝 #1F4E79（与政策正文页标题色一致）。
  static const Color policyColor = Color(0xFF1F4E79);

  /// 政策版本与生效日期（与 ConsentStore.kConsentPolicyVersion / 政策正文一致）。
  static const String policyVersion = 'v1.0';
  static const String effectiveDate = '2026-10-21';

  /// 要点清单（与实现逐条对应，勿随意改动口径）。
  static const List<_ConsentPoint> _points = <_ConsentPoint>[
    _ConsentPoint(
      Icons.school_outlined,
      '只读接入教务网',
      '仅读取成绩、课表、培养方案与选课信息，不含任何提交 / 退课操作；'
          '所有学分、绩点、冲突与缺口均在本机计算。',
    ),
    _ConsentPoint(
      Icons.lock_outline,
      '凭证只在本机',
      '账号密码仅存本机沙箱（混淆编码），会话 Cookie 仅驻内存、进程退出即消失；'
          '设置页可一键清除全部本地数据。',
    ),
    _ConsentPoint(
      Icons.psychology_outlined,
      'AI 解读可完全关闭',
      '默认关闭；开启后按白名单只发送脱敏子集，不含姓名、学号、成绩明细与凭证，'
          '首次发送前会弹窗列明范围请你确认。',
    ),
    _ConsentPoint(
      Icons.screenshot_outlined,
      '屏幕识别需单独同意',
      '仅 Windows 可用，使用系统本机离线 OCR（不经云端）；'
          '需你显式同意后，才随该次问题发送。',
    ),
    _ConsentPoint(
      Icons.ios_share_outlined,
      '导师分享包由你自愿导出',
      '分享包字段级脱敏、默认匿名；是否导出、发给谁完全由你决定。',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(scheme),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    for (final p in _points) _pointCard(p, scheme),
                  ],
                ),
              ),
            ),
            _footer(context, scheme),
          ],
        ),
      ),
    );
  }

  Widget _header(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: policyColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.school_outlined,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '课舟 ClassArk',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: policyColor,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '隐私政策与数据使用说明',
                        style: TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '本应用本地优先：不设自建服务器，除你确认的 AI 请求外不上传任何数据。'
              '政策版本 $policyVersion · 生效日期 $effectiveDate。',
              style: TextStyle(
                  fontSize: 11.5, height: 1.5, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );

  Widget _pointCard(_ConsentPoint p, ColorScheme scheme) => Card(
        margin: const EdgeInsets.symmetric(vertical: 5),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        child: ListTile(
          dense: true,
          leading: Icon(p.icon, color: policyColor, size: 22),
          title: Text(
            p.title,
            style: const TextStyle(
                fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              p.detail,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ),
      );

  Widget _footer(BuildContext context, ColorScheme scheme) => Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.35),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextButton.icon(
              onPressed: onViewPolicy,
              icon: const Icon(Icons.article_outlined, size: 18),
              label: const Text('查看完整隐私政策'),
              style: TextButton.styleFrom(foregroundColor: policyColor),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _confirmDecline(context),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.onSurfaceVariant,
                      side: BorderSide(color: scheme.outlineVariant),
                    ),
                    child: const Text('不同意并退出'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () async {
                      await onAccept();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: policyColor,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('同意并继续'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '不同意将无法使用本应用：课舟 ClassArk 需要你在上述说明下同意后，'
              '才会读取并在本机保存必要数据；若你现在退出，应用不会收集任何数据。',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11, height: 1.45, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );

  /// 「不同意」的一次性确认对话框：说明后果后再调用 [onDecline]。
  Future<void> _confirmDecline(BuildContext context) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('确认退出应用？'),
        content: const Text(
          '课舟 ClassArk 需要你在上述说明下同意后，才会读取并在本机保存必要数据。\n\n'
          '若现在退出，应用不会收集任何数据；你可以随时重新打开，'
          '并再次做出选择。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: policyColor),
            child: const Text('确认退出'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await onDecline();
    }
  }
}
