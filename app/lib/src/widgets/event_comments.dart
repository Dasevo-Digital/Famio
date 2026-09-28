import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../format.dart';
import 'data_builder.dart';
import 'member_avatar.dart';

/// "Wer bringt den Kuchen mit?" – comments under an event.
class EventComments extends StatefulWidget {
  const EventComments({super.key, required this.eventId});

  final String eventId;

  @override
  State<EventComments> createState() => _EventCommentsState();
}

class _EventCommentsState extends State<EventComments> {
  final _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    AppScope.engineOf(context).addEventComment(widget.eventId, text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    return DataBuilder(
      collections: const {Collections.eventComments, 'members'},
      builder: (context, engine) {
        final comments = engine.eventComments(widget.eventId);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListHeading(
              comments.isEmpty
                  ? 'Kommentare'
                  : 'Kommentare (${comments.length})',
            ),
            for (final comment in comments)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GestureDetector(
                  onLongPress: comment.authorId == engine.memberId
                      ? () => engine.deleteEventComment(comment.id)
                      : null,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (engine.member(comment.authorId) case final m?)
                        MemberAvatar(m, radius: 14)
                      else
                        const SizedBox(width: 28),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          decoration: BoxDecoration(
                            color: c.surfaceSoft,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${engine.member(comment.authorId)?.displayName ?? '?'}'
                                ' · ${dateTimeLabel(comment.at)}',
                                style: theme.textTheme.labelSmall,
                              ),
                              Text(comment.text),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Kommentar, z. B. „Ich bringe Kuchen mit“',
                      prefixIcon: Icon(AppIcons.comment),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 8),
                BubbleButton(
                  icon: AppIcons.paperPlaneRight,
                  tooltip: 'Senden',
                  color: Colors.white,
                  background: c.strong(FamioSection.calendar),
                  onPressed: _send,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
