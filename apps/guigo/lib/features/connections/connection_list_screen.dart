import 'package:diag_protocol/diag_protocol.dart'
    show defaultLogonLanguage, defaultSapPort;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/connections.dart';
import '../../core/input_history_menu.dart';
import '../../core/password_dialog.dart';
import '../session/session_screen.dart';
import '../session/type_ahead.dart';

/// The widest a system card gets: on a tablet or a desktop window the list
/// stays a readable column (the M3 modal sheet caps itself at 640).
const double _maxContentWidth = 600;

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
      // the form can be taller than the screen minus the keyboard: the
      // sheet then starts below the status bar / notch, not under it
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: _ConnectionForm(existing: existing, clone: clone),
      ),
    );
    if (saved == null) return;
    // the entry first (audit 2026-10-23 R-14): the list on the screen is
    // what the store holds, or the store's failure is told and the screen
    // keeps the entry as it was — a password saved for an edit that was
    // never stored would have been the stale entry's
    final entries = [..._entries];
    final i = entries.indexWhere((e) => e.id == saved.id);
    if (i >= 0) {
      entries[i] = saved;
    } else {
      entries.add(saved);
    }
    if (!await _stored(() => store.saveAll(entries), 'Could not save the system')) {
      return;
    }
    if (!mounted) return;
    setState(() => _entries = entries);
    // ask only when there is nothing stored yet; editing host/client etc.
    // keeps the existing password, and switching storage off forgets it
    if (!saved.storePassword) {
      await _stored(
        () => store.deletePassword(saved.id),
        'Could not delete the stored password',
      );
      return;
    }
    final bool has;
    try {
      has = await store.hasPassword(saved.id);
    } on Object catch (e) {
      _failed('Could not read the password store', e);
      return;
    }
    if (has || !mounted) return;
    final pw = await _askPassword(
      title: saved.user.isEmpty
          ? 'Password for ${saved.label}'
          : 'Password for ${saved.user} on ${saved.label}',
      // the value is stored unverified; the logon path stores one only
      // once SAP accepted it, which is what skipping here leads to
      note:
          'Not checked until you log on. "Ask at logon" asks then and '
          'stores the password once SAP accepts it.',
      cancelLabel: 'Ask at logon',
    );
    if (pw != null && pw.isNotEmpty) {
      await _stored(
        () => store.savePassword(saved.id, pw),
        'Could not store the password',
      );
    }
  }

  /// Run a store write; false, with [what] and the error on a snack bar,
  /// when it threw. A store error used to be an unhandled zone error (the
  /// menu drops these futures) while the list kept stale data
  /// (audit 2026-10-23 R-14).
  Future<bool> _stored(Future<void> Function() write, String what) async {
    try {
      await write();
      return true;
    } on Object catch (e) {
      _failed(what, e);
      return false;
    }
  }

  void _failed(String what, Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text('$what: $error'),
          duration: const Duration(seconds: 6),
        ),
      );
  }

  Future<void> _delete(ConnectionEntry e) async {
    final store = _store;
    if (store == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete system?'),
        content: Text(
          'Delete "${e.label}"? Its stored password is deleted too.',
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
    // the entry first, its password after (audit 2026-10-23 R-14): the
    // other order erased the password and, when saveAll failed, left the
    // entry — without its password. A password delete that fails leaves
    // an orphan in the secure store, told, not an entry
    if (!await _stored(() => store.saveAll(entries), 'Could not delete the system')) {
      return;
    }
    if (!mounted) return;
    setState(() => _entries = entries);
    await _stored(
      () => store.deletePassword(e.id),
      'Could not delete the stored password',
    );
  }

  /// Replace the stored password of [e] (after a password change in SAP)
  /// without the toggle-off-Save-toggle-on-Save detour. Not verified
  /// here: a mistyped value is corrected at the next logon, where SAP's
  /// refusal re-asks and the accepted password overwrites the stored one.
  Future<void> _changePassword(ConnectionEntry e) async {
    final store = _store;
    if (store == null) return;
    final pw = await _askPassword(
      title: 'Change stored password',
      cancelLabel: 'Cancel',
    );
    if (pw == null || pw.isEmpty || !mounted) return;
    // audit 2026-10-23 R-14: a refused write is told, not thrown away
    if (!await _stored(
      () => store.savePassword(e.id, pw),
      'Could not store the password',
    )) {
      return;
    }
    if (!mounted) return;
    // a secure-store write is otherwise invisible
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Stored password changed')));
  }

  Future<String?> _askPassword({
    required String title,
    String? note,
    String cancelLabel = 'Cancel',
  }) {
    return showDialog<String>(
      context: context,
      builder: (c) => PasswordDialog(
        title: title,
        note: note,
        cancelLabel: cancelLabel,
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
                // the list stays full width (it scrolls from anywhere),
                // each card is capped and centred
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _maxContentWidth,
                    ),
                    child: Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.storage)),
                        title: Text(e.label),
                        subtitle: Text(
                          '${e.host}:${e.port} · client ${e.client} · ${e.user} · ${e.language}',
                        ),
                        trailing: PopupMenuButton<String>(
                          key: ValueKey('system-menu-${e.id}'),
                          onSelected: (v) async {
                            if (v == 'edit') return _edit(e);
                            if (v == 'clone') return _edit(e, true);
                            if (v == 'password') return _changePassword(e);
                            if (v == 'delete') return _delete(e);
                          },
                          itemBuilder: (c) => [
                            const PopupMenuItem(
                              value: 'edit',
                              child: Text('Edit'),
                            ),
                            const PopupMenuItem(
                              value: 'clone',
                              child: Text('Clone for another user'),
                            ),
                            // greyed with storage off: flipping the switch
                            // on and saving asks for the password anyway
                            PopupMenuItem(
                              value: 'password',
                              enabled: e.storePassword,
                              child: const Text('Change stored password…'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('Delete'),
                            ),
                          ],
                        ),
                        onTap: () => Navigator.pushNamed(
                          context,
                          '/session',
                          arguments: SessionArgs(e, _store!),
                        ),
                      ),
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
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _client = TextEditingController();
  final _user = TextEditingController();
  final _lang = TextEditingController();
  final _router = TextEditingController();
  bool _storePw = true;
  bool _keepOthers = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name.text = widget.clone ? '${e?.name ?? ''} (copy)' : e?.name ?? '';
    _host.text = e?.host ?? '';
    _port.text = (e?.port ?? defaultSapPort).toString();
    _client.text = e?.client ?? '100';
    _user.text = widget.clone ? '' : e?.user ?? '';
    _lang.text = e?.language ?? defaultLogonLanguage;
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

  /// Refuses with the fields' own errors and keeps the sheet open: nothing
  /// below checks these again — an empty host only fails at the socket,
  /// an empty user or a 2-digit client is sent to SAP and comes back as a
  /// logon refusal inside the password prompt, where nothing typed can
  /// fix it (and every round trip costs a biometric prompt).
  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      ConnectionEntry(
        id:
            (widget.clone ? null : widget.existing?.id) ??
            DateTime.now().microsecondsSinceEpoch.toRadixString(36),
        name: _name.text.trim(),
        host: _host.text.trim(),
        port: parsePort(_port.text)!,
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
    // every field validates on Save, and again as it is typed into once it
    // was refused; Next walks Name → Host → Port → Client → Language →
    // User → Router (reading order), Done on the last one saves
    const next = TextInputAction.next;
    const refused = AutovalidateMode.onUserInteraction;
    // scrolls when the sheet is shorter than the form (landscape phone,
    // keyboard up)
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
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
            TextFormField(
              key: const ValueKey('connection-name'),
              controller: _name,
              // a new system: the keyboard is up at once; an edit starts
              // with nothing focused
              autofocus: widget.existing == null,
              textCapitalization: TextCapitalization.words,
              textInputAction: next,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('connection-host'),
              controller: _host,
              // a host name is not a word: no autocorrect, no suggestions
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: next,
              autovalidateMode: refused,
              validator: (v) => hostError(v ?? ''),
              decoration: const InputDecoration(
                labelText: 'Application server host',
              ),
            ),
            const SizedBox(height: 8),
            Row(
              // a field showing its error grows; the others stay aligned
              // to the top
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    key: const ValueKey('connection-port'),
                    controller: _port,
                    // iPhone's number pad has no Return key: Next is only
                    // reachable there from the text fields
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textInputAction: next,
                    autovalidateMode: refused,
                    validator: (v) => parsePort(v ?? '') == null
                        ? 'A port number from 1 to 65535'
                        : null,
                    decoration: const InputDecoration(
                      labelText: 'Port',
                      errorMaxLines: 4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: const ValueKey('connection-client'),
                    controller: _client,
                    keyboardType: TextInputType.number,
                    // MANDT is CLNT 3
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(3),
                    ],
                    textInputAction: next,
                    autovalidateMode: refused,
                    validator: (v) => clientError(v ?? ''),
                    decoration: const InputDecoration(
                      labelText: 'Client',
                      errorMaxLines: 4,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    key: const ValueKey('connection-language'),
                    controller: _lang,
                    // RSYST-LANGU is 2 characters: an ISO code or a SAP
                    // one-letter key
                    inputFormatters: [LengthLimitingTextInputFormatter(2)],
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: next,
                    autovalidateMode: refused,
                    validator: (v) => languageError(v ?? ''),
                    decoration: const InputDecoration(
                      labelText: 'Language',
                      errorMaxLines: 4,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('connection-user'),
              controller: _user,
              // RSYST-BNAME is 12 characters; the capitalization is a soft
              // keyboard hint only, _save uppercases regardless
              inputFormatters: [LengthLimitingTextInputFormatter(12)],
              textCapitalization: TextCapitalization.characters,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: next,
              autovalidateMode: refused,
              validator: (v) => userError(v ?? ''),
              decoration: const InputDecoration(labelText: 'User'),
            ),
            const SizedBox(height: 8),
            TextFormField(
              key: const ValueKey('connection-router'),
              controller: _router,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _save(),
              // SAP GUI's SAProuter string: the router hops only — the
              // session appends the application server as the last hop
              // itself, a string that already ends in it sends the
              // dispatcher a route it cannot serve
              decoration: const InputDecoration(
                labelText: 'SAProuter string (optional)',
                hintText: '/H/saprouter.example.com/S/3299',
                helperText:
                    'Router hops only; the application server above is '
                    'appended automatically',
                helperMaxLines: 2,
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
              subtitle: const Text(
                'Off (SAP default): ask, preselected to not log on',
              ),
              dense: true,
            ),
            const SizedBox(height: 8),
            FilledButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
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

// The editor's other checks, null = accepted. They live in the form, not
// in ConnectionEntry / SapSystem: an empty user becomes legitimate once
// SNC single sign-on is wired from the UI.

/// Non-empty, no blanks — needed even with a SAProuter string, which holds
/// the router hops only (the session appends this host as the last hop).
String? hostError(String text) {
  final t = text.trim();
  if (t.isEmpty) return 'Enter the application server host';
  if (RegExp(r'\s').hasMatch(t)) return 'A host name or address, no spaces';
  return null;
}

/// MANDT is CLNT 3: exactly three digits (the editor prefills 100).
String? clientError(String text) => RegExp(r'^\d{3}$').hasMatch(text.trim())
    ? null
    : 'A client of 3 digits (100)';

/// Sent as RSYST-BNAME: SAP refuses an empty one on the logon screen.
String? userError(String text) => text.trim().isEmpty ? 'Enter the user' : null;

/// RSYST-LANGU is a 2-character plane: empty (the user's default language,
/// the atom is then left out), a 2-letter ISO code or a 1-character SAP
/// language key. The keys are not limited to the ones `connectLanguage`
/// maps — a system may define more (M, 2, Y, Z …).
String? languageError(String text) =>
    RegExp(r'^([A-Z0-9]|[A-Z]{2})?$').hasMatch(text.trim().toUpperCase())
    ? null
    : 'Empty, a 2-letter ISO code (EN) or an SAP language key (E)';
