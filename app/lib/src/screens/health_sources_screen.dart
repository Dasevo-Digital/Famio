import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../design/app_icons.dart';
import '../l10n.dart';

/// Where the health content of the app comes from, with its date: the
/// vaccination calendar, the check-up booklet, the fever hints, the growth
/// curves and the pregnancy deadlines (#527). Titles are those of the
/// German sources.
class HealthSourcesScreen extends StatelessWidget {
  const HealthSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final groups = <(String, List<_Source>)>[
      (
        tr.sourcesVaccinations,
        const [
          _Source(
            'STIKO-Empfehlungen 2026, Epidemiologisches Bulletin 4/2026', // l10n: Titel der Quelle
            'RKI, 22.01.2026',
            'https://www.rki.de/DE/Aktuelles/Publikationen/Epidemiologisches-Bulletin/2026/04_26.html',
          ),
        ],
      ),
      (
        tr.sourcesCheckups,
        const [
          _Source(
            'Kinderuntersuchungsheft (gelbes Heft) mit Stuhlfarbkarte', // l10n: Titel der Quelle
            'G-BA, Juni 2026',
            'https://www.g-ba.de/downloads/17-98-4160/260618_G-BA_Kinderuntersuchungsheft_WEB_WZ.pdf',
          ),
        ],
      ),
      (
        tr.sourcesFever,
        const [
          _Source(
            'Fieber bei Kindern', // l10n: Titel der Quelle
            'kindergesundheit-info.de (BIÖG), 04.05.2026',
            'https://www.kindergesundheit-info.de/themen/krankes-kind/krankheitszeichen/fieber/',
          ),
        ],
      ),
      (
        tr.sourcesGrowth,
        const [
          _Source(
            'WHO Child Growth Standards',
            'WHO, 2006',
            'https://www.who.int/tools/child-growth-standards',
          ),
          _Source(
            'WHO Motor Development Study',
            'WHO, 2006',
            'https://www.who.int/tools/child-growth-standards/standards/motor-development-milestones',
          ),
        ],
      ),
      (
        tr.sourcesPregnancy,
        const [
          _Source(
            'Mutterschafts-Richtlinien', // l10n: Titel der Quelle
            'G-BA, 16.07.2026',
            'https://www.g-ba.de/downloads/62-492-4201/Mu-RL_2026-07-16_iK-2026-08-25.pdf',
          ),
          _Source(
            'Mutterschutzgesetz, § 3 Schutzfristen', // l10n: Titel der Quelle
            'gesetze-im-internet.de',
            'https://www.gesetze-im-internet.de/muschg_2018/__3.html',
          ),
          _Source(
            'Bundeselterngeld- und Elternzeitgesetz, § 16', // l10n: Titel der Quelle
            'gesetze-im-internet.de',
            'https://www.gesetze-im-internet.de/beeg/__16.html',
          ),
        ],
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(tr.sourcesTitle)),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(tr.sourcesIntro, style: theme.textTheme.bodyMedium),
          ),
          for (final (topic, sources) in groups) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(topic, style: theme.textTheme.titleSmall),
            ),
            for (final s in sources)
              ListTile(
                title: Text(s.title),
                subtitle: Text(s.stand),
                trailing: const Icon(AppIcons.arrowSquareOut, size: 18),
                onTap: () => launchUrl(
                  Uri.parse(s.url),
                  mode: LaunchMode.externalApplication,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Source {
  const _Source(this.title, this.stand, this.url);

  final String title;
  final String stand;
  final String url;
}
