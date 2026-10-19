/// Pictographs and their joiners: the PDF fonts (Nunito, Fredoka) have no
/// glyphs for them, so a PDF would show empty boxes.
final _emoji = RegExp(
  r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2300}-\u{23FF}'
  r'\u{FE00}-\u{FE0F}\u{200D}\u{20E3}\u{E0020}-\u{E007F}]',
  unicode: true,
);

/// [text] without emoji, for the PDFs: "🟡 Gelbe Tonne" → "Gelbe Tonne".
String withoutEmoji(String text) =>
    text.replaceAll(_emoji, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim();
