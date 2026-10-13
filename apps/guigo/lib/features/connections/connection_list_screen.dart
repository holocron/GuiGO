import 'package:flutter/material.dart';

import '../../core/connections.dart';
import '../../core/input_history.dart';
import '../../core/password_dialog.dart';
import '../session/session_screen.dart';
import '../session/type_ahead.dart';

class ConnectionListScreen extends StatefulWidget {
  const ConnectionListScreen({super.key});

  @override
  State<ConnectionListScreen> createState() => _ConnectionListScreenState();
}

class _ConnectionListScreenState extends State<ConnectionListScreen> {
  ConnectionStore? _store;
  List<ConnectionEntry> _entries = [];

  /// The store is still opening: no list and no empty state yet (showing
  /// "No systems yet" before the saved list arrives would flicker).
  bool get _loading => _store == null;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final store = await ConnectionStore.create();
    if (!mounted) return;
    setState(() {
      _store = store;
      _entries = store.list();
    });
  }

  Future<void> _edit([ConnectionEntry? existing, bool clone = false]) async {
    final store = _store;
    if (store == null) return;
    final saved = await showModalBottomSheet<ConnectionEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _ConnectionForm(existing: existing, clone: clone),
      ),
    );
    if (saved == null) return;
    // ask only when there is nothing stored yet; editing host/client etc.
    // keeps the existing password, and switching storage off forgets it
    if (!saved.storePassword) {
      await store.deletePassword(saved.id);
    } else if (!await store.hasPassword(saved.id)) {
      final pw = await _askPassword();
      if (pw != null && pw.isNotEmpty) {
        await store.savePassword(saved.id, pw);
      }
    }
    final entries = [..._entries];
    final i = entries.indexWhere((e) => e.id == saved.id);
    if (i >= 0) {
      entries[i] = saved;
    } else {
      entries.add(saved);
    }
    await store.saveAll(entries);
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<void> _delete(ConnectionEntry e) async {
    final store = _store;
    if (store == null) return;
    final label = e.name.isEmpty ? '${e.host}:${e.port}' : e.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete system?'),
        content: Text(
          'Delete "$label"? Its stored password is deleted too.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final entries = [
      for (final x in _entries)
        if (x.id != e.id) x,
    ];
    await store.deletePassword(e.id);
    await store.saveAll(entries);
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  Future<String?> _askPassword() {
    return showDialog<String>(
      context: context,
      builder: (c) => const PasswordDialog(
        title: 'Password',
        label: 'Password (stored securely)',
        cancelLabel: 'Skip',
        okLabel: 'Save',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('GuiGo — systems'),
        actions: [
          if (TypeAheadScope.maybeOf(context)?.history case final h?)
            InputHistoryMenu(history: h),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _edit,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.dns_outlined,
                    size: 64,
                    color: Colors.blueGrey.shade300,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'No systems yet',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  const Text('Add an application server to connect'),
                ],
              ),
            )
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (c, i) {
                final e = _entries[i];
                return Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.storage)),
                    title: Text(
                      e.name.isEmpty ? '${e.host}:${e.port}' : e.name,
                    ),
                    subtitle: Text(
                      '${e.host}:${e.port} · client ${e.client} · ${e.user} · ${e.language}',
                    ),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'edit') return _edit(e);
                        if (v == 'clone') return _edit(e, true);
                        if (v == 'delete') return _delete(e);
                      },
                      itemBuilder: (c) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit')),
                        PopupMenuItem(
                          value: 'clone',
                          child: Text('Clone for another user'),
                        ),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                    onTap: () => Navigator.pushNamed(
                      context,
                      '/session',
                      arguments: SessionArgs(e, _store!),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ConnectionForm extends StatefulWidget {
  const _ConnectionForm({this.existing, this.clone = false});

  final ConnectionEntry? existing;

  /// Prefill from [existing] but save as a new entry (new id, no user, no
  /// password) — same server, different user.
  final bool clone;

  @override
  State<_ConnectionForm> createState() => _ConnectionFormState();
}

class _ConnectionFormState extends State<_ConnectionForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _client = TextEditingController();
  final _user = TextEditingController();
  final _lang = TextEditingController();
  final _router = TextEditingController();
  bool _storePw = true;
  bool _keepOthers = false;
  String? _portError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name.text = widget.clone ? '${e?.name ?? ''} (copy)' : e?.name ?? '';
    _host.text = e?.host ?? '';
    _port.text = (e?.port ?? 3200).toString();
    _client.text = e?.client ?? '100';
    _user.text = widget.clone ? '' : e?.user ?? '';
    _lang.text = e?.language ?? 'EN';
    _router.text = e?.routerString ?? '';
    _storePw = e?.storePassword ?? true;
    _keepOthers = e?.keepOtherSessions ?? false;
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _client, _user, _lang, _router]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final port = parsePort(_port.text);
    if (port == null) {
      setState(() => _portError = 'A port number from 1 to 65535');
      return;
    }
    Navigator.pop(
      context,
      ConnectionEntry(
        id:
            (widget.clone ? null : widget.existing?.id) ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: port,
        routerString: _router.text.trim(),
        client: _client.text.trim(),
        user: _user.text.trim().toUpperCase(),
        language: _lang.text.trim().toUpperCase(),
        storePassword: _storePw,
        keepOtherSessions: _keepOthers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // scrolls when the sheet is shorter than the form (landscape phone,
    // keyboard up)
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.existing == null
                ? 'Add system'
                : widget.clone
                ? 'Clone system'
                : 'Edit system',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'Application server host',
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('connection-port'),
                  controller: _port,
                  keyboardType: TextInputType.number,
                  onChanged: (_) {
                    if (_portError != null) setState(() => _portError = null);
                  },
                  decoration: InputDecoration(
                    labelText: 'Port',
                    errorText: _portError,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _client,
                  decoration: const InputDecoration(labelText: 'Client'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _lang,
                  decoration: const InputDecoration(labelText: 'Language'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: 'User'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _router,
            decoration: const InputDecoration(
              labelText: 'SAProuter string (optional)',
              hintText: '/H/router/S/3299/H/host/S/3200',
            ),
          ),
          SwitchListTile(
            value: _storePw,
            onChanged: (v) => setState(() => _storePw = v),
            title: const Text('Store password'),
            subtitle: const Text(
              'Released after Face ID / Touch ID / fingerprint. On a device '
              'without biometrics it is used directly, protected only by '
              'the secure store',
            ),
            dense: true,
          ),
          SwitchListTile(
            value: _keepOthers,
            onChanged: (v) => setState(() => _keepOthers = v),
            title: const Text(
              'Already logged on: continue without ending the other sessions',
            ),
            subtitle: const Text('Off (SAP default): ask, preselected to not log on'),
            dense: true,
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

/// The TCP port typed in the connection editor, or null when it is not a
/// number in 1..65535 (the editor then shows an error instead of guessing).
int? parsePort(String text) {
  final p = int.tryParse(text.trim());
  return (p == null || p < 1 || p > 65535) ? null : p;
}

/// SAP GUI's "Local Data > History" options for every connection: input
/// history On / Off (on by default) and "Clear History" (all systems).
class InputHistoryMenu extends StatelessWidget {
  const InputHistoryMenu({super.key, required this.history});

  final InputHistoryStore history;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) => PopupMenuButton<String>(
        tooltip: 'Input history',
        icon: const Icon(Icons.history),
        onSelected: (v) async {
          if (v == 'toggle') {
            await history.setEnabled(!history.enabled);
          } else if (v == 'clear') {
            await history.clear();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Input history cleared')),
              );
            }
          }
        },
        itemBuilder: (context) => [
          CheckedPopupMenuItem(
            value: 'toggle',
            checked: history.enabled,
            child: const Text('Input history'),
          ),
          PopupMenuItem(
            value: 'clear',
            enabled: !history.isEmpty,
            child: const Text('Clear input history'),
          ),
        ],
      ),
    );
  }
}
