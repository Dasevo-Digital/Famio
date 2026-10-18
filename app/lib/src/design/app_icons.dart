import 'package:flutter/widgets.dart';

/// All icons of the app in one place (Lucide: rounded, friendly strokes).
/// Swap the icon set here, not in the screens.
///
/// The Lucide font ships with the app (`assets/fonts/Lucide.ttf`); the
/// build keeps only the glyphs used here. A new icon: look up its name on
/// lucide.dev and its code point in `tool/lucide_codepoints.json`.
abstract final class AppIcons {
  static const _font = 'Lucide';

  /// Lucide `activity`.
  static const IconData activity = IconData(0xe038, fontFamily: _font);

  /// Lucide `alarm-clock`.
  static const IconData alarm = IconData(0xe03a, fontFamily: _font);

  /// Lucide `refresh-cw`.
  static const IconData arrowsClockwise = IconData(0xe145, fontFamily: _font);

  /// Lucide `arrow-left-right`.
  static const IconData arrowsLeftRight = IconData(0xe24a, fontFamily: _font);

  /// Lucide `external-link`.
  static const IconData arrowSquareOut = IconData(0xe0b9, fontFamily: _font);

  /// Lucide `arrow-up`.
  static const IconData arrowUp = IconData(0xe04a, fontFamily: _font);

  /// Lucide `baby`.
  static const IconData baby = IconData(0xe2ce, fontFamily: _font);

  /// Lucide `baby`.
  static const IconData babyCarriage = IconData(0xe2ce, fontFamily: _font);

  /// Lucide `backpack`.
  static const IconData backpack = IconData(0xe2c8, fontFamily: _font);

  /// Lucide `shopping-basket`.
  static const IconData basket = IconData(0xe4ea, fontFamily: _font);

  /// Lucide `bell`.
  static const IconData bell = IconData(0xe059, fontFamily: _font);

  /// Lucide `bell-off`.
  static const IconData bellOff = IconData(0xe05a, fontFamily: _font);

  /// Lucide `cake`.
  static const IconData cake = IconData(0xe344, fontFamily: _font);

  /// Lucide `calendar`.
  static const IconData calendarBlank = IconData(0xe063, fontFamily: _font);

  /// Lucide `calendar-check`.
  static const IconData calendarCheck = IconData(0xe2b7, fontFamily: _font);

  /// Lucide `calendar-days`.
  static const IconData calendarDot = IconData(0xe2b9, fontFamily: _font);

  /// Lucide `calendar-heart`.
  static const IconData calendarHeart = IconData(0xe305, fontFamily: _font);

  /// Lucide `calendar-x`.
  static const IconData calendarX = IconData(0xe2be, fontFamily: _font);

  /// Lucide `camera`.
  static const IconData camera = IconData(0xe064, fontFamily: _font);

  /// Lucide `chevron-left`.
  static const IconData caretLeft = IconData(0xe06e, fontFamily: _font);

  /// Lucide `chevron-right`.
  static const IconData caretRight = IconData(0xe06f, fontFamily: _font);

  /// Lucide `message-circle-more`.
  static const IconData chatCircleDots = IconData(0xe565, fontFamily: _font);

  /// Lucide `messages-square`.
  static const IconData chatsCircle = IconData(0xe40d, fontFamily: _font);

  /// Lucide `check`.
  static const IconData check = IconData(0xe06c, fontFamily: _font);

  /// Lucide `square-check-big`.
  static const IconData checkSquareOffset = IconData(0xe16a, fontFamily: _font);

  /// Lucide `circle`.
  static const IconData circle = IconData(0xe076, fontFamily: _font);

  /// Lucide `clock`.
  static const IconData clock = IconData(0xe087, fontFamily: _font);

  /// Lucide `cloud-download`.
  static const IconData cloudArrowDown = IconData(0xe089, fontFamily: _font);

  /// Lucide `cloud-upload`.
  static const IconData cloudArrowUp = IconData(0xe091, fontFamily: _font);

  /// Lucide `cloud-check`.
  static const IconData cloudCheck = IconData(0xe66e, fontFamily: _font);

  /// Lucide `cloud-off`.
  static const IconData cloudSlash = IconData(0xe08d, fontFamily: _font);

  /// Lucide `party-popper`.
  static const IconData confetti = IconData(0xe343, fontFamily: _font);

