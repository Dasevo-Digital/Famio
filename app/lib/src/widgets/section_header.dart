import 'package:flutter/material.dart';

import '../design/app_icons.dart';

/// Title and explanation above a group of settings.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, this.text, {super.key});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(text, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Numbered steps behind a question, e.g. how to set up another app.
class HelpSteps extends StatelessWidget {
  const HelpSteps(this.title, this.steps, {super.key});

  final String title;
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      title: Text(title, style: Theme.of(context).textTheme.bodyMedium),
      leading: const Icon(AppIcons.question, size: 22),
      childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, step) in steps.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('${i + 1}. $step'),
          ),
      ],
    );
  }
}
