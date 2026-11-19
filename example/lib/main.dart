import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qfli_git/qfli_git.dart';

import 'flow.dart';

void main() {
  runApp(const QfliGitExampleApp());
}

class QfliGitExampleApp extends StatelessWidget {
  const QfliGitExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'qfli_git example',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const FlowPage(),
    );
  }
}

class FlowPage extends StatefulWidget {
  const FlowPage({super.key});

  @override
  State<FlowPage> createState() => _FlowPageState();
}

class _FlowPageState extends State<FlowPage> {
  final _remoteController = TextEditingController();
  final _branchController = TextEditingController(text: 'feature');
  final _usernameController = TextEditingController();
  final _tokenController = TextEditingController();
  final _authorNameController = TextEditingController(text: 'QFLI User');
  final _authorEmailController = TextEditingController(
    text: 'qfli@example.com',
  );

  final _steps = <FlowStep>[];
  CancelToken? _cancel;
  bool _running = false;
  bool _tokenVisible = false;
  String _version = 'unknown';
  String? _versionError;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  void dispose() {
    _cancel?.dispose();
    _remoteController.dispose();
    _branchController.dispose();
    _usernameController.dispose();
    _tokenController.dispose();
    _authorNameController.dispose();
    _authorEmailController.dispose();
    super.dispose();
  }

  void _loadVersion() {
    try {
      final version = QfliGit.libgit2Version;
      setState(() {
        _version = version;
        _versionError = null;
      });
    } catch (error) {
      setState(() {
        _versionError = error.toString();
      });
    }
  }

  Future<void> _runFlow() async {
    final typedUrl = _remoteController.text.trim();
    if (typedUrl.isEmpty) {
      _showMessage('Enter a remote URL.');
      return;
    }
    final remoteUrl = sanitizeRemoteUrl(typedUrl);
    if (remoteUrl != typedUrl) {
      _showMessage('Put the token in the Token field. The URL was cleaned.');
    }
    final settings = FlowSettings(
      remoteUrl: remoteUrl,
      branch: _branchController.text.trim().isEmpty
          ? 'feature'
          : _branchController.text.trim(),
      authorName: _authorNameController.text.trim(),
      authorEmail: _authorEmailController.text.trim(),
      username: _usernameController.text.trim().isEmpty
          ? null
          : _usernameController.text.trim(),
      token: _tokenController.text.isEmpty ? null : _tokenController.text,
    );

    final cancel = CancelToken();
    setState(() {
      _steps.clear();
      _cancel = cancel;
      _running = true;
    });

    try {
      await QfliGit.ensureInitialized();
      final support = await getApplicationSupportDirectory();
      final runner = FlowRunner(
        settings: settings,
        workPath: p.join(support.path, 'flow_repo'),
        cancel: cancel,
        onStep: (step) {
          if (mounted) {
            setState(() => _steps.add(step));
          }
        },
      );
      await runner.run();
    } catch (error) {
      if (mounted) {
        if (error is GitException && error.isCanceled) {
          _showMessage('Flow canceled.');
        } else {
          _showMessage('Flow stopped: $error');
        }
      }
    } finally {
      cancel.dispose();
      if (mounted) {
        setState(() {
          _running = false;
          _cancel = null;
        });
      }
    }
  }

  void _cancelFlow() {
    _cancel?.cancel();
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('qfli_git example')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _versionBanner(theme),
            const SizedBox(height: 12),
            _field(_remoteController, 'Remote HTTPS URL'),
            _field(_usernameController, 'Username (optional)'),
            _field(
              _tokenController,
              'Token',
              obscure: !_tokenVisible,
              trailing: IconButton(
                tooltip: _tokenVisible ? 'Hide token' : 'Show token',
                icon: Icon(
                  _tokenVisible ? Icons.visibility_off : Icons.visibility,
                ),
                onPressed: () => setState(() => _tokenVisible = !_tokenVisible),
              ),
            ),
            _field(_branchController, 'Merge branch name'),
            _field(_authorNameController, 'Author name'),
            _field(_authorEmailController, 'Author email'),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    key: const Key('run'),
                    onPressed: _running ? null : _runFlow,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('全流程'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const Key('cancel'),
                    onPressed: _running ? _cancelFlow : null,
                    icon: const Icon(Icons.stop),
                    label: const Text('取消'),
                  ),
                ),
              ],
            ),
            const Divider(height: 32),
            Row(
              children: <Widget>[
                Text('Steps', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (_steps.isNotEmpty)
                  Text(
                    '${_steps.where((step) => step.succeeded).length}/'
                    '${_steps.length} ok',
                    style: theme.textTheme.labelLarge,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_steps.isEmpty)
              Text(
                'No step has run yet.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            for (final step in _steps) _stepRow(theme, step),
          ],
        ),
      ),
    );
  }

  Widget _versionBanner(ThemeData theme) {
    final error = _versionError;
    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: ListTile(
        leading: const Icon(Icons.info_outline),
        title: Text('libgit2 $_version', key: const Key('libgit2-version')),
        subtitle: error == null
            ? const Text('Token stays in memory only.')
            : Text('Library error: $error'),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool obscure = false,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        enableSuggestions: !obscure,
        autocorrect: false,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: trailing,
        ),
      ),
    );
  }

  Widget _stepRow(ThemeData theme, FlowStep step) {
    final IconData icon;
    final Color color;
    if (step.succeeded) {
      icon = Icons.check_circle;
      color = Colors.green.shade700;
    } else if (step.cancelled) {
      icon = Icons.cancel_outlined;
      color = Colors.orange.shade800;
    } else {
      icon = Icons.error;
      color = theme.colorScheme.error;
    }
    final text = step.succeeded ? step.detail : step.error;
    final subtitle = text == null || text.isEmpty
        ? (step.cancelled ? '已取消' : null)
        : text;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ListTile(
        dense: true,
        leading: Icon(icon, color: color),
        title: Text(step.name),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, maxLines: 4, overflow: TextOverflow.ellipsis),
        trailing: Text('${step.elapsed.inMilliseconds} ms'),
      ),
    );
  }
}
