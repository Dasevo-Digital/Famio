import 'dart:math' as math;

import 'package:famio_client/famio_client.dart';
import 'package:flutter/material.dart';
import '../design/app_icons.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../design/components.dart';
import '../widgets/trust_certificate.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../data/family_extras.dart';
import 'calendar_screen.dart';
import 'chores_screens.dart';
import 'medication_screens.dart';
import 'chat_screens.dart';
import 'budget_screens.dart';
import 'contacts_screens.dart';
import 'documents_screen.dart';
import 'home_screen.dart';
import 'kids_screens.dart';
import 'kiosk_screen.dart';
import 'location_screens.dart';
import 'meals_screens.dart';
import 'settings_screen.dart';
import 'sos_screens.dart';
import '../sos/sos_device.dart';
import 'shopping_screens.dart';
import 'tasks_screen.dart';
import '../environment.dart';
import '../widgets/whats_new.dart';

Widget _pageFor(FamioSection section) => switch (section) {
  FamioSection.home => const HomeScreen(),
  FamioSection.tasks => const TasksScreen(),
  FamioSection.shopping => const ShoppingListsScreen(),
  FamioSection.calendar => const CalendarScreen(),
  FamioSection.chat => const ChatListScreen(),
  FamioSection.documents => const DocumentsScreen(),
  FamioSection.kids => const KidsScreen(),
  FamioSection.location => const LocationScreen(),
  FamioSection.chores => const ChoresScreen(),
  FamioSection.meals => const MealsScreen(),
  FamioSection.budget => const BudgetScreen(),
  FamioSection.health => const MedicationScreen(),
  FamioSection.contacts => const ContactsScreen(),
  FamioSection.settings => const SettingsScreen(),
};

/// Sections in the phone bar; the rest sits behind "Mehr".
const _barSections = [
  FamioSection.home,
  FamioSection.tasks,
  FamioSection.shopping,
  FamioSection.calendar,
  FamioSection.chat,
];

/// Guests (grandparents, babysitters) see no documents, health data,
/// finances or locations – the server does not send them anyway.
const _guestHidden = {
  FamioSection.documents,
  FamioSection.kids,
  FamioSection.location,
  FamioSection.budget,
  FamioSection.health,
};

/// The sections [role] sees, without those the family switched off
/// ([hidden], by name; see `ServerSettings.hiddenModules`).
List<FamioSection> sectionsFor(
  MemberRole role, {
  Set<String> hidden = const {},
}) => [
  for (final s in FamioSection.values)
    if ((role != MemberRole.guest || !_guestHidden.contains(s)) &&
        !hidden.contains(s.name))
      s,
];

/// Lets any page switch sections, e.g. the dashboard tiles.
class FamioNav extends InheritedWidget {
  const FamioNav({
    super.key,
    required this.go,
    required this.current,
    required super.child,
  });

  final ValueChanged<FamioSection> go;
  final FamioSection current;

  static FamioNav of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FamioNav>()!;

  @override
  bool updateShouldNotify(FamioNav old) => old.current != current;
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  var _section = FamioSection.home;

  /// Sections for the member's role, updated with the member list.
  var _sections = FamioSection.values;

  /// The phone bar: its usual sections that are switched on.
  List<FamioSection> get _bar => [
    for (final s in _barSections)
      if (_sections.contains(s)) s,
  ];

  /// Sections are built on their first visit only, so e.g. the map does not
  /// load tiles at every app start.
  final _visited = {FamioSection.home};