  /// Lucide `copy`.
  static const IconData copy = IconData(0xe09e, fontFamily: _font);

  /// Lucide `database`.
  static const IconData database = IconData(0xe0ad, fontFamily: _font);

  /// Lucide `monitor-smartphone`.
  static const IconData devices = IconData(0xe3a2, fontFamily: _font);

  /// Lucide `circle-ellipsis`.
  static const IconData dotsThreeCircle = IconData(0xe346, fontFamily: _font);

  /// Lucide `ellipsis-vertical`.
  static const IconData dotsThreeVertical = IconData(0xe0b7, fontFamily: _font);

  /// Lucide `file`.
  static const IconData file = IconData(0xe0c0, fontFamily: _font);

  /// Lucide `file-up`.
  static const IconData fileArrowUp = IconData(0xe32a, fontFamily: _font);

  /// Lucide `file-audio`.
  static const IconData fileAudio = IconData(0xe31a, fontFamily: _font);

  /// Lucide `file-text`.
  static const IconData fileDoc = IconData(0xe0cc, fontFamily: _font);

  /// Lucide `file-image`.
  static const IconData fileImage = IconData(0xe31c, fontFamily: _font);

  /// Lucide `file-text`.
  static const IconData filePdf = IconData(0xe0cc, fontFamily: _font);

  /// Lucide `file-video`.
  static const IconData fileVideo = IconData(0xe321, fontFamily: _font);

  /// Lucide `file-spreadsheet`.
  static const IconData fileXls = IconData(0xe326, fontFamily: _font);

  /// Lucide `heart-pulse`.
  static const IconData firstAidKit = IconData(0xe36e, fontFamily: _font);

  /// Lucide `folder-open`.
  static const IconData folderOpen = IconData(0xe247, fontFamily: _font);

  /// Lucide `folder-heart`.
  static const IconData folderSimpleStar = IconData(0xe333, fontFamily: _font);

  /// Lucide `settings`.
  static const IconData gearSix = IconData(0xe154, fontFamily: _font);

  /// Lucide `eye`.
  static const IconData eye = IconData(0xe0ba, fontFamily: _font);

  /// Lucide `eye-off`.
  static const IconData eyeSlash = IconData(0xe0bb, fontFamily: _font);

  /// Lucide `car`.
  static const IconData car = IconData(0xe1d5, fontFamily: _font);

  /// Lucide `shield`.
  static const IconData shield = IconData(0xe158, fontFamily: _font);

  /// Lucide `heart-pulse`.
  static const IconData heartPulse = IconData(0xe36e, fontFamily: _font);

  /// Lucide `ticket`.
  static const IconData ticket = IconData(0xe20f, fontFamily: _font);

  /// Lucide `briefcase`.
  static const IconData briefcase = IconData(0xe062, fontFamily: _font);

  /// Lucide `banknote`.
  static const IconData banknote = IconData(0xe052, fontFamily: _font);

  /// Lucide `coins`.
  static const IconData coins = IconData(0xe097, fontFamily: _font);

  /// Lucide `sofa`.
  static const IconData sofa = IconData(0xe2c4, fontFamily: _font);

  /// Lucide `globe`.
  static const IconData globe = IconData(0xe0e8, fontFamily: _font);

  /// Lucide `server`.
  static const IconData hardDrives = IconData(0xe153, fontFamily: _font);

  /// Lucide `heart`.
  static const IconData heart = IconData(0xe0f2, fontFamily: _font);

  /// Lucide `hourglass`.
  static const IconData hourglassMedium = IconData(0xe296, fontFamily: _font);

  /// Lucide `house`.
  static const IconData house = IconData(0xe0f5, fontFamily: _font);

  /// Lucide `house`.
  static const IconData houseLine = IconData(0xe0f5, fontFamily: _font);

  /// Lucide `id-card`.
  static const IconData identificationCard = IconData(
    0xe617,
    fontFamily: _font,
  );

  /// Lucide `image`.
  static const IconData image = IconData(0xe0f6, fontFamily: _font);

  /// Lucide `image-off`.
  static const IconData imageBroken = IconData(0xe1c0, fontFamily: _font);

  /// Lucide `images`.
  static const IconData images = IconData(0xe5c4, fontFamily: _font);

  /// Lucide `image-plus`.
  static const IconData imageSquare = IconData(0xe1f7, fontFamily: _font);

