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
import '../l10n.dart';

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

  /// An idea goes to everyone but its owner (the server makes sure).
  void saveWish(Wish w) => put(
    Collections.wishes,
    w.id,
    w.toData(w.isIdea ? [for (final m in members) m.id] : null),
  );

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
/// they would like and say "Ich besorge das" – they never see who. On the
/// others' lists the family also notes gift ideas, hidden from that person.
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
            if (w.ownerId == selected && !w.isIdea && (mine || !w.received)) w,
        ];
        final ideas = [
          for (final w in engine.wishes)
            if (w.ownerId == selected && w.isIdea && !mine) w,
        ];
        final name = engine.member(selected)?.displayName ?? '';
        final claims = engine.wishClaims;
        final c = FamioColors.of(context);
        final accent = c.strong(FamioSection.home);
        return SectionPage(
          section: FamioSection.home,
          title: tr.settingsWishes,
          subtitle: mine ? tr.wishesWhatYouWish : tr.wishesWhatNameWishes(name),
          maxBodyWidth: 720,
          floating: engine.iAmGuest
              ? null
              : AddButton(
                  color: accent,
                  tooltip: mine ? tr.wishesAddWish : tr.wishesAddIdea,
                  icon: mine ? AppIcons.plus : AppIcons.lightbulb,
                  onPressed: () => _edit(
                    context,
                    engine,
                    null,
                    ideaFor: mine ? null : selected,
                  ),
                ),
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
                            m.id == engine.memberId
                                ? tr.shoppingMe
                                : m.displayName,
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
                    mine ? tr.wishesNoWishesYetOthers : tr.wishesNoWishesYet,
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
              if (!mine && !engine.iAmGuest) ...[
                ListHeading(tr.wishesGiftIdeas, color: accent),
                if (ideas.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Text(
                      tr.wishesIdeasHidden(name),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: c.inkSoft),
                    ),
                  ),
                if (ideas.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr.wishesNoIdeasYet(name)),
                  ),
                for (final w in ideas)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _WishCard(
                      wish: w,
                      mine: false,
                      claim: claims[w.id],
                      engine: engine,
                      onEdit: () => _edit(context, engine, w),
                    ),
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// [w] or a new wish; with [ideaFor] a new gift idea for that member.
  Future<void> _edit(
    BuildContext context,
    SyncEngine engine,
    Wish? w, {
    String? ideaFor,
  }) async {
    final idea = w?.isIdea ?? ideaFor != null;
    final owner = w?.ownerId ?? ideaFor ?? engine.memberId;
    final title = TextEditingController(text: w?.title);
    final link = TextEditingController(text: w?.link);
    final price = TextEditingController(text: w?.price);
    final note = TextEditingController(text: w?.note);
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          idea
              ? (w == null
                    ? tr.wishesNewIdea(engine.member(owner)?.displayName ?? '')
                    : tr.wishesEditIdea)
              : (w == null ? tr.wishesNewWish : tr.wishesEditWish),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: title,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: tr.wishesWhat),
              ),
              TextField(
                controller: link,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(labelText: tr.wishesLinkOptional),
              ),
              TextField(
                controller: price,
                decoration: InputDecoration(
                  labelText: tr.wishesPriceOptional,
                  hintText: tr.wishesEGAbout25,
                ),
              ),
              TextField(
                controller: note,
                decoration: InputDecoration(labelText: tr.wishesNoteSizeColor),
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
              child: Text(tr.commonDelete),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonSave),
          ),
        ],
      ),
    );
    if (save == true && title.text.trim().isNotEmpty) {
      engine.saveWish(
        Wish(
          id: w?.id ?? newId(),
          ownerId: owner,
          title: title.text.trim(),
          link: link.text.trim(),
          price: price.text.trim(),
          note: note.text.trim(),
          received: w?.received ?? false,
          createdAt: w?.createdAt ?? DateTime.now(),
          ideaBy: idea ? (w?.ideaBy ?? engine.memberId) : null,
        ),
      );
    }
    // Not disposed: the dialog still shows them while it closes.
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
      onTap: mine || wish.isIdea ? onEdit : null,
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
                  tooltip: tr.wishesOpenLink,
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
          if (wish.isIdea)
            Text(
              wish.ideaBy == engine.memberId
                  ? tr.wishesYourIdea
                  : tr.wishesIdeaBy(
                      engine.member(wish.ideaBy!)?.displayName ??
                          tr.commonSomeone,
                    ),
              style: theme.textTheme.bodySmall?.copyWith(color: c.inkSoft),
            ),
          const SizedBox(height: 6),
          if (mine)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: Icon(wish.received ? AppIcons.rotateCcw : AppIcons.check),
                label: Text(
                  wish.received ? tr.wishesWishAgain : tr.wishesReceived,
                ),
                onPressed: () =>
                    engine.saveWish(wish.copyWith(received: !wish.received)),
              ),
            )
          else if (claim == null)
            FilledButton.tonalIcon(
              icon: const Icon(AppIcons.gift),
              label: Text(tr.wishesILlGet),
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
                        ? tr.wishesYouReGetting
                        : tr.wishesNameGetting(
                            engine.member(claim!.claimedBy)?.displayName ??
                                tr.commonSomeone,
                          ),
                    style: TextStyle(color: c.inkSoft),
                  ),
                ),
                if (byMe)
                  TextButton(
                    onPressed: () => engine.releaseWish(wish.id),
                    child: Text(tr.wishesRelease),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
