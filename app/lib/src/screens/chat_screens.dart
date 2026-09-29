import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import '../widgets/data_builder.dart';
import '../widgets/files.dart';
import '../widgets/member_avatar.dart';
import '../widgets/sync_status_icon.dart';

const _chatCollections = {
  Collections.chatMessages,
  Collections.chatReads,
  Collections.pollVotes,
  'members',
};

/// The family chat plus one direct chat per other member. On wide screens
/// (tablets, desktop) the open chat sits next to the list.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  var _open = (ChatIds.family, 'Familie');

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 900) return _list(context, null);
      final (chatId, title) = _open;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 380, child: _list(context, chatId)),
          Expanded(
            child: ChatScreen(
              key: ValueKey(chatId),
              chatId: chatId,
              title: title,
            ),
          ),
        ],
      );
    },
  );

  /// [selected]: the chat shown beside the list, else chats open full size.
  Widget _list(BuildContext context, String? selected) {
    final c = FamioColors.of(context);
    void open(String chatId, String title) => selected == null
        ? Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatScreen(chatId: chatId, title: title),
            ),
          )
        : setState(() => _open = (chatId, title));
    return SectionPage(
      section: FamioSection.chat,
      title: 'Chat',
      subtitle: 'Nachrichten an die Familie',
      actions: const [SyncStatusIcon()],
      body: DataBuilder(
        collections: _chatCollections,
        builder: (context, engine) {
          final others = engine.members
              .where((m) => m.id != engine.memberId)
              .toList();
          return ListView(
            padding: EdgeInsets.only(
              top: 8,
              bottom: listBottomPadding(context),
            ),
            children: [
              _ChatTile(
                chatId: ChatIds.family,
                title: 'Familie',
                leading: IconBlob(
                  AppIcons.usersThree,
                  color: c.strong(FamioSection.chat),
                  size: 52,
                ),
                engine: engine,
                selected: selected == ChatIds.family,
                onTap: () => open(ChatIds.family, 'Familie'),
              ),
              if (others.isNotEmpty) const ListHeading('Einzelchats'),
              for (final m in others)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ChatTile(
                    chatId: ChatIds.direct(engine.memberId, m.id),
                    title: m.displayName,
                    leading: MemberAvatar(m, radius: 26),
                    engine: engine,
                    selected:
                        selected == ChatIds.direct(engine.memberId, m.id),
                    onTap: () => open(
                      ChatIds.direct(engine.memberId, m.id),
                      m.displayName,
                    ),
                  ),
                ),
              if (others.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Sobald weitere Familienmitglieder dabei sind, könnt ihr euch '
                    'hier auch einzeln schreiben.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ChatTile extends StatelessWidget {
  const _ChatTile({
    required this.chatId,
    required this.title,
    required this.leading,
    required this.engine,
    required this.onTap,
    this.selected = false,
  });

  final String chatId;
  final String title;
  final Widget leading;
  final SyncEngine engine;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final messages = engine.chatMessages(chatId);
    final last = messages.lastOrNull;
    final unread = engine.unreadCount(chatId);
    final author = last == null ? null : engine.member(last.authorId);
    final preview = last == null
        ? 'Noch keine Nachrichten – sag Hallo! 👋'
        : '${last.authorId == engine.memberId ? 'Du: ' : (ChatIds.isDirect(chatId) ? '' : '${author?.displayName ?? '?'}: ')}'
              '${last.poll != null
                  ? '📊 ${last.poll!.question}'
                  : last.text.isNotEmpty
                  ? last.text
                  : '📎 ${last.attachment?.name ?? 'Anhang'}'}';
    return SoftCard(
      padding: const EdgeInsets.all(14),
      color: selected ? c.tint(FamioSection.chat) : null,
      onTap: onTap,
      child: Row(
        children: [
          leading,
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  preview,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: unread > 0 ? c.ink : c.inkSoft,
                    fontWeight: unread > 0 ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (last != null)
                Text(
                  _shortTime(last.sentAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 4),
              if (unread > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: c.strong(FamioSection.chat),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$unread',
                    style: TextStyle(
                      color: c.onStrong,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String _shortTime(DateTime t) => DateUtils.isSameDay(t, DateTime.now())
    ? timeLabel(t)
    : DateFormat('d.M.', 'de').format(t);

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.chatId, required this.title});

  final String chatId;
  final String title;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  var _uploading = false;

  @override
  void initState() {
    super.initState();
    _focus.onKeyEvent = (node, event) {
      // Enter sends, Shift+Enter makes a new line (desktop keyboards).
      if (event is KeyDownEvent &&
          event.logicalKey == LogicalKeyboardKey.enter &&
          !HardwareKeyboard.instance.isShiftPressed) {
        _send();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    AppScope.engineOf(context).sendChatMessage(widget.chatId, text: text);
    _input.clear();
    _focus.requestFocus();
  }

  Future<void> _attach() async {
    final picked = await pickFile(context);
    if (picked == null || !mounted) return;
    setState(() => _uploading = true);
    try {
      final ref = await uploadPicked(context, picked);
      if (!mounted) return;
      AppScope.engineOf(context).sendChatMessage(
        widget.chatId,
        text: _input.text.trim(),
        attachment: ref,
      );
      _input.clear();
    } on ApiError catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _createPoll() async {
    final poll = await showPollEditor(context);
    if (poll == null || !mounted) return;
    AppScope.engineOf(context).sendPoll(widget.chatId, poll);
  }

  Future<void> _deleteMessage(ChatMessage m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nachricht löschen?'),
        content: const Text('Sie verschwindet für alle.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Löschen'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      AppScope.engineOf(context).deleteChatMessage(m.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.chat);
    return SectionPage(
      section: FamioSection.chat,
      title: widget.title,
      subtitle: ChatIds.isDirect(widget.chatId)
          ? 'Privat – nur ihr zwei'
          : 'Alle in der Familie',
      bodyPadding: EdgeInsets.zero,
      body: DataBuilder(
        collections: _chatCollections,
        builder: (context, engine) {
          final messages = engine.chatMessages(widget.chatId);
          // Everything visible counts as read.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (messages.isNotEmpty) {
              engine.markChatRead(widget.chatId, at: messages.last.sentAt);
            }
          });
          final otherId = engine
              .chatAudience(widget.chatId)
              ?.firstWhere((id) => id != engine.memberId, orElse: () => '');
          final otherRead = otherId == null || otherId.isEmpty
              ? null
              : engine.lastRead(widget.chatId, otherId);
          final lastMine = messages.lastWhere(
            (m) => m.authorId == engine.memberId,
            orElse: () => _none,
          );

          return Column(
            children: [
              Expanded(
                child: messages.isEmpty
                    ? EmptyHint(
                        icon: AppIcons.chatCircleDots,
                        color: color,
                        text:
                            'Noch ganz still hier.\nSchreib die erste Nachricht!',
                      )
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                        itemCount: messages.length,
                        itemBuilder: (context, i) {
                          final index = messages.length - 1 - i;
                          final m = messages[index];
                          final previous = index > 0
                              ? messages[index - 1]
                              : null;
                          final newDay =
                              previous == null ||
                              !DateUtils.isSameDay(previous.sentAt, m.sentAt);
                          final sameAuthor =
                              !newDay && previous.authorId == m.authorId;
                          return Column(
                            children: [
                              if (newDay) _DaySeparator(m.sentAt),
                              _Bubble(
                                message: m,
                                mine: m.authorId == engine.memberId,
                                author: engine.member(m.authorId),
                                showAuthor:
                                    !sameAuthor &&
                                    !ChatIds.isDirect(widget.chatId),
                                read:
                                    m.id == lastMine.id &&
                                    otherRead != null &&
                                    !otherRead.isBefore(m.sentAt),
                                onLongPress: m.authorId == engine.memberId
                                    ? () => _deleteMessage(m)
                                    : null,
                                poll: m.poll == null
                                    ? null
                                    : _PollView(message: m, engine: engine),
                              ),
                            ],
                          );
                        },
                      ),
              ),
              _Composer(
                controller: _input,
                focus: _focus,
                color: color,
                uploading: _uploading,
                onSend: _send,
                onAttach: _attach,
                onPoll: _createPoll,
              ),
            ],
          );
        },
      ),
    );
  }
}

final _none = ChatMessage(
  id: '',
  chatId: '',
  authorId: '',
  sentAt: DateTime(0),
);

class _DaySeparator extends StatelessWidget {
  const _DaySeparator(this.day);

  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: c.surfaceSoft,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            dayLabel(day),
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: c.inkSoft),
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.message,
    required this.mine,
    required this.author,
    required this.showAuthor,
    required this.read,
    this.onLongPress,
    this.poll,
  });

  final Widget? poll;
  final ChatMessage message;
  final bool mine;
  final FamilyMember? author;
  final bool showAuthor;
  final bool read;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final background = mine ? c.strong(FamioSection.chat) : c.surface;
    final foreground = mine ? c.onStrong : c.ink;
    final attachment = message.attachment;
    final maxWidth =
        MediaQuery.sizeOf(context).width *
        (MediaQuery.sizeOf(context).width > 720 ? 0.45 : 0.75);

    final bubble = GestureDetector(
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(22),
            topRight: const Radius.circular(22),
            bottomLeft: Radius.circular(mine ? 22 : 6),
            bottomRight: Radius.circular(mine ? 6 : 22),
          ),
          boxShadow: mine ? null : c.softShadow,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showAuthor && !mine && author != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  author!.displayName,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: Color(author!.color ?? 0xFF636A8A),
                  ),
                ),
              ),
            if (attachment != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: attachment.isImage
                    ? GestureDetector(
                        onTap: () => openFileRef(context, attachment),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: CachedImage(
                            attachment,
                            thumb: 480,
                            fit: BoxFit.cover,
                            radius: 16,
                          ),
                        ),
                      )
                    : _FileChip(ref: attachment, onColor: mine),
              ),
            ?poll,
            if (message.text.isNotEmpty)
              Text(
                message.text,
                style: theme.textTheme.bodyLarge?.copyWith(color: foreground),
              ),
            const SizedBox(height: 2),
            Align(
              alignment: Alignment.bottomRight,
              child: Text(
                '${timeLabel(message.sentAt)}${read ? ' · gelesen' : ''}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: mine ? Colors.white.withValues(alpha: 0.8) : c.inkSoft,
                  fontSize: 10.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return Padding(
      padding: EdgeInsets.only(top: showAuthor ? 8 : 3),
      child: Row(
        mainAxisAlignment: mine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!mine && author != null) ...[
            Opacity(
              opacity: showAuthor ? 1 : 0,
              child: MemberAvatar(author!, radius: 14),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(child: bubble),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  const _FileChip({required this.ref, required this.onColor});

  final FileRef ref;
  final bool onColor;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final fg = onColor ? Colors.white : c.ink;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => openFileRef(context, ref),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: onColor ? Colors.white.withValues(alpha: 0.18) : c.surfaceSoft,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(fileIcon(ref.mime), color: fg, size: 28),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    ref.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(
                      context,
                    ).textTheme.labelLarge?.copyWith(color: fg),
                  ),
                  Text(
                    fileSizeLabel(ref.size),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: fg.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.focus,
    required this.color,
    required this.uploading,
    required this.onSend,
    required this.onAttach,
    required this.onPoll,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final Color color;
  final bool uploading;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final VoidCallback onPoll;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SafeArea(
      top: false,
      child: Container(
        margin: EdgeInsets.fromLTRB(
          12,
          4,
          12,
          MediaQuery.sizeOf(context).width < 720 ? 92 : 12,
        ),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(30),
          boxShadow: c.softShadow,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            uploading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  )
                : BubbleButton(
                    icon: AppIcons.paperclip,
                    tooltip: 'Foto oder Datei senden',
                    background: c.surfaceSoft,
                    onPressed: onAttach,
                  ),
            const SizedBox(width: 4),
            BubbleButton(
              icon: AppIcons.poll,
              tooltip: 'Umfrage',
              background: c.surfaceSoft,
              onPressed: onPoll,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focus,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Nachricht …',
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 12,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
            BubbleButton(
              icon: AppIcons.paperPlaneRight,
              tooltip: 'Senden',
              color: Colors.white,
              background: color,
              onPressed: onSend,
            ),
          ],
        ),
      ),
    );
  }
}

/// Votes of a chat poll, tappable while open.
class _PollView extends StatelessWidget {
  const _PollView({required this.message, required this.engine});

  final ChatMessage message;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final poll = message.poll!;
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final mine = message.authorId == engine.memberId;
    final fg = mine ? c.onStrong : c.ink;
    final votes = engine.pollVotes(message.id);
    final myVote = votes
        .where((v) => v.memberId == engine.memberId)
        .firstOrNull;
    final chosen = {...?myVote?.optionIds};
    final voters = votes.length;
    final canVote = !poll.closed;

    void toggle(String optionId) {
      if (!canVote) return;
      final next = poll.multiple
          ? (chosen.contains(optionId)
                ? (chosen..remove(optionId))
                : (chosen..add(optionId)))
          : (chosen.contains(optionId) ? <String>{} : {optionId});
      engine.vote(message, next.toList());
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.poll, size: 18, color: fg),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  poll.question,
                  style: theme.textTheme.titleMedium?.copyWith(color: fg),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final o in poll.options) ...[
            () {
              final count = votes
                  .where((v) => v.optionIds.contains(o.id))
                  .length;
              final names = [
                for (final v in votes)
                  if (v.optionIds.contains(o.id))
                    engine.member(v.memberId)?.displayName ?? '?',
              ];
              return InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: canVote ? () => toggle(o.id) : null,
                child: Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  decoration: BoxDecoration(
                    color: mine
                        ? Colors.white.withValues(alpha: 0.16)
                        : c.surfaceSoft,
                    borderRadius: BorderRadius.circular(12),
                    border: chosen.contains(o.id)
                        ? Border.all(color: fg, width: 2)
                        : null,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              o.text,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: fg,
                              ),
                            ),
                          ),
                          Text(
                            '$count',
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: fg,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: voters == 0 ? 0 : count / voters,
                          minHeight: 5,
                          color: mine
                              ? Colors.white
                              : c.strong(FamioSection.chat),
                          backgroundColor: mine
                              ? Colors.white.withValues(alpha: 0.25)
                              : c.line,
                        ),
                      ),
                      if (names.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            names.join(', '),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: fg.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            }(),
          ],
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    '$voters ${voters == 1 ? 'Stimme' : 'Stimmen'}',
                    if (poll.multiple) 'mehrere Antworten möglich',
                    if (poll.closed) 'beendet',
                  ].join(' · '),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: fg.withValues(alpha: 0.8),
                  ),
                ),
              ),
              if (mine && !poll.closed)
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: fg,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => engine.closePoll(message),
                  child: const Text('Beenden'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Asks for question and answers of a new poll.
Future<Poll?> showPollEditor(BuildContext context) =>
    showDialog<Poll>(context: context, builder: (_) => const _PollEditor());

class _PollEditor extends StatefulWidget {
  const _PollEditor();

  @override
  State<_PollEditor> createState() => _PollEditorState();
}

class _PollEditorState extends State<_PollEditor> {
  final _question = TextEditingController();
  final _options = [TextEditingController(), TextEditingController()];
  var _multiple = false;

  @override
  void dispose() {
    _question.dispose();
    for (final o in _options) {
      o.dispose();
    }
    super.dispose();
  }

  void _send() {
    final question = _question.text.trim();
    final options = [
      for (final o in _options)
        if (o.text.trim().isNotEmpty) o.text.trim(),
    ];
    if (question.isEmpty || options.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Frage und mindestens zwei Antworten')),
      );
      return;
    }
    Navigator.pop(
      context,
      Poll(
        question: question,
        multiple: _multiple,
        options: [
          for (final (i, text) in options.indexed)
            PollOption(id: 'o$i', text: text),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('Umfrage'),
    content: SizedBox(
      width: 380,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _question,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Frage',
              hintText: 'z. B. Wohin am Sonntag?',
            ),
          ),
          const SizedBox(height: 12),
          for (final (i, o) in _options.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: o,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: 'Antwort ${i + 1}'),
              ),
            ),
          if (_options.length < 10)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(AppIcons.plus),
                label: const Text('Antwort'),
                onPressed: () =>
                    setState(() => _options.add(TextEditingController())),
              ),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Mehrere Antworten erlauben'),
            value: _multiple,
            onChanged: (v) => setState(() => _multiple = v),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Abbrechen'),
      ),
      FilledButton(onPressed: _send, child: const Text('Senden')),
    ],
  );
}