  /// Lucide `info`.
  static const IconData info = IconData(0xe0f9, fontFamily: _font);

  /// Lucide `key-round`.
  static const IconData key = IconData(0xe4a3, fontFamily: _font);

  /// Lucide `laptop`.
  static const IconData laptop = IconData(0xe1cd, fontFamily: _font);

  /// Lucide `lightbulb`.
  static const IconData lightbulb = IconData(0xe1c2, fontFamily: _font);

  /// Lucide `link`.
  static const IconData link = IconData(0xe102, fontFamily: _font);

  /// Lucide `lock`.
  static const IconData lock = IconData(0xe10b, fontFamily: _font);

  /// Lucide `lock-keyhole`.
  static const IconData lockKey = IconData(0xe531, fontFamily: _font);

  /// Lucide `search`.
  static const IconData magnifyingGlass = IconData(0xe151, fontFamily: _font);

  /// Lucide `map-pin`.
  static const IconData mapPin = IconData(0xe111, fontFamily: _font);

  /// Lucide `map-pinned`.
  static const IconData mapPinned = IconData(0xe53d, fontFamily: _font);

  /// Lucide `map-pin-off`.
  static const IconData mapPinOff = IconData(0xe2a6, fontFamily: _font);

  /// Lucide `map`.
  static const IconData map = IconData(0xe110, fontFamily: _font);

  /// Lucide `locate-fixed`.
  static const IconData locate = IconData(0xe1db, fontFamily: _font);

  /// Lucide `route`.
  static const IconData route = IconData(0xe53e, fontFamily: _font);

  /// Lucide `pause`.
  static const IconData pause = IconData(0xe12e, fontFamily: _font);

  /// Lucide `play`.
  static const IconData play = IconData(0xe13c, fontFamily: _font);

  /// Lucide `circle-stop`.
  static const IconData stop = IconData(0xe083, fontFamily: _font);

  /// Lucide `battery-medium`.
  static const IconData battery = IconData(0xe057, fontFamily: _font);

  /// Lucide `history`.
  static const IconData history = IconData(0xe1f5, fontFamily: _font);

  /// Lucide `monitor`.
  static const IconData monitor = IconData(0xe11d, fontFamily: _font);

  /// Lucide `contrast`.
  static const IconData contrast = IconData(0xe09d, fontFamily: _font);

  /// Lucide `sticky-note`.
  static const IconData note = IconData(0xe303, fontFamily: _font);

  /// Lucide `paperclip`.
  static const IconData paperclip = IconData(0xe12d, fontFamily: _font);

  /// Lucide `send`.
  static const IconData paperPlaneRight = IconData(0xe152, fontFamily: _font);

  /// Lucide `key-round`.
  static const IconData password = IconData(0xe4a3, fontFamily: _font);

  /// Lucide `pencil`.
  static const IconData pencilSimple = IconData(0xe1f9, fontFamily: _font);

  /// Lucide `piggy-bank`.
  static const IconData piggyBank = IconData(0xe13a, fontFamily: _font);

  /// Lucide `plus`.
  static const IconData plus = IconData(0xe13d, fontFamily: _font);

  /// Lucide `circle-help`.
  static const IconData question = IconData(0xe082, fontFamily: _font);

  /// Lucide `repeat`.
  static const IconData repeat = IconData(0xe146, fontFamily: _font);

  /// Lucide `rotate-ccw`.
  static const IconData rotateCcw = IconData(0xe148, fontFamily: _font);

  /// Lucide `ruler`.
  static const IconData ruler = IconData(0xe14b, fontFamily: _font);

  /// Lucide `shield-user`.
  static const IconData shieldUser = IconData(0xe647, fontFamily: _font);

  /// Lucide `shield-check`.
  static const IconData shieldCheck = IconData(0xe1ff, fontFamily: _font);

  /// Lucide `qr-code`.
  static const IconData qrCode = IconData(0xe1df, fontFamily: _font);

  /// Lucide `log-in`.
  static const IconData logIn = IconData(0xe10d, fontFamily: _font);

  /// Lucide `unlink`.
  static const IconData unlink = IconData(0xe19c, fontFamily: _font);

  /// Lucide `shopping-cart`.
  static const IconData shoppingCartSimple = IconData(
    0xe15c,
    fontFamily: _font,
  );

