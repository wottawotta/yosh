import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shiori/shiori.dart';

import 'package:mangayomi/services/http/source_mirrors.dart';
import 'package:mangayomi/services/m_extension_server.dart';

/// Domain mirrors for sources whose sites rotate or block domains: pick the
/// host a source always asks for and the live mirror it should reach instead.
/// Kept per device, and pushed to the Mihon extension server so APK
/// extensions (Keiyoushi and friends) honor them too.
class SourceMirrorsScreen extends ConsumerStatefulWidget {
  const SourceMirrorsScreen({super.key});

  @override
  ConsumerState<SourceMirrorsScreen> createState() =>
      _SourceMirrorsScreenState();
}

class _SourceMirrorsScreenState extends ConsumerState<SourceMirrorsScreen> {
  Future<void> _onStoreChanged() async {
    await SourceMirrorStore.save();
    unawaited(MExtensionServerPlatform(ref).syncSourceMirrors());
    setState(() {});
  }

  Future<void> _edit([SourceMirror? mirror]) async {
    final hostController = TextEditingController(
      text: mirror?.fromHost ?? '',
    );
    final originController = TextEditingController(
      text: mirror?.toOrigin ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(mirror == null ? 'Add mirror' : 'Edit mirror'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: hostController,
              autofocus: mirror == null,
              decoration: const InputDecoration(
                labelText: 'Source domain',
                helperText: 'The host the source asks for, e.g. kagane.to',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: originController,
              decoration: const InputDecoration(
                labelText: 'Mirror',
                helperText: 'Where to read instead, e.g. https://kagane.moe',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    final stored = SourceMirrorStore.upsert(
      hostController.text,
      originController.text,
    );
    if (stored == null) {
      botToast('Invalid mirror: check the domain and the mirror URL');
      return;
    }
    await _onStoreChanged();
  }

  Future<void> _delete(SourceMirror mirror) async {
    final confirmed = await showShioriConfirm(
      context,
      title: 'Remove mirror',
      message:
          'Requests to ${mirror.fromHost} go back to the source\u0027s own '
          'domain.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed) return;
    SourceMirrorStore.remove(mirror.fromHost);
    await _onStoreChanged();
  }

  @override
  Widget build(BuildContext context) {
    final mirrors = SourceMirrorStore.mirrors;
    return Scaffold(
      appBar: AppBar(title: const Text('Source mirrors')),
      body: ListView(
        padding: tvPageInsets,
        children: [
          ShioriSettingsGroup(
            title: "Redirect a source's domain to a mirror",
            footer:
                'Mirrors keep the path of every request: kagane.to \u2192 '
                'https://kagane.moe. They apply to this device and to its '
                'Mihon extension server, and are not synced.',
            children: [
              ShioriSettingRow(
                icon: Symbols.add_rounded,
                title: mirrors.isEmpty ? 'Add a mirror' : 'Add another mirror',
                onTap: () => _edit(),
              ),
              for (final mirror in mirrors)
                ShioriSettingRow(
                  icon: Symbols.swap_horiz_rounded,
                  title: mirror.fromHost,
                  subtitle: mirror.toOrigin,
                  onTap: () => _edit(mirror),
                  trailing: IconButton(
                    icon: const Icon(Symbols.delete_rounded),
                    onPressed: () => _delete(mirror),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
