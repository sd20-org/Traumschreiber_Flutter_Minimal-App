// Saved recordings: share or delete.
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../recording/recorder.dart';
import 'style.dart';

class RecordingsPage extends StatefulWidget {
  final AppState app;
  const RecordingsPage({super.key, required this.app});

  @override
  State<RecordingsPage> createState() => _RecordingsPageState();
}

class _RecordingsPageState extends State<RecordingsPage> {
  late Future<List<Recording>> _list = Recorder.list();
  bool _wasRecording = false;

  void _reload() {
    setState(() {
      _list = Recorder.list();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Refresh once a recording has just been stopped.
    final recording = widget.app.recorder.isRecording;
    if (_wasRecording && !recording) _list = Recorder.list();
    _wasRecording = recording;

    return FutureBuilder<List<Recording>>(
      future: _list,
      builder: (context, snap) {
        final all = snap.data ?? [];
        final data = all.where((r) => !_isCompanion(r.name)).toList();
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (data.isEmpty) {
          return const Center(
            child: Text('No recordings yet.\nConnect, then tap Record.',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: data.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, i) {
            final r = data[i];
            final extras = [for (final x in _companions) ...all.where((s) => s.name == r.name.replaceFirst('.csv', x))];
            final live = recording && widget.app.recorder.file?.path == r.file.path;
            return Card(
              child: ListTile(
                contentPadding: const EdgeInsets.fromLTRB(18, 8, 8, 8),
                leading: Icon(live ? Icons.fiber_manual_record_rounded : Icons.description_outlined,
                    color: live ? kRecord : kAccent),
                title: Text(r.name),
                subtitle: Text(
                    '${_date(r.modified)} · ${_duration(r.duration)} · '
                    '${(r.bytes / 1e6).toStringAsFixed(1)} MB'
                    '${extras.isNotEmpty ? ' · +${extras.length} file${extras.length > 1 ? 's' : ''}' : ''}',
                    style: const TextStyle(color: Colors.white54, fontSize: 12)),
                trailing: live
                    ? const Padding(padding: EdgeInsets.all(12), child: Text('recording'))
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          tooltip: 'Share',
                          icon: const Icon(Icons.ios_share_rounded),
                          onPressed: () => Recorder.share([r.file, for (final x in extras) x.file]),
                        ),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _delete(r, extras),
                        ),
                      ]),
              ),
            );
          },
        );
      },
    );
  }

  /// Files saved next to a recording: sleep stages and button presses.
  static const _companions = ['_stages.csv', '_button.csv'];
  static bool _isCompanion(String name) => _companions.any(name.endsWith);

  Future<void> _delete(Recording r, Iterable<Recording> extras) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete recording?'),
        content: Text(r.name),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await r.file.delete();
    for (final s in extras) {
      await s.file.delete();
    }
    _reload();
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
  static String _date(DateTime t) =>
      '${_two(t.day)}.${_two(t.month)}.${t.year} ${_two(t.hour)}:${_two(t.minute)}';
  static String _duration(Duration d) =>
      d.inHours > 0 ? '${d.inHours} h ${d.inMinutes % 60} min' : '${d.inMinutes} min ${d.inSeconds % 60} s';
}