  /// Lucide `signature`.
  static const IconData signature = IconData(0xe5f2, fontFamily: _font);

  /// Lucide `log-out`.
  static const IconData signOut = IconData(0xe10e, fontFamily: _font);

  /// Lucide `smartphone`.
  static const IconData smartphone = IconData(0xe163, fontFamily: _font);

  /// Lucide `smile`.
  static const IconData smiley = IconData(0xe164, fontFamily: _font);

  /// Lucide `sparkles`.
  static const IconData sparkle = IconData(0xe412, fontFamily: _font);

  /// Lucide `star`.
  static const IconData star = IconData(0xe176, fontFamily: _font);

  /// Lucide `stethoscope`.
  static const IconData stethoscope = IconData(0xe2f1, fontFamily: _font);

  /// Lucide `sun`.
  static const IconData sun = IconData(0xe178, fontFamily: _font);

  /// Lucide `syringe`.
  static const IconData syringe = IconData(0xe2f2, fontFamily: _font);

  /// Lucide `trash-2`.
  static const IconData trash = IconData(0xe18e, fontFamily: _font);

  /// Lucide `umbrella`.
  static const IconData umbrella = IconData(0xe199, fontFamily: _font);

  /// Lucide `upload`.
  static const IconData upload = IconData(0xe19e, fontFamily: _font);

  /// Lucide `user`.
  static const IconData user = IconData(0xe19f, fontFamily: _font);

  /// Lucide `user-cog`.
  static const IconData userCog = IconData(0xe342, fontFamily: _font);

  /// Lucide `user-check`.
  static const IconData userList = IconData(0xe1a0, fontFamily: _font);

  /// Lucide `user-minus`.
  static const IconData userMinus = IconData(0xe1a1, fontFamily: _font);

  /// Lucide `user-plus`.
  static const IconData userPlus = IconData(0xe1a2, fontFamily: _font);

  /// Lucide `users`.
  static const IconData usersThree = IconData(0xe1a4, fontFamily: _font);

  /// Lucide `circle-alert`.
  static const IconData warningCircle = IconData(0xe077, fontFamily: _font);

  /// Lucide `x`.
  static const IconData x = IconData(0xe1b2, fontFamily: _font);

  /// Lucide `bot`.
  static const IconData bot = IconData(0xe1bb, fontFamily: _font);

  /// Lucide `layout-grid`.
  static const IconData layoutGrid = IconData(0xe0ff, fontFamily: _font);

  // Health log, emergency, contacts and planning.
  /// Lucide `milk`.
  static const IconData milk = IconData(0xe399, fontFamily: _font);

  /// Lucide `droplet`.
  static const IconData droplet = IconData(0xe0b4, fontFamily: _font);

  /// Lucide `droplets`.
  static const IconData droplets = IconData(0xe0b5, fontFamily: _font);

  /// Lucide `moon`.
  static const IconData moon = IconData(0xe11e, fontFamily: _font);

  /// Lucide `thermometer`.
  static const IconData thermometer = IconData(0xe186, fontFamily: _font);

  /// Lucide `pill`.
  static const IconData pill = IconData(0xe3bd, fontFamily: _font);

  /// Lucide `bath`.
  static const IconData bath = IconData(0xe2ab, fontFamily: _font);

  /// Lucide `bandage`.
  static const IconData bandage = IconData(0xe61d, fontFamily: _font);

  /// Lucide `utensils`.
  static const IconData utensils = IconData(0xe2f6, fontFamily: _font);

  /// Lucide `soup`.
  static const IconData soup = IconData(0xe3aa, fontFamily: _font);

  /// Lucide `apple`.
  static const IconData apple = IconData(0xe34e, fontFamily: _font);

  /// Lucide `phone`.
  static const IconData phone = IconData(0xe133, fontFamily: _font);

  /// Lucide `phone-call`.
  static const IconData phoneCall = IconData(0xe134, fontFamily: _font);

  /// Lucide `siren`.
  static const IconData siren = IconData(0xe2ef, fontFamily: _font);

  /// Lucide `ambulance`.
  static const IconData ambulance = IconData(0xe5bb, fontFamily: _font);

  /// Lucide `contact`.
  static const IconData contact = IconData(0xe09c, fontFamily: _font);

  /// Lucide `book-user`.
  static const IconData bookUser = IconData(0xe54d, fontFamily: _font);