  // One navigator per section keeps each section's page stack.
  final _navigators = {
    for (final s in FamioSection.values) s: GlobalKey<NavigatorState>(),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SosDevice.onLaunch = _sosLaunch;
    // Kitchen tablet: straight to the wall display.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AppScope.read(context).kioskAutostart) {
        openKiosk(context);
      } else {
        // After an update, once: what is new.
        maybeShowWhatsNew(context);
      }
      _checkSosLaunch();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (SosDevice.onLaunch == _sosLaunch) SosDevice.onLaunch = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkSosLaunch();
  }

  /// Opened from the "Famio Notruf" tile or the app shortcut (Android).
  Future<void> _checkSosLaunch() async {
    if (await SosDevice.takeLaunch()) _sosLaunch();
  }

  void _sosLaunch() {
    if (mounted) startSosCountdown(context);
  }

  void _go(FamioSection section) {
    if (section == _section) {
      // Tapping the current section again returns to its start page.
      _navigators[section]!.currentState?.popUntil((r) => r.isFirst);
    }
    setState(() {
      _section = section;
      _visited.add(section);
    });
  }

  Future<void> _showMore() async {
    final picked = await showModalBottomSheet<FamioSection>(
      context: context,
      // Above the floating navigation bar.
      useRootNavigator: true,
      isScrollControlled: true,
      // Below the status bar, so the handle stays reachable.
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // Three per row: all sections fit on small phones.
            const gap = 10.0;
            final width = (constraints.maxWidth - 32 - gap * 2) / 3;
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final s in _sections.where((s) => !_bar.contains(s)))
                    SizedBox(
                      width: width,
                      child: _MoreTile(
                        section: s,
                        onTap: () => Navigator.pop(context, s),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
    if (picked != null) _go(picked);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final pages = IndexedStack(
      index: FamioSection.values.indexOf(_section),
      children: [
        for (final s in FamioSection.values)
          if (_visited.contains(s))
            HeroControllerScope.none(
              child: Navigator(
                key: _navigators[s],
                onGenerateRoute: (_) =>
                    MaterialPageRoute<void>(builder: (_) => _pageFor(s)),
              ),
            )
          else
            const SizedBox.shrink(),
      ],
    );
    final c = FamioColors.of(context);
    final changed = AppScope.of(context).changedCertificate;
    final body = Column(
      children: [
        if (changed != null) _CertificateBanner(fingerprint: changed),
        const SosBanner(),
        Expanded(child: pages),
      ],
    );

    return FamioNav(
      go: _go,
      current: _section,
      child: DataBuilder(
        collections: const {
          Collections.chatMessages,
          Collections.chatReads,
          'members',
        },
        builder: (context, engine) {
          final unread = engine.totalUnread;
          _sections = sectionsFor(
            engine.myRole,
            hidden: AppScope.of(context).hiddenModules,
          );
          if (!_sections.contains(_section)) {
            // Switched off while open: back to the start page.
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => mounted ? _go(FamioSection.home) : null,
            );
          }
          if (wide) {
            return Scaffold(
              backgroundColor: c.background,
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SideRail(
                    sections: _sections,
                    current: _section,
                    onSelect: _go,
                    unread: unread,
                  ),
                  Expanded(child: body),
                ],
              ),
            );
          }
          return Scaffold(
            backgroundColor: c.background,
            extendBody: true,
            body: body,
            bottomNavigationBar: _FloatingBar(
              bar: _bar,
              current: _section,
              onSelect: _go,
              onMore: _showMore,
              unread: unread,
            ),
          );
        },
      ),
    );
  }
}

