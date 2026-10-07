import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class AddPlaylistScreen extends StatelessWidget {
  const AddPlaylistScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Liste ekle'),
          bottom: const TabBar(tabs: [Tab(text: 'M3U'), Tab(text: 'Xtream')]),
        ),
        body: const TabBarView(children: [_M3uForm(), _XtreamForm()]),
      ),
    );
  }
}

/// Ortak: yükleniyor durumu ve hata gösterimi.
mixin _Submitting<T extends StatefulWidget> on State<T> {
  bool busy = false;
  String? error;

  Future<void> run(Future<void> Function() task) async {
    FocusScope.of(context).unfocus();
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await task();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget errorBox() {
    if (error == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(error!, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }

  Widget submitButton(String label, VoidCallback onPressed) => Padding(
        padding: const EdgeInsets.only(top: 20),
        child: FilledButton(
          onPressed: busy ? null : onPressed,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(label),
        ),
      );
}

class _M3uForm extends StatefulWidget {
  const _M3uForm();
  @override
  State<_M3uForm> createState() => _M3uFormState();
}

class _M3uFormState extends State<_M3uForm> with _Submitting {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _epg = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _epg.dispose();
    super.dispose();
  }

  void _submitUrl() {
    if (_url.text.trim().isEmpty) {
      setState(() => error = 'Liste bağlantısını girin.');
      return;
    }
    run(() => context.read<AppState>().addM3u(_name.text, _url.text, epgUrl: _epg.text));
  }

  Future<void> _pickFile() async {
    final res = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    final file = res?.files.single;
    if (file == null) return;
    final bytes = file.bytes ?? (file.path != null ? await File(file.path!).readAsBytes() : null);
    if (bytes == null) return;
    final text = utf8.decode(bytes, allowMalformed: true);
    final name = _name.text.trim().isEmpty ? file.name : _name.text.trim();
    await run(() => context.read<AppState>().addLocalFile(name, text));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Liste adı (isteğe bağlı)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'M3U / M3U8 bağlantısı',
            hintText: 'http://…',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _epg,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'EPG adresi (isteğe bağlı)',
            helperText: 'Listede tanımlıysa otomatik bulunur.',
            border: OutlineInputBorder(),
          ),
        ),
        errorBox(),
        submitButton('Listeyi ekle', _submitUrl),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: busy ? null : _pickFile,
          icon: const Icon(Icons.folder_open),
          label: const Text('Cihazdan dosya seç'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
        ),
      ],
    );
  }
}

class _XtreamForm extends StatefulWidget {
  const _XtreamForm();
  @override
  State<_XtreamForm> createState() => _XtreamFormState();
}

class _XtreamFormState extends State<_XtreamForm> with _Submitting {
  final _name = TextEditingController();
  final _server = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _hide = true;

  @override
  void dispose() {
    for (final c in [_name, _server, _user, _pass]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (_server.text.trim().isEmpty || _user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => error = 'Sunucu adresi, kullanıcı adı ve şifre gerekli.');
      return;
    }
    run(() => context.read<AppState>().addXtream(_name.text, _server.text, _user.text, _pass.text));
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Liste adı (isteğe bağlı)', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _server,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Sunucu adresi',
            hintText: 'http://sunucu.com:8080',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _user,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Kullanıcı adı', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _pass,
          obscureText: _hide,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Şifre',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              icon: Icon(_hide ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hide = !_hide),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Bilgileriniz yalnızca bu cihazda saklanır.',
          style: TextStyle(fontSize: 13),
        ),
        errorBox(),
        submitButton('Hesabı ekle', _submit),
      ],
    );
  }
}