  /// Lucide `cloud-sun`.
  static const IconData cloudSun = IconData(0xe216, fontFamily: _font);

  /// Lucide `shirt`.
  static const IconData shirt = IconData(0xe1ca, fontFamily: _font);

  /// Lucide `chart-column`.
  static const IconData chartColumn = IconData(0xe2a3, fontFamily: _font);

  /// Lucide `chart-line`.
  static const IconData chartLine = IconData(0xe2a5, fontFamily: _font);

  /// Lucide `timer`.
  static const IconData timer = IconData(0xe1e0, fontFamily: _font);

  /// Lucide `chef-hat`.
  static const IconData chefHat = IconData(0xe2ac, fontFamily: _font);

  /// Lucide `clipboard-list`.
  static const IconData clipboardList = IconData(0xe086, fontFamily: _font);

  /// Lucide `glass-water`.
  static const IconData glassWater = IconData(0xe2d5, fontFamily: _font);

  /// Lucide `cooking-pot`.
  static const IconData cookingPot = IconData(0xe584, fontFamily: _font);

  /// Lucide `notebook-pen`.
  static const IconData notebookPen = IconData(0xe596, fontFamily: _font);

  /// Lucide `wallet`.
  static const IconData wallet = IconData(0xe204, fontFamily: _font);

  /// Lucide `trophy`.
  static const IconData trophy = IconData(0xe373, fontFamily: _font);

  /// Lucide `gift`.
  static const IconData gift = IconData(0xe0e1, fontFamily: _font);

  /// Lucide `file-text`.
  static const IconData fileText = IconData(0xe0cc, fontFamily: _font);

  /// Lucide `scan-barcode`.
  static const IconData scanBarcode = IconData(0xe535, fontFamily: _font);

  /// Lucide `scan-text`.
  static const IconData scanText = IconData(0xe538, fontFamily: _font);

  /// Lucide `package`.
  static const IconData package = IconData(0xe129, fontFamily: _font);

  /// Lucide `list-checks`.
  static const IconData listChecks = IconData(0xe1d0, fontFamily: _font);

  /// Lucide `vote`.
  static const IconData vote = IconData(0xe3ad, fontFamily: _font);

  /// Lucide `minus`.
  static const IconData minus = IconData(0xe11c, fontFamily: _font);

  /// Lucide `refrigerator`.
  static const IconData refrigerator = IconData(0xe37b, fontFamily: _font);

  /// Lucide `sunrise`.
  static const IconData sunrise = IconData(0xe179, fontFamily: _font);

  /// Lucide `moon-star`.
  static const IconData moonStar = IconData(0xe410, fontFamily: _font);

  /// Lucide `message-square-text`.
  static const IconData comment = IconData(0xe575, fontFamily: _font);

  /// Lucide `tv`.
  static const IconData tv = IconData(0xe195, fontFamily: _font);

  /// Lucide `medal`.
  static const IconData medal = IconData(0xe36f, fontFamily: _font);

  /// Lucide `pill-bottle`.
  static const IconData pillBottle = IconData(0xe5ea, fontFamily: _font);

  /// Lucide `hand-coins`.
  static const IconData handCoins = IconData(0xe5b8, fontFamily: _font);

  /// Lucide `bell-ring`.
  static const IconData bellRing = IconData(0xe224, fontFamily: _font);

  /// Lucide `layout-template`.
  static const IconData template = IconData(0xe207, fontFamily: _font);

  /// Lucide `chart-no-axes-column`.
  static const IconData poll = IconData(0xe068, fontFamily: _font);

  /// Lucide `calendar-range`.
  static const IconData calendarRange = IconData(0xe2bd, fontFamily: _font);

  /// Lucide `luggage`.
  static const IconData luggage = IconData(0xe2ca, fontFamily: _font);

  /// Lucide `party-popper`.
  static const IconData partyPopper = IconData(0xe343, fontFamily: _font);

  /// Lucide `paw-print`.
  static const IconData pawPrint = IconData(0xe4f5, fontFamily: _font);

  /// Lucide `recycle`.
  static const IconData recycle = IconData(0xe2e9, fontFamily: _font);

  /// Lucide `wrench`.
  static const IconData wrench = IconData(0xe1b1, fontFamily: _font);

  /// Lucide `languages`.
  static const IconData languages = IconData(0xe0fe, fontFamily: _font);
}
