import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
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
  'members',
};

/// The family chat plus one direct chat per other member.
class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
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
  });

  final String chatId;
  final String title;
  final Widget leading;
  final SyncEngine engine;

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
              '${last.text.isNotEmpty ? last.text : '📎 ${last.attachment?.name ?? 'Anhang'}'}';
    return SoftCard(
      padding: const EdgeInsets.all(14),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatScreen(chatId: chatId, title: title),
        ),
      ),
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
                    style: const TextStyle(
                      color: Colors.white,
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
  });

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
    final foreground = mine ? Colors.white : c.ink;
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
  });

  final TextEditingController controller;
  final FocusNode focus;
  final Color color;
  final bool uploading;
  final VoidCallback onSend;
  final VoidCallback onAttach;

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
