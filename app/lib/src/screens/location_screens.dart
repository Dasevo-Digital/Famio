import 'dart:async';
import 'dart:math' as math;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../location/location_sharing.dart';
import '../widgets/data_builder.dart';
import '../widgets/form_dialog.dart';
import '../widgets/member_avatar.dart';
import '../widgets/password_reveal.dart';

part 'location/family_map.dart';
part 'location/history.dart';
part 'location/labels.dart';
part 'location/member_list.dart';
part 'location/minute_ticker.dart';
part 'location/my_sharing_card.dart';
part 'location/places.dart';
part 'location/schedule_dialog.dart';

const _collections = {
  Collections.places,
  Collections.memberLocations,
  'members',
};

/// Center of Germany, for an empty map.
const _fallbackCenter = LatLng(51.16, 10.45);

/// A position older than this is shown as outdated.
const _stale = Duration(minutes: 30);

/// Who is where: family map, places and the own sharing switch.
class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  /// The member the map follows; null follows everybody.
  String? _focused;

  void _focus(MemberLocation l) {
    if (!l.hasPosition) return;
    setState(() => _focused = l.memberId);
  }

  @override
  Widget build(BuildContext context) {
    return SectionPage(
      section: FamioSection.location,
      title: 'Wo ist wer?',
      subtitle: 'Standort der Familie',
      actions: [
        BubbleButton(
          icon: AppIcons.mapPin,
          tooltip: 'Orte',
          onPressed: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PlacesScreen())),
        ),
      ],
      bodyPadding: EdgeInsets.zero,
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final locations = engine.memberLocations;
          final map = MinuteTicker(
            builder: (_) => ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: FamilyMap(
                engine: engine,
                locations: locations,
                focus: _focused,
                onShowAll: () => setState(() => _focused = null),
              ),
            ),
          );
          Widget memberList({bool scrollable = true}) => MinuteTicker(
            builder: (_) => _MemberList(
              engine: engine,
              locations: locations,
              onFocus: _focus,
              scrollable: scrollable,
            ),
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 900) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 380, child: memberList()),
                      const SizedBox(width: 16),
                      Expanded(child: map),
                    ],
                  ),
                );
              }
              // On phones map and members share one scroll view. Previously
              // only the member list scrolled, leaving the map permanently
              // fixed in the upper half of the screen.
              final mapHeight = (constraints.maxHeight * 0.55)
                  .clamp(260.0, 420.0)
                  .toDouble();
              return CustomScrollView(
                key: const PageStorageKey('location-mobile-scroll'),
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(height: mapHeight, child: map),
                    ),
                  ),
                  SliverToBoxAdapter(child: memberList(scrollable: false)),
                ],
              );
            },
          );
        },
      ),
    );
  }
}
