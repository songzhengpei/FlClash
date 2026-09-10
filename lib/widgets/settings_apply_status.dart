import 'package:fl_clash/widgets/surge/surge.dart';
import 'package:fl_clash/widgets/dialog.dart';
import 'package:fl_clash/widgets/input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/providers/settings_apply.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/services/settings/settings_apply_queue.dart';
import 'package:fl_clash/state.dart';

String settingsText(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;

/// Uses the app's transient notification and error-dialog system. No page row.
class SettingsApplyFeedback extends ConsumerWidget {
  const SettingsApplyFeedback({super.key, required this.child, this.onMessage});
  final Widget child;
  final void Function(String message, VoidCallback? retry)? onMessage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(settingsApplyProvider, (previous, status) {
      if (!ref.read(initProvider)) return;
      if (status.phase == SettingsApplyPhase.deferred &&
          previous?.phase == status.phase) {
        return;
      }
      final localContext = globalState.navigatorKey.currentContext ?? context;
      final zh =
          Localizations.maybeLocaleOf(localContext)?.languageCode == 'zh';
      String text(String cn, String en) => zh ? cn : en;
      final message = switch (status.phase) {
        SettingsApplyPhase.applied => text('设置已生效', 'Settings applied'),
        SettingsApplyPhase.deferred => text(
          '设置已保存，下次启动或恢复时生效',
          'Saved; applies on next start or resume',
        ),
        SettingsApplyPhase.failed =>
          "${text('设置应用失败', 'Settings application failed')}\n${status.error ?? ''}",
        SettingsApplyPhase.applying when status.reconnect => text(
          '正在应用设置，VPN 将短暂重连',
          'Applying settings; VPN will briefly reconnect',
        ),
        _ => null,
      };
      if (message == null) return;
      void retry() {
        if (context.mounted) ref.read(settingsApplyProvider.notifier).retry();
      }

      if (onMessage != null) {
        onMessage!(
          message,
          status.phase == SettingsApplyPhase.failed ? retry : null,
        );
      } else if (status.phase == SettingsApplyPhase.failed) {
        globalState
            .showCommonDialog<bool>(
              child: SettingsApplyFailureDialog(
                message: status.error ?? message,
              ),
            )
            .then((value) {
              if (value == true) retry();
            });
      } else {
        globalState.showNotifier(message);
      }
    });
    return child;
  }
}

/// Matches the project/core link dialogs on the About page.
class SettingsApplyFailureDialog extends StatelessWidget {
  const SettingsApplyFailureDialog({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) => CommonDialog(
    title: settingsText(context, '设置应用失败', 'Settings application failed'),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 16,
      children: [
        InputDecorator(
          decoration: surgeInputDecoration(
            context,
            contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          ),
          child: Text(message, style: context.typography.body),
        ),
        SurgeDialogActionRow(
          cancelLabel: settingsText(context, '关闭', 'Close'),
          submitLabel: settingsText(context, '重试', 'Retry'),
          onCancel: () => Navigator.of(context).pop(false),
          onSubmit: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
}
