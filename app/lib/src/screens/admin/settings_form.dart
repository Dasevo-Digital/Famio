part of '../admin_screens.dart';

class _SettingsForm extends StatefulWidget {
  const _SettingsForm({
    super.key,
    required this.overview,
    required this.onSaved,
  });

  final ServerOverview overview;
  final ValueChanged<ServerOverview> onSaved;

  @override
  State<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<_SettingsForm> {
  late final _publicUrl = TextEditingController(
    text: widget.overview.settings.publicUrl ?? '',
  );
  late final _upload = TextEditingController(
    text: widget.overview.settings.maxUploadMb?.toString() ?? '',
  );
  late final _tiles = TextEditingController(
    text:
        widget.overview.settings.mapTileUrl ??
        widget.overview.effective.mapTileUrl ??
        '',
  );
  late final _locationHistory = TextEditingController(
    text: widget.overview.settings.locationHistoryDays?.toString() ?? '',
  );
  late String _zone = widget.overview.settings.timeZone ?? '';
  late MapTileProvider _mapProvider =
      widget.overview.settings.mapProvider ??
      (widget.overview.effective.mapTileUrl == null
          ? MapTileProvider.openStreetMap
          : MapTileProvider.custom);
  late TwoFactorPolicy? _policy = widget.overview.settings.twoFactorRequired;
  late GermanState? _region = GermanState.parse(
    widget.overview.settings.holidayRegion,
  );
  var _busy = false;
  String? _error;

  static List<String>? _zones;

  static List<String> get zones {
    if (_zones == null) {
      tzdata.initializeTimeZones();
      _zones =
          tz.timeZoneDatabase.locations.keys
              .where((z) => z.contains('/') && !z.startsWith('Etc/'))
              .toList()
            ..sort();
    }
    return _zones!;
  }

  @override
  void dispose() {
    _publicUrl.dispose();
    _upload.dispose();
    _tiles.dispose();
    _locationHistory.dispose();
    super.dispose();
  }

  /// The state's school holidays as a calendar subscription for the whole
  /// family (public source, imported by the server like any ICS feed).
  void _subscribeSchoolHolidays(GermanState state) {
    final engine = AppScope.read(context).engine!;
    final messenger = ScaffoldMessenger.of(context);
    if (engine.calendarSubscriptions.any(
      (s) => s.url == state.schoolHolidaysUrl,
    )) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(tr.adminSchoolHolidaysStateAlready(state.label)),
        ),
      );
      return;
    }
    engine.saveCalendarSubscription(
      CalendarSubscription(
        id: newId(),
        name: tr.adminSchoolHolidaysState(state.label),
        url: state.schoolHolidaysUrl,
        color: 0xFF5B8DEF,
      ),
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(tr.adminSchoolHolidaysStateSubscribed(state.label)),
      ),
    );
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final upload = _upload.text.trim();
    try {
      final fresh = await AppScope.read(context).engine!.api
          .updateServerSettings({
            'publicUrl': _publicUrl.text.trim().isEmpty
                ? null
                : _publicUrl.text.trim(),
            'timeZone': _zone.trim().isEmpty ? null : _zone.trim(),
            'maxUploadMb': upload.isEmpty ? null : int.tryParse(upload) ?? -1,
            'mapProvider': _mapProvider.wire,
            'mapTileUrl': _mapProvider == MapTileProvider.openStreetMap
                ? null
                : _tiles.text.trim().isEmpty
                ? null
                : _tiles.text.trim(),
            'locationHistoryDays': _locationHistory.text.trim().isEmpty
                ? null
                : int.tryParse(_locationHistory.text.trim()) ?? -1,
            'twoFactorRequired': _policy?.name,
            'holidayRegion': _region?.code,
          });
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.adminServerSettingsSaved)));
      widget.onSaved(fresh);
    } on ApiError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Switches areas off for the whole family (e.g. Finanzen); their data
  /// stays on the server and comes back when switched on again.
  Future<void> _editModules() async {
    final hidden = {...?widget.overview.settings.hiddenModules};
    final optional = [
      for (final s in FamioSection.values)
        if (ServerSettings.optionalModules.contains(s.name)) s,
    ];
    final save = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          scrollable: true,
          title: Text(tr.adminAreas),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr.adminWhatFamilyDoesNot,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final s in optional)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(s.icon),
                    title: Text(s.title(context)),
                    value: !hidden.contains(s.name),
                    onChanged: (on) => setDialog(
                      () => on ? hidden.remove(s.name) : hidden.add(s.name),
                    ),
                  ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(AppIcons.arrowsLeftRight),
                  title: Text(tr.adminListConnections),
                  subtitle: Text(tr.adminMembersMaySyncTasks),
                  value: !hidden.contains(ServerSettings.listSyncModule),
                  onChanged: (on) => setDialog(
                    () => on
                        ? hidden.remove(ServerSettings.listSyncModule)
                        : hidden.add(ServerSettings.listSyncModule),
                  ),
                ),
              ],
            ),
          ),
          actions: [
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
      ),
    );
    if (save != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final fresh = await AppScope.read(
        context,
      ).engine!.api.updateServerSettings({'hiddenModules': hidden.toList()});
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(tr.adminAreasSaved)));
      widget.onSaved(fresh);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setCode() async {
    final api = AppScope.read(context).engine!.api;
    final code = TextEditingController();
    final repeat = TextEditingController();
    var saved = false;
    await showDialog<void>(
      context: context,
      builder: (context) => FormDialog(
        title: tr.adminParentsCode,
        controllers: [code, repeat],
        fields: [
          Text(tr.adminCodeParentsCanPause),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: code,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              autofocus: true,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: tr.adminNewCodeLeast4,
              ),
            ),
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: repeat,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: tr.adminRepeatCode,
              ),
            ),
          ),
        ],
        onSubmit: () async {
          if (code.text != repeat.text) {
            throw ApiError(0, 'mismatch', tr.adminCodesDoNotMatch);
          }
          await api.setLocationCode(code.text);
          saved = true;
        },
      ),
    );
    if (!saved || !mounted) return;
    widget.onSaved(await api.adminOverview());
  }

  Future<void> _resetSettings() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr.adminResetSettings),
        content: Text(tr.adminPublicAddressTimeZone),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr.commonReset),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fresh = await AppScope.read(
        context,
      ).engine!.api.resetServerSettings();
      messenger.showSnackBar(
        SnackBar(content: Text(tr.adminSettingsResetDefault)),
      );
      widget.onSaved(fresh);
    } on ApiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _wipe() async {
    final engine = AppScope.read(context).engine!;
    final messenger = ScaffoldMessenger.of(context);
    final password = TextEditingController();
    final confirm = TextEditingController();
    var removeMembers = false;
    ({int records, int files, int members})? result;
    await showDialog<void>(
      context: context,
      builder: (context) {
        final c = FamioColors.of(context);
        return FormDialog(
          title: tr.adminDeleteAllData,
          submitLabel: tr.adminDeletePermanently,
          controllers: [password, confirm],
          fields: [
            Text(
              tr.adminDeletesAllEventsChats,
              style: TextStyle(color: c.inkSoft),
            ),
            StatefulBuilder(
              builder: (context, setState) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(tr.adminAlsoRemoveAllOther),
                subtitle: Text(tr.adminOnlyAccountRemains),
                value: removeMembers,
                onChanged: (v) => setState(() => removeMembers = v ?? false),
              ),
            ),
            PasswordReveal(
              builder: (_, obscure, toggle) => TextField(
                controller: password,
                obscureText: obscure,
                contextMenuBuilder: PasswordReveal.contextMenu,
                decoration: InputDecoration(
                  suffixIcon: toggle,
                  labelText: tr.commonYourPassword,
                  helperText: tr.adminLeaveEmptyIfYou,
                  helperMaxLines: 2,
                ),
              ),
            ),
            TextField(
              controller: confirm,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(labelText: tr.adminTypeDeleteConfirm),
            ),
          ],
          onSubmit: () async {
            if (confirm.text.trim().toUpperCase() != tr.adminWipeWord) {
              throw ApiError(
                0,
                'confirmation_required',
                tr.adminPleaseTypeDeleteConfirm,
              );
            }
            result = await engine.api.wipeServerData(
              password: password.text,
              confirm: 'LÖSCHEN',
              removeMembers: removeMembers,
            );
          },
        );
      },
    );
    final done = result;
    if (done == null) return;
    // Pull the deletions right away; other devices follow on their next sync.
    unawaited(engine.sync());
    if (done.members > 0) unawaited(engine.refreshMembers());
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          tr.adminDeletedRecordsEntriesFiles(
            done.records,
            done.files,
            done.members > 0 ? tr.adminMembersMembers(done.members) : '',
          ),
        ),
      ),
    );
    if (mounted) widget.onSaved(await engine.api.adminOverview());
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.overview;
    final c = FamioColors.of(context);
    final accent = c.strong(FamioSection.settings);
    String hint(String? v) => tr.adminDefaultValue(v ?? '–');
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
          children: [
            Text(
              tr.adminChangesApplyImmediatelyAll,
              style: TextStyle(color: c.inkSoft),
            ),
            ListHeading(tr.adminReachability, color: accent),
            TextField(
              controller: _publicUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: tr.adminPublicAddress,
                hintText: 'https://famio.example.org',
                helperText: tr.adminHintCalendarSubscriptionsGoogle(
                  hint(o.defaults.publicUrl),
                ),
                helperMaxLines: 3,
                prefixIcon: const Icon(AppIcons.globe),
              ),
            ),
            ListHeading(tr.settingsFamily, color: accent),
            Autocomplete<String>(
              initialValue: TextEditingValue(text: _zone),
              optionsBuilder: (value) {
                final q = value.text.toLowerCase();
                if (q.isEmpty) return const [];
                return zones.where((z) => z.toLowerCase().contains(q)).take(20);
              },
              onSelected: (z) => _zone = z,
              fieldViewBuilder: (context, controller, focus, onSubmit) =>
                  TextField(
                    controller: controller,
                    focusNode: focus,
                    onChanged: (v) => _zone = v,
                    decoration: InputDecoration(
                      labelText: tr.adminTimeZone,
                      hintText: 'Europe/Berlin',
                      helperText: tr.adminHintCalendarFeedsImported(
                        hint(o.defaults.timeZone),
                      ),
                      helperMaxLines: 2,
                      prefixIcon: const Icon(AppIcons.clock),
                    ),
                  ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<GermanState?>(
              initialValue: _region,
              decoration: InputDecoration(
                labelText: tr.adminFederalState,
                helperText: tr.adminPublicHolidaysCalendar,
                prefixIcon: Icon(AppIcons.calendarBlank),
              ),
              items: [
                DropdownMenuItem(
                  value: null,
                  child: Text(tr.adminNoPublicHolidays),
                ),
                for (final s in GermanState.values)
                  DropdownMenuItem(value: s, child: Text(s.label)),
              ],
              onChanged: (v) => setState(() => _region = v),
            ),
            if (_region != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(AppIcons.cloudArrowDown, size: 18),
                  label: Text(
                    tr.adminSubscribeSchoolHolidaysRegion(_region!.label),
                  ),
                  onPressed: () => _subscribeSchoolHolidays(_region!),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _upload,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: tr.adminMaximumFileSizeMb,
                helperText: tr.adminHintNpmAlsoAdjust(
                  hint('${o.defaults.maxUploadMb ?? 100} MB'),
                ),
                helperMaxLines: 2,
                prefixIcon: const Icon(AppIcons.upload),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              tr.adminMapProvider,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final provider in MapTileProvider.values)
                  ChoiceChip(
                    label: Text(switch (provider) {
                      MapTileProvider.openStreetMap => 'OpenStreetMap',
                      MapTileProvider.martin => tr.adminOwnMartinServer,
                      MapTileProvider.custom => tr.adminOwnXyzAddress,
                    }),
                    selected: _mapProvider == provider,
                    onSelected: (_) => setState(() => _mapProvider = provider),
                  ),
              ],
            ),
            if (_mapProvider == MapTileProvider.openStreetMap)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(tr.adminReadyUsePublicService),
              )
            else ...[
              const SizedBox(height: 12),
              TextField(
                controller: _tiles,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _mapProvider == MapTileProvider.martin
                      ? tr.adminMartinTileAddress
                      : tr.adminXyzTileAddress,
                  hintText:
                      'https://karten.example.org/tiles/basemap/{z}/{x}/{y}',
                  helperText: _mapProvider == MapTileProvider.martin
                      ? tr.adminMartinServesOwnPmtiles
                      : tr.adminHttpsAddressWith('{z}, {x}, {y}'),
                  helperMaxLines: 3,
                  prefixIcon: const Icon(AppIcons.map),
                ),
              ),
            ],
            const SizedBox(height: 16),
            TextField(
              controller: _locationHistory,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Standortverlauf (Tage)',
                hintText: '7',
                helperText: tr.adminHintOldPrecisePoints(
                  hint(tr.commonDaysCount(o.defaults.locationHistoryDays ?? 7)),
                ),
                helperMaxLines: 3,
                prefixIcon: const Icon(AppIcons.mapPin),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<TwoFactorPolicy?>(
              initialValue: _policy,
              decoration: InputDecoration(
                labelText: tr.adminRequireTwoFactorSign,
                helperText: tr.adminThoseAffectedSetUp,
                helperMaxLines: 3,
                prefixIcon: Icon(AppIcons.shieldCheck),
              ),
              items: [
                DropdownMenuItem(value: null, child: Text(tr.adminNotRequired)),
                for (final p in TwoFactorPolicy.values)
                  DropdownMenuItem(value: p, child: Text(tr.adminWho(p.label))),
              ],
              onChanged: (p) => setState(() => _policy = p),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: c.danger)),
            ],
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: ColorButton(
                label: tr.commonSave,
                icon: AppIcons.check,
                color: accent,
                onPressed: _busy ? null : _save,
              ),
            ),
            ListHeading(tr.adminSign, color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.logIn),
              title: const Text('Single Sign-On (OpenID Connect)'),
              subtitle: Text(tr.adminSignAuthentikKeycloakAuthelia),
              trailing: TextButton(
                onPressed: _busy ? null : () => showSsoDialog(context),
                child: Text(tr.commonSetUp),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.folderSimpleStar),
              title: Text(tr.adminPaperBuddy),
              subtitle: Text(tr.adminPaperBuddySubtitle),
              trailing: TextButton(
                onPressed: _busy ? null : () => showPaperBuddyDialog(context),
                child: Text(tr.commonSetUp),
              ),
            ),
            ListHeading(tr.adminAreas, color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.dotsThreeCircle),
              title: Text(tr.adminShowHideAreas),
              subtitle: Text(
                (o.settings.hiddenModules ?? const []).isEmpty
                    ? tr.adminAllAreasVisible
                    : tr.adminHiddenAreas(
                        [
                          for (final s in FamioSection.values)
                            if (o.settings.hiddenModules!.contains(s.name))
                              s.title(context),
                          if (o.settings.hiddenModules!.contains(
                            ServerSettings.listSyncModule,
                          ))
                            tr.adminListConnections,
                        ].join(', '),
                      ),
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _editModules,
                child: Text(tr.commonChange),
              ),
            ),
            ListHeading(tr.sectionLocation, color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.lockKey),
              title: Text(tr.adminParentsCode),
              subtitle: Text(
                o.locationCodeSet
                    ? tr.adminSetNeededPauseEnd
                    : tr.adminNotSetYetWithout,
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _setCode,
                child: Text(o.locationCodeSet ? tr.commonChange : tr.adminSet),
              ),
            ),
            ListHeading(tr.adminOnlyChangeableServer, color: accent),
            _InfoRow(
              icon: AppIcons.shield,
              label: tr.adminTrustReverseProxy,
              value: o.trustProxy ? tr.commonOn : tr.commonOff,
              note: tr.adminFamioTrustProxyNot,
            ),
            _InfoRow(
              icon: AppIcons.house,
              label: tr.adminHomeAssistantSign,
              value: o.ingressAuth ? tr.commonOn : tr.commonOff,
              note: tr.adminAddOptionIngressAuth,
            ),
            ListHeading(tr.commonExport, color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.cloudArrowDown),
              title: Text(tr.adminExportFamily),
              subtitle: Text(tr.adminAllDataFilesZip),
              trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () => exportData(context, family: true),
                child: Text(tr.adminExport),
              ),
            ),
            ListHeading(tr.commonReset, color: c.danger),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.arrowsClockwise),
              title: Text(tr.adminSettingsDefault),
              subtitle: Text(tr.adminTakeAddressTimeZone),
              trailing: TextButton(
                onPressed: _busy ? null : _resetSettings,
                child: Text(tr.commonReset),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(AppIcons.trash, color: c.danger),
              title: Text(
                tr.adminDeleteAllData2,
                style: TextStyle(color: c.danger),
              ),
              subtitle: Text(tr.adminDeleteEventsChatLists),
              trailing: TextButton(
                style: TextButton.styleFrom(foregroundColor: c.danger),
                onPressed: _busy ? null : _wipe,
                child: Text(tr.commonDeleteEllipsis),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- status -----------------------------------------------------------------
