import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';

class MemberAvatar extends StatelessWidget {
  const MemberAvatar(this.member, {super.key, this.radius = 14});

  final FamilyMember member;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final color = Color(member.color ?? 0xFF607D8B);
    final initial = member.displayName.isEmpty
        ? '?'
        : member.displayName.characters.first.toUpperCase();
    return Tooltip(
      message: member.displayName,
      child: CircleAvatar(
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
      ),
    );
  }
}
