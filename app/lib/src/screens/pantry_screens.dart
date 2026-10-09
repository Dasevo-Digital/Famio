import 'dart:convert';
import 'dart:io';

import 'package:famio_client/famio_client.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_state.dart';
import '../data/family_data.dart';
import '../data/family_extras.dart';
import '../design/app_icons.dart';
import '../design/components.dart';
import '../design/palette.dart';
import '../widgets/data_builder.dart';
import '../widgets/sync_status_icon.dart';
import '../widgets/undo_delete.dart';
import '../l10n.dart';

const _collections = {
  Collections.pantryItems,
  Collections.shoppingLists,
  Collections.shoppingItems,
};

/// Whether this device has a camera scanner (Windows and Linux do not).
bool get scannerAvailable =>
    !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

/// Entry on the shopping page: what runs low or expires.
class PantryCard extends StatelessWidget {
  const PantryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.shopping);
    return DataBuilder(
      collections: const {Collections.pantryItems},
      builder: (context, engine) {
        final items = engine.pantryItems;
        final today = DateTime.now();
        final low = items.where((i) => i.low).length;
        final expiring = items
            .where((i) => (i.daysLeft(today) ?? 99) <= 3)
            .length;
        return SoftCard(
          color: c.tint(FamioSection.shopping),
          onTap: () => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => const PantryScreen())),
          child: Row(
            children: [
              IconBlob(
                AppIcons.refrigerator,
                color: color,
                background: c.surface,
                size: 52,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Vorrat',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      items.isEmpty
                          ? 'Kühlschrank & Vorratsschrank im Blick – mit Barcode-Scanner'
                          : [
                              '${items.length} Artikel',
                              if (low > 0) '$low werden knapp',
                              if (expiring > 0) '$expiring laufen bald ab',
                            ].join(' · '),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Icon(AppIcons.caretRight, color: color),
            ],
          ),
        );
      },
    );
  }
}

class PantryScreen extends StatefulWidget {
  const PantryScreen({super.key});

  @override
  State<PantryScreen> createState() => _PantryScreenState();
}

class _PantryScreenState extends State<PantryScreen> {
  PantryPlace? _place;

