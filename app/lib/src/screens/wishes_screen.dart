import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/member_avatar.dart';
import '../widgets/undo_delete.dart';

extension WishData on SyncEngine {
  List<Wish> get wishes =>
      records(Collections.wishes).map(Wish.fromRecord).toList()..sort(
        (a, b) =>
            (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)),
      );

  /// Who gets what (never contains claims on my own wishes: the server
  /// does not send them to me).
  Map<String, WishClaim> get wishClaims => {
    for (final r in records(Collections.wishClaims))
      r.id: WishClaim.fromRecord(r),
  };

  void saveWish(Wish w) => put(Collections.wishes, w.id, w.toData());

  void deleteWish(String id) => delete(Collections.wishes, id);

  /// "Ich besorge das": seen by everyone but the wish's owner.
  void claimWish(Wish w) => put(
    Collections.wishClaims,
    w.id,
    WishClaim(wishId: w.id, claimedBy: memberId).toData([
      for (final m in members)
        if (m.id != w.ownerId) m.id,
    ]),
  );

  void releaseWish(String id) => delete(Collections.wishClaims, id);
}

/// Wish lists of the whole family: my own to edit, the others' to see what
/// they would like and say "Ich besorge das" – they never see who.
class WishesScreen extends StatefulWidget {
  const WishesScreen({super.key, this.memberId});

  /// Start on this member's list.
  final String? memberId;

  @override
  State<WishesScreen> createState() => _WishesScreenState();
}

class _WishesScreenState extends State<WishesScreen> {
  String? _member;

  @override
  Widget build(BuildContext context) {
    return DataBuilder(
      collections: const {
        Collections.wishes,
        Collections.wishClaims,
        'members',
      },
      builder: (context, engine) {
        final people = [
          for (final m in engine.members)
            if (!m.isGuest) m,
        ];
        final selected = _member ?? widget.memberId ?? engine.memberId;
        final mine = selected == engine.memberId;
        final wishes = [
          for (final w in engine.wishes)
            if (w.ownerId == selected && (mine || !w.received)) w,
        ];
        final claims = engine.wishClaims;
        final c = FamioColors.of(context);
        final accent = c.strong(FamioSection.home);
        return SectionPage(
          section: FamioSection.home,
          title: 'Wunschzettel',
          subtitle: mine
              ? 'Was du dir wünschst'
              : 'Was sich ${engine.member(selected)?.displayName ?? ''} wünscht',
          maxBodyWidth: 720,
          floating: mine && !engine.iAmGuest
              ? AddButton(
                  color: accent,
                  tooltip: 'Wunsch hinzufügen',
                  icon: AppIcons.plus,
                  onPressed: () => _edit(context, engine, null),
                )
              : null,
          body: ListView(
            padding: EdgeInsets.only(bottom: listBottomPadding(context)),
            children: [
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    for (final m in people)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          avatar: MemberAvatar(m, radius: 10),
                          label: Text(
                            m.id == engine.memberId ? 'Ich' : m.displayName,
                          ),
                          selected: m.id == selected,
                          onSelected: (_) => setState(() => _member = m.id),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (wishes.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    mine
                        ? 'Noch keine Wünsche. Die anderen sehen deine Liste '
                              'und können still „Ich besorge das“ wählen – '
                              'du erfährst nicht, wer was besorgt.'
                        : 'Noch keine Wünsche.',
                  ),
                ),
              for (final w in wishes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _WishCard(
                    wish: w,
                    mine: mine,
                    claim: mine ? null : claims[w.id],
                    engine: engine,
                    onEdit: () => _edit(context, engine, w),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, SyncEngine engine, Wish? w) async {
    final title = TextEditingController(text: w?.title);
    final link = TextEditingController(text: w?.link);
    final price = TextEditingController(text: w?.price);
    final note = TextEditingController(text: w?.note);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(w == null ? 'Neuer Wunsch' : 'Wunsch bearbeiten'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Was?'),
              ),
              TextField(
                controller: link,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(labelText: 'Link (optional)'),
              ),
              TextField(
                controller: price,
                decoration: const InputDecoration(
                  labelText: 'Preis (optional)',
                  hintText: 'z. B. ca. 25 €',
                ),
              ),
              TextField(
                controller: note,
                decoration: const InputDecoration(
                  labelText: 'Hinweis (Größe, Farbe …)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          if (w != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context, false);
                deleteWithUndo(
                  this.context,
                  what: w.title,
                  collections: const {Collections.wishes},
                  delete: () => engine.deleteWish(w.id),
                );
              },
              child: const Text('Löschen'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Speichern'),
          ),
        ],
      ),
    );
    if (save == true && title.text.trim().isNotEmpty) {
      engine.saveWish(
        Wish(
          id: w?.id ?? newId(),
          ownerId: engine.memberId,
          title: title.text.trim(),
          link: link.text.trim(),
          price: price.text.trim(),
          note: note.text.trim(),
          received: w?.received ?? false,
          createdAt: w?.createdAt ?? DateTime.now(),
        ),
      );
    }
    for (final c in [title, link, price, note]) {
      c.dispose();
    }
  }
}

class _WishCard extends StatelessWidget {
  const _WishCard({
    required this.wish,
    required this.mine,
    required this.claim,
    required this.engine,
    required this.onEdit,
  });

  final Wish wish;
  final bool mine;
  final WishClaim? claim;
  final SyncEngine engine;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = FamioColors.of(context);
    final byMe = claim?.claimedBy == engine.memberId;
    final details = [
      if (wish.price.isNotEmpty) wish.price,
      if (wish.note.isNotEmpty) wish.note,
    ].join(' · ');
    return SoftCard(
      onTap: mine ? onEdit : null,
      color: wish.received ? c.surfaceSoft : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  wish.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    decoration: wish.received
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
              ),
              if (wish.link.isNotEmpty)
                IconButton(
                  tooltip: 'Link öffnen',
                  icon: const Icon(AppIcons.arrowSquareOut),
                  onPressed: () => launchUrl(
                    Uri.parse(
                      wish.link.contains('://')
                          ? wish.link
                          : 'https://${wish.link}',
                    ),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
            ],
          ),
          if (details.isNotEmpty) Text(details),
          const SizedBox(height: 6),
          if (mine)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: Icon(wish.received ? AppIcons.rotateCcw : AppIcons.check),
                label: Text(wish.received ? 'Doch noch wünschen' : 'Bekommen'),
                onPressed: () => engine.saveWish(
                  Wish(
                    id: wish.id,
                    ownerId: wish.ownerId,
                    title: wish.title,
                    link: wish.link,
                    price: wish.price,
                    note: wish.note,
                    received: !wish.received,
                    createdAt: wish.createdAt,
                  ),
                ),
              ),
            )
          else if (claim == null)
            FilledButton.tonalIcon(
              icon: const Icon(AppIcons.gift),
              label: const Text('Ich besorge das'),
              onPressed: () => engine.claimWish(wish),
            )
          else
            Row(
              children: [
                Icon(AppIcons.gift, size: 18, color: c.inkSoft),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    byMe
                        ? 'Du besorgst das'
                        : '${engine.member(claim!.claimedBy)?.displayName ?? 'Jemand'} besorgt das',
                    style: TextStyle(color: c.inkSoft),
                  ),
                ),
                if (byMe)
                  TextButton(
                    onPressed: () => engine.releaseWish(wish.id),
                    child: const Text('Freigeben'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
