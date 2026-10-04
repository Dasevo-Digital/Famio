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
          });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Servereinstellungen gespeichert')),
      );
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
          title: const Text('Bereiche'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Was die Familie nicht nutzt, verschwindet aus Menü und '
                  'Startseite – in allen Apps. Die Daten bleiben erhalten.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final s in optional)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: Icon(s.icon),
                    title: Text(s.label),
                    value: !hidden.contains(s.name),
                    onChanged: (on) => setDialog(
                      () => on ? hidden.remove(s.name) : hidden.add(s.name),
                    ),
                  ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(AppIcons.arrowsLeftRight),
                  title: const Text('Listen-Anbindungen'),
                  subtitle: const Text(
                    'Mitglieder dürfen Aufgaben und Einkaufslisten mit '
                    'Bring! und Microsoft To Do abgleichen.',
                  ),
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
              child: const Text('Abbrechen'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Speichern'),
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
      ).showSnackBar(const SnackBar(content: Text('Bereiche gespeichert')));
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
        title: 'Eltern-Code',
        controllers: [code, repeat],
        fields: [
          const Text(
            'Mit diesem Code können Eltern die Standortfreigabe eines '
            'Familienmitglieds pausieren oder auf einem Handy beenden. '
            'Kindern nicht verraten.',
          ),
          PasswordReveal(
            builder: (_, obscure, toggle) => TextField(
              controller: code,
              obscureText: obscure,
              contextMenuBuilder: PasswordReveal.contextMenu,
              autofocus: true,
              decoration: InputDecoration(
                suffixIcon: toggle,
                labelText: 'Neuer Code (mind. 4 Zeichen)',
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
                labelText: 'Code wiederholen',
              ),
            ),
          ),
        ],
        onSubmit: () async {
          if (code.text != repeat.text) {
            throw const ApiError(
              0,
              'mismatch',
              'Die Codes stimmen nicht überein',
            );
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
        title: const Text('Einstellungen zurücksetzen?'),
        content: const Text(
          'Öffentliche Adresse, Zeitzone, maximale Dateigröße und '
          'Kartenserver gelten wieder so, wie sie in der Server-Konfiguration '
          '(Umgebungsvariablen bzw. Add-on-Optionen) stehen. Daten, '
          'Mitglieder und der Eltern-Code bleiben unverändert.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Zurücksetzen'),
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
        const SnackBar(content: Text('Einstellungen auf Standard gesetzt')),
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
          title: 'Alle Daten löschen?',
          submitLabel: 'Endgültig löschen',
          controllers: [password, confirm],
          fields: [
            Text(
              'Gelöscht werden alle Termine, Chats, Listen, Aufgaben, Ämter, '
              'Dokumente, Fotos, Kinder- und Gesundheitsdaten, Standorte, '
              'verbundene Kalender und Kalender-Links – auf dem Server und '
              'beim nächsten Abgleich auf allen Geräten. Das lässt sich nicht '
              'rückgängig machen; vorher eine Sicherung des Datenordners '
              'anlegen.\n\nErhalten bleiben die Konten, Server-Einstellungen '
              'und das HTTPS-Zertifikat.',
              style: TextStyle(color: c.inkSoft),
            ),
            StatefulBuilder(
              builder: (context, setState) => CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auch alle anderen Mitglieder entfernen'),
                subtitle: const Text('Nur dein Konto bleibt bestehen'),
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
                  labelText: 'Dein Passwort',
                  helperText:
                      'Leer lassen, wenn du dich nur über Home Assistant '
                      'anmeldest.',
                  helperMaxLines: 2,
                ),
              ),
            ),
            TextField(
              controller: confirm,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Zur Bestätigung LÖSCHEN eingeben',
              ),
            ),
          ],
          onSubmit: () async {
            if (confirm.text.trim().toUpperCase() != 'LÖSCHEN') {
              throw const ApiError(
                0,
                'confirmation_required',
                'Bitte zur Bestätigung LÖSCHEN eingeben',
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
          'Gelöscht: ${done.records} Einträge, ${done.files} Dateien'
          '${done.members > 0 ? ', ${done.members} Mitglieder' : ''}',
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
    String hint(String? v) => 'Standard: ${v ?? '–'}';
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: EdgeInsets.only(top: 8, bottom: listBottomPadding(context)),
          children: [
            Text(
              'Änderungen gelten sofort für alle Geräte. Leere Felder nutzen den '
              'Standard aus der Server-Konfiguration (Umgebungsvariablen bzw. '
              'Add-on-Optionen).',
              style: TextStyle(color: c.inkSoft),
            ),
            ListHeading('Erreichbarkeit', color: accent),
            TextField(
              controller: _publicUrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Öffentliche Adresse',
                hintText: 'https://famio.example.org',
                helperText:
                    '${hint(o.defaults.publicUrl)}. Für Kalender-Abos (Google, '
                    'iCloud) über den Reverse-Proxy.',
                helperMaxLines: 3,
                prefixIcon: const Icon(AppIcons.globe),
              ),
            ),
            ListHeading('Familie', color: accent),
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
                      labelText: 'Zeitzone',
                      hintText: 'Europe/Berlin',
                      helperText:
                          '${hint(o.defaults.timeZone)}. Für Kalender-Feeds und '
                          'importierte Termine.',
                      helperMaxLines: 2,
                      prefixIcon: const Icon(AppIcons.clock),
                    ),
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _upload,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Maximale Dateigröße (MB)',
                helperText:
                    '${hint('${o.defaults.maxUploadMb ?? 100} MB')}. Bei NPM auch '
                    'client_max_body_size anpassen.',
                helperMaxLines: 2,
                prefixIcon: const Icon(AppIcons.upload),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Kartenanbieter',
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
                      MapTileProvider.martin => 'Eigener Martin-Server',
                      MapTileProvider.custom => 'Eigene XYZ-Adresse',
                    }),
                    selected: _mapProvider == provider,
                    onSelected: (_) => setState(() => _mapProvider = provider),
                  ),
              ],
            ),
            if (_mapProvider == MapTileProvider.openStreetMap)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Sofort nutzbar. Der öffentliche Dienst sieht den geladenen Kartenausschnitt.',
                ),
              )
            else ...[
              const SizedBox(height: 12),
              TextField(
                controller: _tiles,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: _mapProvider == MapTileProvider.martin
                      ? 'Martin-Kacheladresse'
                      : 'XYZ-Kacheladresse',
                  hintText:
                      'https://karten.example.org/tiles/basemap/{z}/{x}/{y}',
                  helperText: _mapProvider == MapTileProvider.martin
                      ? 'Martin stellt eigene PMTiles/MBTiles bereit. Docker: docker compose --profile maps up -d; danach die HTTPS-Adresse hier eintragen.'
                      : 'HTTPS-Adresse mit {z}, {x} und {y}.',
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
                helperText:
                    '${hint('${o.defaults.locationHistoryDays ?? 7} Tage')}. '
                    'Alte, präzise Punkte und Ortsmeldungen werden automatisch '
                    'gelöscht; der aktuelle Standort bleibt sichtbar.',
                helperMaxLines: 3,
                prefixIcon: const Icon(AppIcons.mapPin),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<TwoFactorPolicy?>(
              initialValue: _policy,
              decoration: const InputDecoration(
                labelText: 'Zwei-Faktor-Anmeldung verlangen',
                helperText:
                    'Betroffene richten beim nächsten Öffnen der App eine '
                    'Authenticator-App ein; Single Sign-On zählt auch. Für '
                    'Home Assistant ein eigenes Mitglied ohne Pflicht nutzen.',
                helperMaxLines: 3,
                prefixIcon: Icon(AppIcons.shieldCheck),
              ),
              items: [
                const DropdownMenuItem(
                  value: null,
                  child: Text('Nicht verlangt'),
                ),
                for (final p in TwoFactorPolicy.values)
                  DropdownMenuItem(value: p, child: Text('Für ${p.label}')),
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
                label: 'Speichern',
                icon: AppIcons.check,
                color: accent,
                onPressed: _busy ? null : _save,
              ),
            ),
            ListHeading('Anmeldung', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.logIn),
              title: const Text('Single Sign-On (OpenID Connect)'),
              subtitle: const Text(
                'Anmelden mit Authentik, Keycloak, Authelia, Google, Microsoft …',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : () => showSsoDialog(context),
                child: const Text('Einrichten'),
              ),
            ),
            ListHeading('Bereiche', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.dotsThreeCircle),
              title: const Text('Bereiche ein- und ausblenden'),
              subtitle: Text(
                (o.settings.hiddenModules ?? const []).isEmpty
                    ? 'Alle Bereiche sind sichtbar'
                    : 'Ausgeblendet: ${[for (final s in FamioSection.values)
                        if (o.settings.hiddenModules!.contains(s.name)) s.label, if (o.settings.hiddenModules!.contains(ServerSettings.listSyncModule)) 'Listen-Anbindungen'].join(', ')}',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _editModules,
                child: const Text('Ändern'),
              ),
            ),
            ListHeading('Standort', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.lockKey),
              title: const Text('Eltern-Code'),
              subtitle: Text(
                o.locationCodeSet
                    ? 'Festgelegt. Nötig, um eine Standortfreigabe zu '
                          'pausieren oder zu beenden.'
                    : 'Noch nicht festgelegt – ohne Code kann niemand die '
                          'Standortfreigabe pausieren.',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _setCode,
                child: Text(o.locationCodeSet ? 'Ändern' : 'Festlegen'),
              ),
            ),
            ListHeading('Nur auf dem Server änderbar', color: accent),
            _InfoRow(
              icon: AppIcons.shield,
              label: 'Reverse-Proxy vertrauen',
              value: o.trustProxy ? 'an' : 'aus',
              note: 'FAMIO_TRUST_PROXY – aus Sicherheitsgründen nicht per App',
            ),
            _InfoRow(
              icon: AppIcons.house,
              label: 'Home-Assistant-Anmeldung',
              value: o.ingressAuth ? 'an' : 'aus',
              note: 'Add-on-Option ingress_auth',
            ),
            ListHeading('Export', color: accent),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.cloudArrowDown),
              title: const Text('Familie exportieren'),
              subtitle: const Text(
                'Alle Daten und Dateien als ZIP, z. B. für einen Umzug',
              ),
              trailing: TextButton(
                onPressed: _busy
                    ? null
                    : () => exportData(context, family: true),
                child: const Text('Exportieren'),
              ),
            ),
            ListHeading('Zurücksetzen', color: c.danger),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(AppIcons.arrowsClockwise),
              title: const Text('Einstellungen auf Standard'),
              subtitle: const Text(
                'Adresse, Zeitzone, Dateigröße und Kartenserver wieder aus der '
                'Server-Konfiguration nehmen. Daten und Eltern-Code bleiben.',
              ),
              trailing: TextButton(
                onPressed: _busy ? null : _resetSettings,
                child: const Text('Zurücksetzen'),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(AppIcons.trash, color: c.danger),
              title: Text(
                'Alle Daten löschen',
                style: TextStyle(color: c.danger),
              ),
              subtitle: const Text(
                'Termine, Chat, Listen, Dokumente, Fotos und alles Weitere '
                'endgültig löschen – auf dem Server und allen Geräten.',
              ),
              trailing: TextButton(
                style: TextButton.styleFrom(foregroundColor: c.danger),
                onPressed: _busy ? null : _wipe,
                child: const Text('Löschen …'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- status -----------------------------------------------------------------
