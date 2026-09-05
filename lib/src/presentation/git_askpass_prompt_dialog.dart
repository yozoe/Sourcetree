import 'package:flutter/material.dart';

import '../git/git.dart';

/// Presents a credential field for one request in a validated AskPass session.
///
/// Raw Git prompts can contain a full URL, username, or token. This dialog
/// deliberately renders only a broad prompt type and returns the submitted
/// value directly to its caller; it never logs or persists the value.
/// 中文：显示相应界面或信息。
/// English: Shows the corresponding UI or information.
Future<String?> showGitAskPassPromptDialog(
  BuildContext context,
  GitAskPassRequest request,
) {
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _GitAskPassPromptDialog(request: request),
  );
}

final class _GitAskPassPromptDialog extends StatefulWidget {
  const _GitAskPassPromptDialog({required this.request});

  final GitAskPassRequest request;

  /// 中文：创建关联的状态对象。
  /// English: Creates the associated state object.
  @override
  State<_GitAskPassPromptDialog> createState() =>
      _GitAskPassPromptDialogState();
}

final class _GitAskPassPromptDialogState
    extends State<_GitAskPassPromptDialog> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool get _isUsername => widget.request.kind == GitAskPassPromptKind.username;

  String get _title => switch (widget.request.kind) {
    GitAskPassPromptKind.username => '需要用户名',
    GitAskPassPromptKind.password => '需要密码',
    GitAskPassPromptKind.passphrase => '需要 SSH 私钥口令',
    GitAskPassPromptKind.unknown => '需要认证信息',
  };

  String get _hint => _isUsername ? '输入用户名' : '输入认证信息';

  /// 中文：初始化组件状态和依赖。
  /// English: Initializes widget state and dependencies.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// 中文：释放当前对象持有的资源。
  /// English: Releases resources held by this object.
  @override
  void dispose() {
    _controller
      ..clear()
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 中文：提交当前表单或请求。
  /// English: Submits the current form or request.
  void _submit() {
    Navigator.of(context).pop(_controller.text);
  }

  /// 中文：构建当前组件的界面。
  /// English: Builds the current component UI.
  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_title),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Git 正在请求凭据。输入仅用于当前操作，不会由应用保存。'),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              obscureText: !_isUsername,
              enableSuggestions: false,
              autocorrect: false,
              enableInteractiveSelection: false,
              autofillHints: null,
              keyboardType: _isUsername
                  ? TextInputType.text
                  : TextInputType.visiblePassword,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: _hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('继续')),
      ],
    );
  }
}
