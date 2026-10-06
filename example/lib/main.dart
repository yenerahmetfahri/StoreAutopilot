import 'package:flutter/material.dart';

void main() => runApp(const ExampleApp());

/// A small task list with a stats screen, in English and German. The store screenshot test starts it with a fixed
/// language; everything else is the same app users get.
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, this.locale = 'en'});

  final String locale;

  @override
  Widget build(BuildContext context) {
    final text = Strings(locale);
    return MaterialApp(
      title: text['title'],
      theme: ThemeData(colorSchemeSeed: const Color(0xFF2563EB), useMaterial3: true),
      home: TasksScreen(text: text),
    );
  }
}

class Strings {
  Strings(String locale) : _values = _all[locale] ?? _all['en']!;

  final Map<String, String> _values;

  String operator [](String key) => _values[key]!;

  static const _all = {
    'en': {
      'title': 'Tiny Tasks',
      'today': 'Today',
      'stats': 'This week',
      'done': 'done',
      'streak': 'day streak',
      'tasks': 'Water the plants|Call the bank|Read 20 pages|Go for a run|Plan the weekend',
    },
    'de': {
      'title': 'Tiny Tasks',
      'today': 'Heute',
      'stats': 'Diese Woche',
      'done': 'erledigt',
      'streak': 'Tage in Folge',
      'tasks': 'Pflanzen gießen|Die Bank anrufen|20 Seiten lesen|Laufen gehen|Das Wochenende planen',
    },
  };
}

class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, required this.text});

  final Strings text;

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  final _done = <int>{0, 2};

  @override
  Widget build(BuildContext context) {
    final tasks = widget.text['tasks'].split('|');
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.text['today']),
        actions: [
          IconButton(
            key: const Key('stats'),
            icon: const Icon(Icons.insights),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => StatsScreen(text: widget.text)),
            ),
          ),
        ],
      ),
      body: ListView(
        children: [
          for (final (i, task) in tasks.indexed)
            CheckboxListTile(
              value: _done.contains(i),
              title: Text(task),
              onChanged: (on) => setState(() => on! ? _done.add(i) : _done.remove(i)),
            ),
        ],
      ),
    );
  }
}

class StatsScreen extends StatelessWidget {
  const StatsScreen({super.key, required this.text});

  final Strings text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(text['stats'])),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 180,
              child: CircularProgressIndicator(value: 0.72, strokeWidth: 14),
            ),
            const SizedBox(height: 32),
            Text('72% ${text['done']}', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text('5 ${text['streak']}', style: theme.textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