  Future<void> _scan() async {
    final engine = AppScope.engineOf(context);
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const BarcodeScanScreen()),
    );
    if (code == null || !mounted) return;
    final known = engine.pantryByBarcode(code);
    if (known != null) {
      await _scannedKnown(engine, known);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('Suche Produkt …'),
        duration: Duration(seconds: 2),
      ),
    );
    final product = await lookupProduct(code);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    await showPantryEditor(
      context,
      initial: PantryItem(
        id: newId(),
        name: product?.name ?? '',
        brand: product?.brand ?? '',
        barcode: code,
        place: _place ?? PantryPlace.pantry,
      ),
    );
  }

  /// A known product: one more in stock, or one used up.
  Future<void> _scannedKnown(SyncEngine engine, PantryItem item) async {
    final add = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(item.name),
        content: Text('Vorrat: ${item.amountLabel}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Verbraucht (−1)'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eingekauft (+1)'),
          ),
        ],
      ),
    );
    if (add == null) return;
    final amount = (item.amount + (add ? 1 : -1)).clamp(0, 99999).toDouble();
    engine.savePantryItem(item.copyWith(amount: amount));
  }

  void _restock(SyncEngine engine, List<PantryItem> low) {
    final lists = engine.shoppingLists;
    if (lists.isEmpty) {
      final list = ShoppingList(id: newId(), name: 'Einkauf');
      engine.saveShoppingList(list);
      lists.add(list);
    }
    final added = engine.addToShoppingList(lists.first.id, [
      for (final i in low) Ingredient(name: i.name),
    ]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'Steht schon alles auf „${lists.first.name}“'
              : '$added Artikel auf „${lists.first.name}“ gesetzt',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final color = c.strong(FamioSection.shopping);
    return SectionPage(
      maxBodyWidth: 960,
      section: FamioSection.shopping,
      title: 'Vorrat',
      subtitle: 'Was ist noch da?',
      actions: [
        if (scannerAvailable)
          BubbleButton(
            icon: AppIcons.scanBarcode,
            tooltip: 'Barcode scannen',
            onPressed: _scan,
          ),
        const SyncStatusIcon(),
      ],
      floating: AddButton(
        color: color,
        tooltip: 'Artikel hinzufügen',
        onPressed: () => showPantryEditor(
          context,
          initial: PantryItem(
            id: newId(),
            name: '',
            place: _place ?? PantryPlace.pantry,
          ),
        ),
      ),
      body: DataBuilder(
        collections: _collections,
        builder: (context, engine) {
          final all = engine.pantryItems;
          final items = _place == null
              ? all
              : all.where((i) => i.place == _place).toList();
          final today = DateTime.now();
          final expiring =
              items.where((i) => (i.daysLeft(today) ?? 99) <= 3).toList()
                ..sort((a, b) => a.bestBefore!.compareTo(b.bestBefore!));
          final low = items.where((i) => i.low).toList();
          return Column(
            children: [
              PillTabs<PantryPlace?>(
                values: const [null, ...PantryPlace.values],
                selected: _place,
                label: (p) => p == null ? 'Alles' : '${p.emoji} ${p.label}',
                color: color,
                onChanged: (p) => setState(() => _place = p),
              ),
              Expanded(
                child: items.isEmpty
                    ? EmptyHint(
                        icon: AppIcons.refrigerator,
                        color: color,
                        text: scannerAvailable
                            ? 'Noch nichts erfasst.\nScanne den Barcode einer '
                                  'Packung oder tippe auf +.'
                            : 'Noch nichts erfasst. Tippe auf +.',
                      )
                    : ListView(
                        padding: EdgeInsets.only(
                          top: 8,
                          bottom: listBottomPadding(context),
                        ),
                        children: [
                          if (expiring.isNotEmpty) ...[
                            ListHeading('Bald verbrauchen', color: c.danger),
                            for (final i in expiring)
                              _PantryTile(item: i, engine: engine),
                          ],
                          if (low.isNotEmpty)
                            ListHeading(
                              'Wird knapp',
                              color: color,
                              trailing: TextButton.icon(
                                icon: const Icon(AppIcons.basket, size: 18),
                                label: const Text('Auf die Einkaufsliste'),
                                onPressed: () => _restock(engine, low),
                              ),
                            ),
                          for (final i in low)
                            if (!expiring.contains(i))
                              _PantryTile(item: i, engine: engine),
                          const ListHeading('Alles'),
                          for (final i in items)
                            if (!expiring.contains(i) && !low.contains(i))
                              _PantryTile(item: i, engine: engine),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PantryTile extends StatelessWidget {
  const _PantryTile({required this.item, required this.engine});

  final PantryItem item;
  final SyncEngine engine;

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final theme = Theme.of(context);
    final days = item.daysLeft(DateTime.now());
    final expiry = days == null
        ? null
        : days < 0
        ? 'abgelaufen'
        : days == 0
        ? 'MHD heute'
        : days == 1
        ? 'MHD morgen'
        : 'MHD ${DateFormat.Md(appLanguage).format(item.bestBefore!)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SoftCard(
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        onTap: () => showPantryEditor(context, initial: item, existing: true),
        child: Row(
          children: [
            Text(item.place.emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: theme.textTheme.titleMedium),
                  Text(
                    [
                      if (item.brand.isNotEmpty) item.brand,
                      ?expiry,
                      if (item.low) 'knapp',
                    ].join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: (days ?? 99) <= 1 ? c.danger : null,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Eins weniger',
              icon: const Icon(AppIcons.minus),
              onPressed: item.amount <= 0
                  ? null
                  : () => engine.savePantryItem(
                      item.copyWith(
                        amount: (item.amount - 1).clamp(0, 99999).toDouble(),
                      ),
                    ),
            ),
            SizedBox(
              width: 96,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  item.amountLabel,
                  maxLines: 1,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Eins mehr',
              icon: const Icon(AppIcons.plus),
              onPressed: () =>
                  engine.savePantryItem(item.copyWith(amount: item.amount + 1)),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showPantryEditor(
  BuildContext context, {
  required PantryItem initial,
  bool existing = false,
}) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _PantryEditor(initial: initial, existing: existing),
);

class _PantryEditor extends StatefulWidget {
  const _PantryEditor({required this.initial, required this.existing});

  final PantryItem initial;
  final bool existing;

  @override
  State<_PantryEditor> createState() => _PantryEditorState();
}

class _PantryEditorState extends State<_PantryEditor> {
  late final _name = TextEditingController(text: widget.initial.name);
  late final _brand = TextEditingController(text: widget.initial.brand);
  late final _amount = TextEditingController(
    text: widget.existing ? _num(widget.initial.amount) : '1',
  );
  late final _unit = TextEditingController(text: widget.initial.unit);
  late final _min = TextEditingController(
    text: widget.initial.minAmount == 0 ? '' : _num(widget.initial.minAmount),
  );
  late var _place = widget.initial.place;
  late DateTime? _bestBefore = widget.initial.bestBefore;

  static String _num(double v) => v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toString().replaceAll('.', ',');

  static double? _parse(String t) =>
      double.tryParse(t.trim().replaceAll(',', '.'));

  @override
  void dispose() {
    for (final c in [_name, _brand, _amount, _unit, _min]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    AppScope.engineOf(context).savePantryItem(
      widget.initial.copyWith(
        name: name,
        brand: _brand.text.trim(),
        amount: _parse(_amount.text) ?? 0,
        unit: _unit.text.trim(),
        minAmount: _parse(_min.text) ?? 0,
        place: _place,
        bestBefore: _bestBefore,
      ),
    );
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = FamioColors.of(context);
    final engine = AppScope.engineOf(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.existing ? 'Vorrat bearbeiten' : 'In den Vorrat',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            if (widget.initial.barcode != null)
              Text(
                'Barcode ${widget.initial.barcode}'
                '${widget.initial.name.isEmpty && !widget.existing ? ' – Produkt unbekannt, bitte Namen eintragen' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: widget.initial.name.isEmpty,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Artikel'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _brand,
              decoration: const InputDecoration(labelText: 'Marke (optional)'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Menge'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _unit,
                    decoration: const InputDecoration(
                      labelText: 'Einheit',
                      hintText: 'Stück, Packungen, l',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _min,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Knapp ab'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in PantryPlace.values)
                  ChoiceChip(
                    label: Text('${p.emoji} ${p.label}'),
                    selected: _place == p,
                    selectedColor: c.tint(FamioSection.shopping),
                    onSelected: (_) => setState(() => _place = p),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: InputChip(
                avatar: const Icon(AppIcons.calendarX, size: 18),
                label: Text(
                  _bestBefore == null
                      ? 'Mindestens haltbar bis …'
                      : 'MHD ${DateFormat.yMd(appLanguage).format(_bestBefore!)}',
                ),
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _bestBefore ?? now,
                    firstDate: DateTime(now.year - 1),
                    lastDate: DateTime(now.year + 10),
                  );
                  if (picked != null) setState(() => _bestBefore = picked);
                },
                onDeleted: _bestBefore == null
                    ? null
                    : () => setState(() => _bestBefore = null),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                if (widget.existing)
                  TextButton.icon(
                    icon: const Icon(AppIcons.trash, size: 18),
                    label: const Text('Entfernen'),
                    style: TextButton.styleFrom(foregroundColor: c.danger),
                    onPressed: () {
                      deleteWithUndo(
                        context,
                        what: widget.initial.name,
                        collections: const {Collections.pantryItems},
                        delete: () =>
                            engine.deletePantryItem(widget.initial.id),
                      );
                      Navigator.pop(context);
                    },
                  ),
                const Spacer(),
                ColorButton(
                  label: 'Speichern',
                  color: c.strong(FamioSection.shopping),
                  onPressed: _save,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Full screen camera that returns the first product barcode it sees.
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({
    super.key,
    this.qr = false,
    this.title = 'Barcode scannen',
  });

  /// Scan QR codes (e.g. an invitation) instead of product barcodes.
  final bool qr;
  final String title;

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  late final _controller = MobileScannerController(
    formats: widget.qr
        ? const [BarcodeFormat.qrCode]
        : const [
            BarcodeFormat.ean13,
            BarcodeFormat.ean8,
            BarcodeFormat.upcA,
            BarcodeFormat.upcE,
          ],
  );
  var _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(widget.title),
    ),
    body: Stack(
      children: [
        MobileScanner(
          controller: _controller,
          onDetect: (capture) {
            final code = capture.barcodes
                .map((b) => b.rawValue)
                .nonNulls
                .firstOrNull;
            if (code == null || _done) return;
            _done = true;
            Navigator.pop(context, code);
          },
          errorBuilder: (context, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                'Die Kamera ist nicht verfügbar. Bitte den Zugriff in den '
                'Einstellungen erlauben.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ),
        Center(
          child: Container(
            width: 280,
            height: widget.qr ? 280 : 160,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white, width: 3),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
        ),
      ],
    ),
  );
}

/// A product as Open Food Facts knows it.
typedef ProductInfo = ({String name, String brand});

/// Looks the barcode up in the free Open Food Facts database; null if
/// unknown or offline. Only the barcode leaves the device.
Future<ProductInfo?> lookupProduct(String code, {http.Client? client}) async {
  if (!RegExp(r'^\d{6,14}$').hasMatch(code)) return null;
  final http.Client c = client ?? http.Client();
  try {
    final response = await c
        .get(
          Uri.https('world.openfoodfacts.org', '/api/v2/product/$code.json', {
            'fields': 'product_name,product_name_de,brands,quantity',
          }),
          headers: {'user-agent': 'Famio/0.13 (Familien-Organizer)'},
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(response.bodyBytes));
    if (json is! Map || json['status'] != 1) return null;
    final p = (json['product'] as Map?)?.cast<String, Object?>() ?? {};
    String text(Object? v) => v is String ? v.trim() : '';
    var name = text(p['product_name_de']);
    if (name.isEmpty) name = text(p['product_name']);
    if (name.isEmpty) return null;
    final quantity = text(p['quantity']);
    return (
      name: quantity.isEmpty ? name : '$name ($quantity)',
      brand: text(p['brands']).split(',').first.trim(),
    );
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}
