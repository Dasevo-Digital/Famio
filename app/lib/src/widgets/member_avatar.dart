import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

class MemberAvatar extends StatelessWidget {
  const MemberAvatar(
    this.member, {
    super.key,
    this.radius = 14,
    this.onTap,
    this.tooltip,
  });

  final FamilyMember member;
  final double radius;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final color = Color(member.color ?? 0xFF607D8B);
    final initial = member.displayName.isEmpty
        ? '?'
        : member.displayName.characters.first.toUpperCase();
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.9,
          fontFamily: 'Fredoka',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    final child = onTap == null
        ? avatar
        : Semantics(
            button: true,
            label: tooltip ?? member.displayName,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              // A 22 px avatar becomes a 48 px tap target in the header.
              child: Padding(padding: const EdgeInsets.all(2), child: avatar),
            ),
          );
    return Tooltip(message: tooltip ?? member.displayName, child: child);
  }
}
