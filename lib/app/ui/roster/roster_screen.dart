/// RosterScreen — profile header + three-tab view: Servants | CEs | Mystic Codes.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../optimizer/roster/user_roster.dart';
import 'ce_list_page.dart';
import 'mc_list_page.dart';
import 'roster_notifier.dart';
import 'servant_list_page.dart';

class RosterScreen extends StatelessWidget {
  const RosterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final roster = RosterScope.of(context).roster;
    final svtCount = roster.servants.length;
    final ceCount = roster.craftEssences.length;
    final mcCount = roster.mysticCodes.length;

    return Column(
      children: [
        const _ProfileHeader(),
        Expanded(
          child: DefaultTabController(
            length: 3,
            child: Column(
              children: [
                TabBar(
                  tabs: [
                    Tab(text: 'Servants ($svtCount)'),
                    Tab(text: 'CEs ($ceCount)'),
                    Tab(text: 'Mystic Codes ($mcCount)'),
                  ],
                ),
                const Expanded(
                  child: TabBarView(
                    children: [
                      ServantListPage(),
                      CeListPage(),
                      McListPage(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// _ProfileHeader — active profile selector + management actions
// ---------------------------------------------------------------------------

enum _ProfileAction { newProfile, rename, delete, export, import }

class _ProfileHeader extends StatelessWidget {
  const _ProfileHeader();

  @override
  Widget build(BuildContext context) {
    final notifier = RosterScope.of(context);
    final profiles = notifier.profiles;
    final current = notifier.activeProfileName;
    // Guard against transient state where the active name isn't in the list yet
    final items = profiles.contains(current) ? profiles : [...profiles, current];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Text('Profile:', style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(width: 8),
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: current,
              isDense: true,
              items: items
                  .map((p) => DropdownMenuItem(value: p, child: Text(p)))
                  .toList(),
              onChanged: (name) {
                if (name != null) notifier.switchProfile(name);
              },
            ),
          ),
          const Spacer(),
          PopupMenuButton<_ProfileAction>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'Profile actions',
            onSelected: (action) => _dispatch(context, action, notifier),
            itemBuilder: (_) => [
              _menuItem(_ProfileAction.newProfile, Icons.add, 'New Profile'),
              _menuItem(_ProfileAction.rename, Icons.edit_outlined, 'Rename'),
              _menuItem(_ProfileAction.delete, Icons.delete_outline, 'Delete'),
              const PopupMenuDivider(),
              _menuItem(_ProfileAction.export, Icons.upload_outlined, 'Export to file…'),
              _menuItem(_ProfileAction.import, Icons.download_outlined, 'Import from file…'),
            ],
          ),
        ],
      ),
    );
  }

  static PopupMenuItem<_ProfileAction> _menuItem(
    _ProfileAction value,
    IconData icon,
    String label,
  ) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Text(label),
        ],
      ),
    );
  }

  void _dispatch(
      BuildContext context, _ProfileAction action, RosterNotifier notifier) {
    switch (action) {
      case _ProfileAction.newProfile:
        _showNewDialog(context, notifier);
      case _ProfileAction.rename:
        _showRenameDialog(context, notifier);
      case _ProfileAction.delete:
        _showDeleteConfirm(context, notifier);
      case _ProfileAction.export:
        _doExport(context, notifier);
      case _ProfileAction.import:
        _doImport(context, notifier);
    }
  }

  // -------------------------------------------------------------------------
  // New profile dialog
  // -------------------------------------------------------------------------

  void _showNewDialog(BuildContext context, RosterNotifier notifier) {
    final ctrl = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        void submit() {
          final name = ctrl.text.trim();
          if (!_validName(name)) {
            _showError(ctx, _nameError);
            return;
          }
          try {
            notifier.createNewProfile(name);
            Navigator.pop(ctx);
          } on ArgumentError catch (e) {
            _showError(ctx, e.message as String);
          }
        }

        return AlertDialog(
          title: const Text('New Profile'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Profile name'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(onPressed: submit, child: const Text('Create')),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Rename dialog
  // -------------------------------------------------------------------------

  void _showRenameDialog(BuildContext context, RosterNotifier notifier) {
    final ctrl = TextEditingController(text: notifier.activeProfileName);
    ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
    showDialog<void>(
      context: context,
      builder: (ctx) {
        void submit() {
          final name = ctrl.text.trim();
          if (!_validName(name)) {
            _showError(ctx, _nameError);
            return;
          }
          try {
            notifier.renameCurrentProfile(name);
            Navigator.pop(ctx);
          } on ArgumentError catch (e) {
            _showError(ctx, e.message as String);
          }
        }

        return AlertDialog(
          title: const Text('Rename Profile'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'New name'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(onPressed: submit, child: const Text('Rename')),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Delete confirmation dialog
  // -------------------------------------------------------------------------

  void _showDeleteConfirm(BuildContext context, RosterNotifier notifier) {
    final name = notifier.activeProfileName;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Profile'),
        content: Text('Delete "$name"? This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.deleteCurrentProfile();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Export
  // -------------------------------------------------------------------------

  Future<void> _doExport(
      BuildContext context, RosterNotifier notifier) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Roster',
      fileName: '${notifier.activeProfileName}.json',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (path == null) return;
    try {
      notifier.exportCurrentProfile(path);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to $path')),
        );
      }
    } catch (e) {
      if (context.mounted) _showError(context, 'Export failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Import
  // -------------------------------------------------------------------------

  Future<void> _doImport(
      BuildContext context, RosterNotifier notifier) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import Roster',
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;

    UserRoster imported;
    try {
      imported = UserRoster.fromJsonString(File(path).readAsStringSync());
    } catch (e) {
      if (context.mounted) _showError(context, 'Could not read file: $e');
      return;
    }

    if (!context.mounted) return;

    if (notifier.profiles.contains(imported.profileName)) {
      _showImportCollisionDialog(context, notifier, imported);
    } else {
      notifier.saveImported(imported);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${imported.profileName}"')),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Import collision: overwrite or rename
  // -------------------------------------------------------------------------

  void _showImportCollisionDialog(
    BuildContext context,
    RosterNotifier notifier,
    UserRoster imported,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Profile Already Exists'),
        content: Text(
          'A profile named "${imported.profileName}" already exists.\n'
          'Overwrite it, or save under a new name?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _showImportRenameDialog(context, notifier, imported);
            },
            child: const Text('Rename…'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              notifier.saveImported(imported);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content:
                          Text('Overwrote "${imported.profileName}"')),
                );
              }
            },
            style:
                TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Overwrite'),
          ),
        ],
      ),
    );
  }

  void _showImportRenameDialog(
    BuildContext context,
    RosterNotifier notifier,
    UserRoster imported,
  ) {
    final ctrl =
        TextEditingController(text: '${imported.profileName}_imported');
    ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: ctrl.text.length);
    showDialog<void>(
      context: context,
      builder: (ctx) {
        void submit() {
          final name = ctrl.text.trim();
          if (!_validName(name)) {
            _showError(ctx, _nameError);
            return;
          }
          if (notifier.profiles.contains(name)) {
            _showError(ctx, 'A profile named "$name" already exists.');
            return;
          }
          notifier.saveImported(imported.copyWith(profileName: name));
          Navigator.pop(ctx);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Imported as "$name"')),
            );
          }
        }

        return AlertDialog(
          title: const Text('Save As'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'New profile name'),
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            TextButton(onPressed: submit, child: const Text('Save')),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  static const _nameError =
      'Name must not be empty and may only contain letters, numbers, '
      'spaces, hyphens, and underscores.';

  static bool _validName(String name) =>
      name.isNotEmpty && RegExp(r'^[a-zA-Z0-9 _-]+$').hasMatch(name);

  static void _showError(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }
}