class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.sections,
    required this.current,
    required this.onSelect,
    required this.unread,
  });

  final List<FamioSection> sections;
  final FamioSection current;
  final ValueChanged<FamioSection> onSelect;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Container(
      width: 108,
      margin: const EdgeInsets.fromLTRB(12, 12, 0, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(32),
        boxShadow: c.softShadow,
      ),
      child: SafeArea(
        right: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The desktop rail deliberately has no scroll area. Its logo and
            // items divide all available vertical space, so it remains calm
            // and balanced on a 13" laptop as well as a tall desktop window.
            const outerPadding = 12.0;
            final usableHeight = math.max(
              0.0,
              constraints.maxHeight - outerPadding * 2,
            );
            final logoExtent = (usableHeight * 0.11)
                .clamp(52.0, 88.0)
                .toDouble();
            final itemExtent = sections.isEmpty
                ? 0.0
                : math.max(0.0, (usableHeight - logoExtent) / sections.length);
            // Below this there is not enough room for a useful text label.
            // Tooltips keep every destination discoverable in icon mode.
            final showLabel = itemExtent >= 45;
            final iconSize = (itemExtent * (showLabel ? 0.42 : 0.64))
                .clamp(18.0, 36.0)
                .toDouble();
            final labelSize = (itemExtent * 0.18).clamp(9.0, 13.0).toDouble();
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: outerPadding),
              child: Column(
                children: [
                  SizedBox(
                    height: logoExtent,
                    child: _Logo(
                      size: (logoExtent * 0.62).clamp(32.0, 52.0).toDouble(),
                    ),
                  ),
                  for (final s in sections)
                    Expanded(
                      child: _RailItem(
                        section: s,
                        selected: s == current,
                        showLabel: showLabel,
                        iconSize: iconSize,
                        labelSize: labelSize,
                        badge: s == FamioSection.chat ? unread : 0,
                        onTap: () => onSelect(s),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  const _Logo({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    final showName = size >= 42;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedContainer(
          duration: _railAnimationDuration(context),
          curve: Curves.easeOutCubic,
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFFFFB38A), Color(0xFFF26B8F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(size * 0.34),
          ),
          child: Image.asset(
            'assets/icon/logo_glyph.png',
            width: size * 0.72,
            height: size * 0.72,
          ),
        ),
        if (showName) ...[
          const SizedBox(height: 4),
          Text(
            AppEnv.appName,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontSize: (size * 0.36).clamp(14.0, 18.0).toDouble(),
            ),
          ),
        ],
      ],
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    required this.section,
    required this.selected,
    required this.onTap,
    required this.iconSize,
    required this.labelSize,
    this.badge = 0,
    this.showLabel = true,
  });

  final FamioSection section;
  final bool showLabel;
  final bool selected;
  final VoidCallback onTap;
  final int badge;
  final double iconSize;
  final double labelSize;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(section);
    final item = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: AnimatedContainer(
        duration: _railAnimationDuration(context),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected ? c.tint(section) : Colors.transparent,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: onTap,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Badge(
                    count: badge,
                    child: AnimatedScale(
                      duration: _railAnimationDuration(context),
                      curve: Curves.easeOutCubic,
                      scale: selected ? 1.07 : 1,
                      child: Icon(
                        section.icon,
                        color: selected ? color : c.inkSoft,
                        size: iconSize,
                      ),
                    ),
                  ),
                  if (showLabel) ...[
                    SizedBox(
                      height: (iconSize * 0.12).clamp(2.0, 5.0).toDouble(),
                    ),
                    AnimatedDefaultTextStyle(
                      duration: _railAnimationDuration(context),
                      curve: Curves.easeOutCubic,
                      maxLines: 1,
                      overflow: TextOverflow.fade,
                      softWrap: false,
                      style: Theme.of(context).textTheme.labelSmall!.copyWith(
                        color: selected ? c.ink : c.inkSoft,
                        fontSize: labelSize,
                        fontWeight: selected
                            ? FontWeight.w800
                            : FontWeight.w700,
                      ),
                      child: Text(section.label),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return showLabel
        ? item
        : Tooltip(
            message: section.label,
            child: Semantics(label: section.label, child: item),
          );
  }
}

Duration _railAnimationDuration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 180);

class _FloatingBar extends StatelessWidget {
  const _FloatingBar({
    required this.bar,
    required this.current,
    required this.onSelect,
    required this.onMore,
    required this.unread,
  });

  /// The sections in the bar itself.
  final List<FamioSection> bar;
  final FamioSection current;
  final ValueChanged<FamioSection> onSelect;
  final VoidCallback onMore;
  final int unread;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final inMore = !bar.contains(current);
    return SafeArea(
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(34),
          boxShadow: [
            BoxShadow(
              color: c.shadow,
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          children: [
            for (final s in bar)
              Expanded(
                child: _BarItem(
                  icon: s.icon,
                  label: s.label,
                  color: c.strong(s),
                  tint: c.tint(s),
                  selected: s == current,
                  badge: s == FamioSection.chat ? unread : 0,
                  onTap: () => onSelect(s),
                ),
              ),
            Expanded(
              child: _BarItem(
                icon: AppIcons.dotsThreeCircle,
                label: inMore ? current.label : 'Mehr',
                color: inMore ? c.strong(current) : c.inkSoft,
                tint: inMore ? c.tint(current) : c.surfaceSoft,
                selected: inMore,
                onTap: onMore,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BarItem extends StatelessWidget {
  const _BarItem({
    required this.icon,
    required this.label,
    required this.color,
    required this.tint,
    required this.selected,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String label;
  final Color color;
  final Color tint;
  final bool selected;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Tooltip(
      message: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          height: 56,
          decoration: BoxDecoration(
            color: selected ? tint : Colors.transparent,
            borderRadius: BorderRadius.circular(28),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Badge(
                count: badge,
                child: Icon(
                  icon,
                  color: selected ? color : c.inkSoft,
                  size: 26,
                ),
              ),
              if (selected)
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.fade,
                  softWrap: false,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: c.ink,
                    fontSize: 10.5,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreTile extends StatelessWidget {
  const _MoreTile({required this.section, required this.onTap});

  final FamioSection section;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return Material(
      color: c.tint(section),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Column(
            children: [
              Icon(section.icon, color: c.strong(section), size: 28),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  section.label,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.child});

  final int count;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (count == 0) return child;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          right: -8,
          top: -4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            constraints: const BoxConstraints(minWidth: 18),
            decoration: BoxDecoration(
              color: FamioColors.of(context).strong(FamioSection.kids),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: FamioColors.of(context).surface,
                width: 2,
              ),
            ),
            child: Text(
              count > 99 ? '99+' : '$count',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: FamioColors.of(context).onStrong,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The server shows a key other than the confirmed one: offline until the
/// user compares the new fingerprint.
class _CertificateBanner extends StatelessWidget {
  const _CertificateBanner({required this.fingerprint});

  final String fingerprint;

  Future<void> _check(BuildContext context) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    if (!await confirmCertificate(context, fingerprint)) return;
    try {
      await state.acceptChangedCertificate();
      messenger.showSnackBar(
        const SnackBar(content: Text('Verbindung wiederhergestellt')),
      );
    } on ApiError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: SoftCard(
          color: c.tint(FamioSection.home),
          child: Row(
            children: [
              Icon(AppIcons.shield, color: c.strong(FamioSection.home)),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Das Zertifikat des Servers hat sich geändert. Bis zur '
                  'Prüfung bleibt Famio offline.',
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => _check(context),
                child: const Text('Prüfen'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
