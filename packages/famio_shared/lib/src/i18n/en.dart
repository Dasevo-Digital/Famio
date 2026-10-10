/// English texts of the shared enums, catalogs and messages (key → text),
/// see [sharedTexts]. German is in the code itself.
const sharedEn = <String, String>{
  "MemberRole.adult": "Adult",
  "MemberRole.child": "Child",
  "MemberRole.guest": "Guest",
  "MemberRole.service": "Service account",
  "ServiceAccess.full": "Read and change",
  "ServiceAccess.everyday": "Tick off and shopping",
  "ServiceAccess.readOnly": "Read only",
  "TwoFactorPolicy.admins": "Administrators",
  "TwoFactorPolicy.all": "All members",
  "GermanState.bw": "Baden-Württemberg",
  "GermanState.by": "Bavaria",
  "GermanState.be": "Berlin",
  "GermanState.bb": "Brandenburg",
  "GermanState.hb": "Bremen",
  "GermanState.hh": "Hamburg",
  "GermanState.he": "Hesse",
  "GermanState.mv": "Mecklenburg-Western Pomerania",
  "GermanState.ni": "Lower Saxony",
  "GermanState.nw": "North Rhine-Westphalia",
  "GermanState.rp": "Rhineland-Palatinate",
  "GermanState.sl": "Saarland",
  "GermanState.sn": "Saxony",
  "GermanState.st": "Saxony-Anhalt",
  "GermanState.sh": "Schleswig-Holstein",
  "GermanState.th": "Thuringia",
  "MilestoneArea.motor": "Movement",
  "MilestoneArea.fineMotor": "Hands & dexterity",
  "MilestoneArea.language": "Language",
  "MilestoneArea.social": "Feelings & social",
  "MilestoneArea.selfCare": "Independence",
  "MilestoneArea.body": "Body",
  "ChoreRepeat.once": "Once",
  "ChoreRepeat.daily": "Daily",
  "ChoreRepeat.weekly": "Once a week",
  "MoneyKind.allowance": "Pocket money",
  "MoneyKind.points": "Points exchanged",
  "MoneyKind.spent": "Spent",
  "MoneyKind.gift": "Gift",
  "MoneyKind.other": "Other",
  "ContactRole.pediatrician": "Pediatrician",
  "ContactRole.doctor": "Doctor",
  "ContactRole.dentist": "Dentist",
  "ContactRole.midwife": "Midwife",
  "ContactRole.clinic": "Hospital",
  "ContactRole.daycare": "Daycare",
  "ContactRole.school": "School",
  "ContactRole.babysitter": "Babysitter",
  "ContactRole.family": "Family & friends",
  "ContactRole.emergency": "Emergency service",
  "ContactRole.other": "Other",
  "DocumentCategory.identity": "IDs & passports",
  "DocumentCategory.health": "Health",
  "DocumentCategory.school": "School & daycare",
  "DocumentCategory.insurance": "Insurance",
  "DocumentCategory.finance": "Finances & taxes",
  "DocumentCategory.home": "House & home",
  "DocumentCategory.contracts": "Contracts",
  "DocumentCategory.photos": "Photos",
  "DocumentCategory.other": "Other",
  "PantryPlace.fridge": "Fridge",
  "PantryPlace.freezer": "Freezer",
  "PantryPlace.pantry": "Pantry",
  "PantryPlace.other": "Other",
  "LogKind.breast": "Breastfeeding",
  "LogKind.bottle": "Bottle",
  "LogKind.solids": "Solids",
  "LogKind.pumping": "Pumping",
  "LogKind.sleep": "Sleep",
  "LogKind.diaper": "Diaper",
  "LogKind.temperature": "Temperature",
  "LogKind.medication": "Medication",
  "LogKind.symptom": "Symptom",
  "LogKind.bath": "Bath",
  "BreastSide.left": "left",
  "BreastSide.right": "right",
  "MilkKind.breastMilk": "Breast milk",
  "MilkKind.formula": "Formula",
  "MilkKind.other": "Other",
  "DiaperKind.wet": "wet",
  "DiaperKind.dirty": "dirty",
  "DiaperKind.both": "wet + dirty",
  "WasteKind.residual": "Residual waste",
  "WasteKind.organic": "Organic waste",
  "WasteKind.paper": "Paper",
  "WasteKind.packaging": "Packaging",
  "WasteKind.glass": "Glass",
  "WasteKind.garden": "Garden waste",
  "WasteKind.bulky": "Bulky waste",
  "WasteKind.hazardous": "Hazardous waste",
  "WasteKind.other": "Collection",
  "MealSlot.breakfast": "Breakfast",
  "MealSlot.lunch": "Lunch",
  "MealSlot.dinner": "Dinner",
  "MealSlot.snack": "Snack",
  "DeadlineArea.car": "Car",
  "DeadlineArea.home": "House & home",
  "DeadlineArea.pet": "Pets",
  "DeadlineArea.other": "Other",
  "Checklist|Kliniktasche": "Hospital bag",
  "Checklist|Erstausstattung": "Baby essentials",
  "Checklist|Nach der Geburt": "After the birth",
  "Holiday|Neujahr": "New Year's Day",
  "Holiday|Heilige Drei Könige": "Epiphany",
  "Holiday|Karfreitag": "Good Friday",
  "Holiday|Ostermontag": "Easter Monday",
  "Holiday|Tag der Arbeit": "Labor Day",
  "Holiday|Christi Himmelfahrt": "Ascension Day",
  "Holiday|Pfingstmontag": "Whit Monday",
  "Holiday|Fronleichnam": "Corpus Christi",
  "Holiday|Tag der Deutschen Einheit": "German Unity Day",
  "Holiday|Allerheiligen": "All Saints' Day",
  "Holiday|1. Weihnachtstag": "Christmas Day",
  "Holiday|2. Weihnachtstag": "Boxing Day",
  "Holiday|Internationaler Frauentag": "International Women's Day",
  "Holiday|Ostersonntag": "Easter Sunday",
  "Holiday|Pfingstsonntag": "Whit Sunday",
  "Holiday|Reformationstag": "Reformation Day",
  "Holiday|Mariä Himmelfahrt": "Assumption Day",
  "Holiday|Buß- und Bettag": "Day of Repentance and Prayer",
  "Holiday|Weltkindertag": "World Children's Day",
  "ShoppingCategory.produce": "Fruit & vegetables",
  "ShoppingCategory.bakery": "Bread & bakery",
  "ShoppingCategory.dairy": "Chilled",
  "ShoppingCategory.meat": "Meat, cold cuts & fish",
  "ShoppingCategory.frozen": "Frozen",
  "ShoppingCategory.pantry": "Pasta, rice & cans",
  "ShoppingCategory.baking": "Baking & spices",
  "ShoppingCategory.drinks": "Drinks",
  "ShoppingCategory.snacks": "Sweets & snacks",
  "ShoppingCategory.household": "Drugstore & household",
  "ShoppingCategory.baby": "Baby & child",
  "ShoppingCategory.pet": "Pet supplies",
  "ShoppingCategory.other": "Other",
  "DeadlinePreset|HU/TÜV": "Car inspection",
  "DeadlinePreset|Monat steht auf der Plakette am hinteren Kennzeichen":
      "The month is on the sticker on the rear license plate",
  "DeadlinePreset|Inspektion": "Service",
  "DeadlinePreset|Winterreifen aufziehen": "Put on winter tires",
  "DeadlinePreset|Faustregel: von Oktober bis Ostern":
      "Rule of thumb: from October to Easter",
  "DeadlinePreset|Sommerreifen aufziehen": "Put on summer tires",
  "DeadlinePreset|Kfz-Versicherung prüfen": "Check car insurance",
  "DeadlinePreset|Verbandkasten tauschen": "Replace the first aid kit",
  "DeadlinePreset|Heizungswartung": "Heating maintenance",
  "DeadlinePreset|Rauchmelder testen": "Test smoke detectors",
  "DeadlinePreset|Schornsteinfeger": "Chimney sweep",
  "DeadlinePreset|Wasserfilter wechseln": "Change water filter",
  "DeadlinePreset|Feuerlöscher prüfen": "Check fire extinguisher",
  "DeadlinePreset|Zählerstände ablesen": "Read the meters",
  "DeadlinePreset|Impfung": "Vaccination",
  "DeadlinePreset|Entwurmung": "Deworming",
  "DeadlinePreset|Floh- und Zeckenschutz": "Flea and tick protection",
  "DeadlinePreset|Tierarzt-Check": "Vet checkup",
  "DeadlinePreset|Hundesteuer": "Dog tax",
  "ListTemplate|Urlaub": "Vacation",
  "ListTemplate|Kita-Tasche": "Daycare bag",
  "ListTemplate|Kliniktasche Geburt": "Hospital bag for the birth",
  "ListTemplate|Schwimmbad": "Swimming pool",
  "ListTemplate|Camping": "Camping",
  "CheckIn|Bin angekommen": "I've arrived",
  "CheckIn|Alles ok": "All okay",
  "CheckIn|Bin auf dem Heimweg": "On my way home",
  "CheckIn|Bitte abholen": "Please pick me up",
  "LocationAlert|{member} ist bei „{place}“ angekommen":
      "{member} arrived at “{place}”",
  "LocationAlert|{member} hat „{place}“ verlassen": "{member} left “{place}”",
  "LocationAlert|{member}: {note} (bei „{place}“)":
      "{member}: {note} (at “{place}”)",
  "Recurrence|täglich": "daily",
  "Recurrence|alle {every} Tage": "every {every} days",
  "Recurrence|wöchentlich": "weekly",
  "Recurrence|alle {every} Wochen": "every {every} weeks",
  "Recurrence|monatlich": "monthly",
  "Recurrence|alle {every} Monate": "every {every} months",
  "Recurrence|jährlich": "yearly",
  "Recurrence|alle {every} Jahre": "every {every} years",
  "Milestone|Hebt in Bauchlage kurz den Kopf":
      "Briefly lifts the head when lying on the tummy",
  "Milestone|Hält den Kopf sicher": "Holds the head steady",
  "Milestone|Dreht sich vom Rücken auf den Bauch": "Rolls from back to tummy",
  "Milestone|Sitzt frei ohne Stütze": "Sits without support",
  "Milestone|Krabbelt auf Händen und Knien": "Crawls on hands and knees",
  "Milestone|Manche Kinder lassen das Krabbeln ganz aus – das ist normal.":
      "Some children skip crawling entirely – that's normal.",
  "Milestone|Steht mit Festhalten": "Stands while holding on",
  "Milestone|Läuft an Möbeln entlang": "Cruises along furniture",
  "Milestone|Steht frei": "Stands alone",
  "Milestone|Erste freie Schritte": "First steps alone",
  "Milestone|Geht Treppen mit Festhalten": "Climbs stairs holding on",
  "Milestone|Rennt": "Runs",
  "Milestone|Springt mit beiden Beinen": "Jumps with both feet",
  "Milestone|Fährt Laufrad oder Dreirad": "Rides a balance bike or tricycle",
  "Milestone|Steht kurz auf einem Bein": "Stands briefly on one leg",
  "Milestone|Fährt Fahrrad ohne Stützräder":
      "Rides a bike without training wheels",
  "Milestone|Schwimmt (Seepferdchen)": "Swims (first swimming badge)",
  "Milestone|Greift gezielt nach Dingen": "Reaches for things on purpose",
  "Milestone|Gibt Dinge von einer Hand in die andere":
      "Passes things from one hand to the other",
  "Milestone|Pinzettengriff mit Daumen und Zeigefinger":
      "Pincer grasp with thumb and index finger",
  "Milestone|Baut einen Turm aus Klötzen": "Builds a tower of blocks",
  "Milestone|Kritzelt mit Stift": "Scribbles with a pen",
  "Milestone|Malt einen Kreis": "Draws a circle",
  "Milestone|Schneidet mit der Kinderschere": "Cuts with child scissors",
  "Milestone|Malt einen Menschen mit Kopf, Armen und Beinen":
      "Draws a person with head, arms and legs",
  "Milestone|Gurrt und macht Vokal-Laute": "Coos and makes vowel sounds",
  "Milestone|Brabbelt Silbenketten („ba-ba-ba“)":
      "Babbles syllable chains (“ba-ba-ba”)",
  "Milestone|Erstes Wort mit Bedeutung": "First word with meaning",
  "Milestone|Zweiwortsätze („Mama Auto“)": "Two-word sentences (“Mommy car”)",
  "Milestone|Spricht in kurzen Sätzen": "Speaks in short sentences",
  "Milestone|Stellt „Warum?“-Fragen": "Asks “why?” questions",
  "Milestone|Erzählt kleine Geschichten": "Tells little stories",
  "Milestone|Liest erste Wörter": "Reads first words",
  "Milestone|Erstes soziales Lächeln": "First social smile",
  "Milestone|Lacht laut": "Laughs out loud",
  "Milestone|Fremdelt": "Stranger anxiety",
  "Milestone|Winkt „Tschüss“": "Waves “bye-bye”",
  "Milestone|Als-ob-Spiel (füttert die Puppe)": "Pretend play (feeds the doll)",
  "Milestone|Spielt gemeinsam mit anderen Kindern":
      "Plays together with other children",
  "Milestone|Hat eine beste Freundin / einen besten Freund":
      "Has a best friend",
  "Milestone|Trinkt aus dem Becher": "Drinks from a cup",
  "Milestone|Isst selbst mit dem Löffel": "Eats with a spoon by themselves",
  "Milestone|Tagsüber trocken": "Dry during the day",
  "Milestone|Nachts trocken": "Dry at night",
  "Milestone|Nachts trocken zu werden dauert oft deutlich länger als tagsüber.":
      "Becoming dry at night often takes much longer than during the day.",
  "Milestone|Zieht sich allein an": "Gets dressed alone",
  "Milestone|Bindet Schuhe selbst": "Ties shoes by themselves",
  "Milestone|Erster Zahn": "First tooth",
  "Milestone|Schläft (meist) durch": "Sleeps through the night (mostly)",
  "Milestone|Erster Wackelzahn": "First loose tooth",
  "Checkup|U1 – Neugeborenen-Erstuntersuchung":
      "U1 – first newborn examination",
  "Checkup|direkt nach der Geburt": "right after the birth",
  "Checkup|U2 – Neugeborenen-Basisuntersuchung":
      "U2 – basic newborn examination",
  "Checkup|3.–10. Lebenstag": "day 3–10 of life",
  "Checkup|U3": "U3",
  "Checkup|4.–5. Lebenswoche": "week 4–5 of life",
  "Checkup|U4": "U4",
  "Checkup|3.–4. Lebensmonat": "month 3–4 of life",
  "Checkup|U5": "U5",
  "Checkup|6.–7. Lebensmonat": "month 6–7 of life",
  "Checkup|U6": "U6",
  "Checkup|10.–12. Lebensmonat": "month 10–12 of life",
  "Checkup|U7": "U7",
  "Checkup|21.–24. Lebensmonat": "month 21–24 of life",
  "Checkup|U7a": "U7a",
  "Checkup|34.–36. Lebensmonat": "month 34–36 of life",
  "Checkup|U8": "U8",
  "Checkup|46.–48. Lebensmonat": "month 46–48 of life",
  "Checkup|U9 – vor der Einschulung": "U9 – before starting school",
  "Checkup|60.–64. Lebensmonat": "month 60–64 of life",
  "Checkup|U10": "U10",
  "Checkup|7–8 Jahre": "7–8 years",
  "Checkup|U11": "U11",
  "Checkup|9–10 Jahre": "9–10 years",
  "Checkup|J1 – Jugenduntersuchung": "J1 – adolescent checkup",
  "Checkup|12–14 Jahre": "12–14 years",
  "Checkup|J2": "J2",
  "Checkup|16–17 Jahre": "16–17 years",
  "Vaccination|RSV (Antikörper-Prophylaxe)": "RSV (antibody prophylaxis)",
  "Vaccination|einmalig": "once",
  "Vaccination|Vor bzw. in der ersten RSV-Saison (meist Oktober–März).":
      "Before or during the first RSV season (usually October–March).",
  "Vaccination|Rotaviren": "Rotavirus",
  "Vaccination|1. Dosis": "1st dose",
  "Vaccination|Schluckimpfung ab 6 Wochen.": "Oral vaccine from 6 weeks.",
  "Vaccination|2. Dosis": "2nd dose",
  "Vaccination|3. Dosis": "3rd dose",
  "Vaccination|Je nach Impfstoff nötig.": "Needed depending on the vaccine.",
  "Vaccination|Sechsfach (Tetanus, Diphtherie, Keuchhusten, Hib, Polio, Hepatitis B)":
      "Six-in-one (tetanus, diphtheria, whooping cough, Hib, polio, hepatitis B)",
  "Vaccination|Pneumokokken": "Pneumococcus",
  "Vaccination|Meningokokken B": "Meningococcus B",
  "Vaccination|Masern, Mumps, Röteln, Windpocken":
      "Measles, mumps, rubella, chickenpox",
  "Vaccination|Meningokokken C": "Meningococcus C",
  "Vaccination|Für Kita und Schule ist der Masernschutz Pflicht.":
      "Measles protection is mandatory for daycare and school (Germany).",
  "Vaccination|Tetanus, Diphtherie, Keuchhusten":
      "Tetanus, diphtheria, whooping cough",
  "Vaccination|Auffrischung": "Booster",
  "Vaccination|Mit 5–6 Jahren.": "At 5–6 years.",
  "Vaccination|HPV (Humane Papillomviren)": "HPV (human papillomavirus)",
  "Vaccination|Mit 9–14 Jahren, für alle Kinder.":
      "At 9–14 years, for all children.",
  "Vaccination|Mindestens 5 Monate nach der 1. Dosis.":
      "At least 5 months after the 1st dose.",
  "Vaccination|Tetanus, Diphtherie, Keuchhusten, Polio":
      "Tetanus, diphtheria, whooping cough, polio",
  "Vaccination|Mit 9–16 Jahren.": "At 9–16 years.",
  "PregnancyWeek|ein Mohnsamen": "a poppy seed",
  "PregnancyWeek|Die Einnistung ist geschafft.": "Implantation is done.",
  "PregnancyWeek|ein Sesamkorn": "a sesame seed",
  "PregnancyWeek|Das Herz beginnt sich zu bilden.": "The heart begins to form.",
  "PregnancyWeek|eine Linse": "a lentil",
  "PregnancyWeek|Im Ultraschall ist oft schon der Herzschlag zu sehen.":
      "The heartbeat can often already be seen on the ultrasound.",
  "PregnancyWeek|eine Blaubeere": "a blueberry",
  "PregnancyWeek|Ärmchen und Beinchen knospen.":
      "Little arms and legs are budding.",
  "PregnancyWeek|eine Himbeere": "a raspberry",
  "PregnancyWeek|Finger und Zehen entstehen.": "Fingers and toes are forming.",
  "PregnancyWeek|eine Kirsche": "a cherry",
  "PregnancyWeek|Alle Organe sind angelegt.": "All organs are in place.",
  "PregnancyWeek|eine Erdbeere": "a strawberry",
  "PregnancyWeek|Aus dem Embryo wird ein Fötus.": "The embryo becomes a fetus.",
  "PregnancyWeek|eine Feige": "a fig",
  "PregnancyWeek|Das Baby bewegt sich schon – spüren kann man es noch nicht.":
      "The baby is already moving – it can't be felt yet.",
  "PregnancyWeek|eine Limette": "a lime",
  "PregnancyWeek|Das erste Drittel ist bald geschafft.":
      "The first trimester is almost done.",
  "PregnancyWeek|eine Zitrone": "a lemon",
  "PregnancyWeek|Das zweite Trimester beginnt.": "The second trimester begins.",
  "PregnancyWeek|ein Pfirsich": "a peach",
  "PregnancyWeek|Das Baby kann schon Grimassen schneiden.":
      "The baby can already make faces.",
  "PregnancyWeek|ein Apfel": "an apple",
  "PregnancyWeek|Die Haut ist noch ganz dünn.": "The skin is still very thin.",
  "PregnancyWeek|eine Avocado": "an avocado",
  "PregnancyWeek|Manche spüren jetzt erste Bewegungen.":
      "Some feel the first movements now.",
  "PregnancyWeek|eine Birne": "a pear",
  "PregnancyWeek|Fettpolster beginnen sich zu bilden.":
      "Fat pads begin to form.",
  "PregnancyWeek|eine Paprika": "a bell pepper",
  "PregnancyWeek|Das Baby hört erste Geräusche.":
      "The baby hears its first sounds.",
  "PregnancyWeek|eine Mango": "a mango",
  "PregnancyWeek|Bergfest naht!": "Halfway there soon!",
  "PregnancyWeek|eine Banane": "a banana",
  "PregnancyWeek|Halbzeit – ab jetzt wird von Kopf bis Fuß gemessen.":
      "Halfway – from now on it is measured from head to toe.",
  "PregnancyWeek|eine Karotte": "a carrot",
  "PregnancyWeek|Tritte werden kräftiger.": "Kicks get stronger.",
  "PregnancyWeek|eine Papaya": "a papaya",
  "PregnancyWeek|Das Baby erkennt Stimmen.": "The baby recognizes voices.",
  "PregnancyWeek|eine Grapefruit": "a grapefruit",
  "PregnancyWeek|Die Lunge reift.": "The lungs are maturing.",
  "PregnancyWeek|ein Maiskolben": "an ear of corn",
  "PregnancyWeek|Ab jetzt hat ein Frühchen gute Chancen.":
      "From now on a preemie has a good chance.",
  "PregnancyWeek|ein Blumenkohl": "a cauliflower",
  "PregnancyWeek|Das Baby hat einen Schlaf-Wach-Rhythmus.":
      "The baby has a sleep-wake rhythm.",
  "PregnancyWeek|ein Salatkopf": "a head of lettuce",
  "PregnancyWeek|Die Augen öffnen sich.": "The eyes open.",
  "PregnancyWeek|ein Brokkoli": "a broccoli",
  "PregnancyWeek|Das zweite Trimester endet.": "The second trimester ends.",
  "PregnancyWeek|eine Aubergine": "an eggplant",
  "PregnancyWeek|Das letzte Drittel beginnt.": "The last trimester begins.",
  "PregnancyWeek|ein Butternusskürbis": "a butternut squash",
  "PregnancyWeek|Muskeln und Lunge reifen weiter.":
      "Muscles and lungs keep maturing.",
  "PregnancyWeek|ein Kohlkopf": "a cabbage",
  "PregnancyWeek|Das Gehirn wächst schnell.": "The brain is growing fast.",
  "PregnancyWeek|eine Kokosnuss": "a coconut",
  "PregnancyWeek|Es wird eng im Bauch.": "It is getting tight in the belly.",
  "PregnancyWeek|ein Hokkaido-Kürbis": "a red kuri squash",
  "PregnancyWeek|Die meisten Babys drehen sich jetzt mit dem Kopf nach unten.":
      "Most babies turn head down now.",
  "PregnancyWeek|eine Ananas": "a pineapple",
  "PregnancyWeek|Die Knochen härten aus – bis auf den Schädel.":
      "The bones harden – except for the skull.",
  "PregnancyWeek|eine Honigmelone": "a honeydew melon",
  "PregnancyWeek|Zeit, die Kliniktasche zu packen.":
      "Time to pack the hospital bag.",
  "PregnancyWeek|eine Galiamelone": "a galia melon",
  "PregnancyWeek|Das Baby legt vor allem an Gewicht zu.":
      "The baby mainly gains weight.",
  "PregnancyWeek|ein Römersalat": "a romaine lettuce",
  "PregnancyWeek|Ab jetzt heißt es: bereit sein.": "From now on: be ready.",
  "PregnancyWeek|ein Mangold": "a bunch of chard",
  "PregnancyWeek|Ab 37+0 gilt das Baby als reif geboren.":
      "From 37+0 the baby counts as full-term.",
  "PregnancyWeek|eine Lauchstange": "a leek",
  "PregnancyWeek|Jeden Tag kann es losgehen.": "It can start any day.",
  "PregnancyWeek|eine kleine Wassermelone": "a small watermelon",
  "PregnancyWeek|Die Käseschmiere wird weniger.": "The vernix is getting less.",
  "PregnancyWeek|ein Kürbis": "a pumpkin",
  "PregnancyWeek|Der errechnete Termin ist da – nur wenige Babys kommen genau heute.":
      "The due date is here – only a few babies come exactly today.",
  "PregnancyTask|Hebamme suchen": "Find a midwife",
  "PregnancyTask|Hebammen sind oft früh ausgebucht – für Vorsorge und Wochenbett am besten gleich nach dem positiven Test anfragen.":
      "Midwives are often booked up early – best ask right after the positive test, for prenatal care and the time after the birth.",
  "PregnancyTask|1. Ultraschall-Screening": "1st ultrasound screening",
  "PregnancyTask|Mutterpass: 9+0 bis 12+6.": "Maternity record: 9+0 to 12+6.",
  "PregnancyTask|Geburtsvorbereitungskurs anmelden":
      "Sign up for a birth preparation class",
  "PregnancyTask|Der Kurs selbst liegt meist zwischen SSW 25 und 35.":
      "The class itself is usually between week 25 and 35.",
  "PregnancyTask|2. Ultraschall-Screening": "2nd ultrasound screening",
  "PregnancyTask|Mutterpass: 19+0 bis 22+6.": "Maternity record: 19+0 to 22+6.",
  "PregnancyTask|Zuckertest (Glukose)": "Glucose test",
  "PregnancyTask|Test auf Schwangerschaftsdiabetes: 24+0 bis 27+6.":
      "Test for gestational diabetes: 24+0 to 27+6.",
  "PregnancyTask|Keuchhusten-Impfung": "Whooping cough vaccination",
  "PregnancyTask|STIKO: zu Beginn des letzten Drittels – schützt das Baby in den ersten Monaten.":
      "STIKO: at the start of the last trimester – protects the baby in the first months.",
  "PregnancyTask|3. Ultraschall-Screening": "3rd ultrasound screening",
  "PregnancyTask|Mutterpass: 29+0 bis 32+6.": "Maternity record: 29+0 to 32+6.",
  "PregnancyTask|In der Geburtsklinik anmelden":
      "Register at the maternity clinic",
  "PregnancyTask|Oft mit Vorgespräch und Kreißsaalführung.":
      "Often with a preliminary talk and a delivery room tour.",
  "PregnancyTask|Kinderarzt suchen": "Find a pediatrician",
  "PregnancyTask|Für die U2 und die weiteren Vorsorgen.":
      "For the U2 and the following checkups.",
  "PregnancyTask|Kliniktasche packen": "Pack the hospital bag",
  "PregnancyTask|Siehe Checkliste.": "See the checklist.",
  "PregnancyTask|Mutterschaftsgeld beantragen": "Apply for maternity benefit",
  "PregnancyTask|Bei der Krankenkasse, mit Bescheinigung über den Termin (frühestens 7 Wochen vor ET). Mutterschutz beginnt 6 Wochen vor ET.":
      "At the health insurance, with a certificate of the due date (at the earliest 7 weeks before it). Maternity leave starts 6 weeks before the due date (Germany).",
  "ChecklistItem|Mutterpass, Versichertenkarte, Personalausweis":
      "Maternity record, insurance card, ID card",
  "ChecklistItem|Familienstammbuch bzw. Geburts-/Heiratsurkunde":
      "Family register or birth/marriage certificate",
  "ChecklistItem|Bequeme Kleidung, Bademantel, Hausschuhe":
      "Comfortable clothes, bathrobe, slippers",
  "ChecklistItem|Still-BH, Stilleinlagen, Wochenbett-Unterhosen":
      "Nursing bra, nursing pads, postpartum underwear",
  "ChecklistItem|Kulturbeutel, Haargummi, Lippenpflege":
      "Toiletry bag, hair tie, lip balm",
  "ChecklistItem|Snacks und Getränke für die Geburt":
      "Snacks and drinks for the birth",
  "ChecklistItem|Handy-Ladekabel": "Phone charger",
  "ChecklistItem|Babykleidung für die Heimfahrt (Body, Strampler, Mütze, Jäckchen)":
      "Baby clothes for the trip home (bodysuit, romper, hat, little jacket)",
  "ChecklistItem|Babyschale fürs Auto (einbauen üben!)":
      "Infant car seat (practice installing it!)",
  "ChecklistItem|Beistellbett oder Babybett mit fester Matratze":
      "Bedside crib or crib with a firm mattress",
  "ChecklistItem|Schlafsäcke (keine Decke, kein Kissen)":
      "Sleeping bags (no blanket, no pillow)",
  "ChecklistItem|Kinderwagen oder Trage": "Stroller or carrier",
  "ChecklistItem|Bodys und Strampler (Gr. 50/56 und 62)":
      "Bodysuits and rompers (sizes 50/56 and 62)",
  "ChecklistItem|Windeln, Feuchttücher oder Waschlappen":
      "Diapers, wet wipes or washcloths",
  "ChecklistItem|Wickelunterlage, Wundschutzcreme":
      "Changing pad, diaper cream",
  "ChecklistItem|Badethermometer, Kapuzenhandtuch":
      "Bath thermometer, hooded towel",
  "ChecklistItem|Fieberthermometer": "Fever thermometer",
  "ChecklistItem|Geburt beim Standesamt anzeigen (innerhalb einer Woche; oft über die Klinik)":
      "Register the birth at the registry office (within a week; often via the clinic)",
  "ChecklistItem|Baby bei der Krankenkasse anmelden":
      "Register the baby with the health insurance",
  "ChecklistItem|Kindergeld bei der Familienkasse beantragen":
      "Apply for child benefit at the family benefits office",
  "ChecklistItem|Elterngeld beantragen (rückwirkend nur 3 Monate)":
      "Apply for parental allowance (only 3 months retroactively)",
  "ChecklistItem|Arbeitgeber informieren, Elternzeit anmelden (7 Wochen vorher)":
      "Inform the employer, register parental leave (7 weeks before)",
  "ChecklistItem|Termin für die U2 (3.–10. Lebenstag)":
      "Appointment for the U2 (day 3–10 of life)",
  "ChecklistItem|Wochenbett-Hebamme bestätigen":
      "Confirm the postpartum midwife",
  "TemplateItem|Ausweise & Reisepässe": "IDs & passports",
  "TemplateItem|Krankenversichertenkarten": "Health insurance cards",
  "TemplateItem|Buchungsbestätigungen": "Booking confirmations",
  "TemplateItem|Unterwäsche & Socken": "Underwear & socks",
  "TemplateItem|Schlafanzüge": "Pajamas",
  "TemplateItem|Regenjacken": "Rain jackets",
  "TemplateItem|Badesachen": "Swimwear",
  "TemplateItem|Zahnbürsten & Zahnpasta": "Toothbrushes & toothpaste",
  "TemplateItem|Sonnencreme": "Sunscreen",
  "TemplateItem|Reiseapotheke": "Travel first aid kit",
  "TemplateItem|Ladegeräte": "Chargers",
  "TemplateItem|Kuscheltier": "Cuddly toy",
  "TemplateItem|Spiele & Bücher für die Fahrt": "Games & books for the trip",
  "TemplateItem|Snacks & Getränke": "Snacks & drinks",
  "TemplateItem|Wechselkleidung": "Change of clothes",
  "TemplateItem|Windeln & Feuchttücher": "Diapers & wet wipes",
  "TemplateItem|Matschhose & Gummistiefel": "Rain pants & rubber boots",
  "TemplateItem|Hausschuhe": "Slippers",
  "TemplateItem|Trinkflasche": "Water bottle",
  "TemplateItem|Brotdose": "Lunch box",
  "TemplateItem|Sonnenhut / Mütze": "Sun hat / cap",
  "TemplateItem|Mutterpass": "Maternity record",
  "TemplateItem|Versichertenkarte & Ausweis": "Insurance card & ID",
  "TemplateItem|Familienstammbuch / Geburtsurkunden":
      "Family register / birth certificates",
  "TemplateItem|Bequeme Kleidung & Bademantel":
      "Comfortable clothes & bathrobe",
  "TemplateItem|Still-BHs & Stilleinlagen": "Nursing bras & nursing pads",
  "TemplateItem|Hausschuhe & warme Socken": "Slippers & warm socks",
  "TemplateItem|Kulturbeutel": "Toiletry bag",
  "TemplateItem|Ladekabel": "Charging cable",
  "TemplateItem|Erstausstattung Baby": "Baby essentials",
  "TemplateItem|Mützchen & Söckchen": "Little hat & socks",
  "TemplateItem|Babyschale fürs Auto": "Infant car seat",
  "TemplateItem|Handtücher": "Towels",
  "TemplateItem|Schwimmflügel": "Water wings",
  "TemplateItem|Duschgel & Shampoo": "Shower gel & shampoo",
  "TemplateItem|Haarbürste": "Hairbrush",
  "TemplateItem|Münzen für den Spind": "Coins for the locker",
  "TemplateItem|Snacks": "Snacks",
  "TemplateItem|Zelt & Heringe": "Tent & pegs",
  "TemplateItem|Schlafsäcke & Isomatten": "Sleeping bags & sleeping mats",
  "TemplateItem|Stirnlampen": "Headlamps",
  "TemplateItem|Campingkocher & Gas": "Camping stove & gas",
  "TemplateItem|Geschirr & Besteck": "Dishes & cutlery",
  "TemplateItem|Mückenschutz": "Insect repellent",
  "TemplateItem|Erste-Hilfe-Set": "First aid kit",
  "Client|Anmeldung bei Google abgebrochen": "Google sign-in canceled",
  "Client|Google-Anmeldung fehlgeschlagen ({error})":
      "Google sign-in failed ({error})",
  "Client|Die Google-Anmeldung wurde nicht abgeschlossen":
      "The Google sign-in was not completed",
  "Client|Mit Google verbunden": "Connected with Google",
  "Client|Nicht verbunden": "Not connected",
  "Client|Du kannst dieses Fenster schließen und zu Famio zurückkehren.":
      "You can close this window and return to Famio.",
  "Client|Google-Kalender bitte in der Famio-App am Computer oder Handy verbinden.":
      "Please connect Google Calendar in the Famio app on the computer or phone.",
  "Client|Das Zertifikat des Servers passt nicht zum bestätigten. Wurde der Server neu eingerichtet? Dann die Adresse neu eingeben und den Fingerabdruck mit dem Server-Log vergleichen.":
      "The server's certificate does not match the confirmed one. Was the server set up again? Then enter the address again and compare the fingerprint with the server log.",
  "Client|Verschlüsselte Verbindung fehlgeschlagen":
      "Encrypted connection failed",
  "Client|Das ist kein Famio-Server": "This is not a Famio server",
  "Client|Upload fehlgeschlagen ({error})": "Upload failed ({error})",
  "Client|Server nicht erreichbar ({error})": "Server not reachable ({error})",
  "Client|Unerwartete Antwort vom Server (HTTP {status})":
      "Unexpected answer from the server (HTTP {status})",
  "Client|Fehler {status}": "Error {status}",
  "Server|Zu viele Fehlversuche. Bitte in {minutes} Minute(n) erneut versuchen.":
      "Too many failed attempts. Please try again in {minutes} minute(s).",
  "Server|Nicht angemeldet": "Not signed in",
  "Server|Belegt": "Busy",
  "Server|Bitte mit dem Code aus der Authenticator-App bestätigen.":
      "Please confirm with the code from the authenticator app.",
  "Server|Für dein Konto ist die Zwei-Faktor-Anmeldung Pflicht – bitte in der App einrichten.":
      "Two-factor sign-in is required for your account – please set it up in the app.",
  "Server|Für Gäste nicht verfügbar": "Not available for guests",
  "Server|Nur für Administratoren": "Only for administrators",
  "Server|Dieser Server erlaubt nur verschlüsselte Verbindungen. Bitte die https-Adresse verwenden{port}.":
      "This server only allows encrypted connections. Please use the https address{port}.",
  "Server| (im Heimnetz Port {port})": "(in the home network port {port})",
  "Server|Dieses Dienstkonto darf das nicht ändern ({access})":
      "This service account may not change that ({access})",
  "Server|Content-Type application/json erwartet":
      "Content-Type application/json expected",
  "Server|Anfrage ist zu groß": "Request is too large",
  "Server|Ungültiger JSON-Body": "Invalid JSON body",
  "Server|Ungültige Anfrage": "Invalid request",
  "Server|Benutzername ist vergeben": "Username is taken",
  "Server|Mitglied nicht gefunden": "Member not found",
  "Server|Der Name fehlt": "The name is missing",
  "Server|Es muss mindestens einen Administrator geben":
      "There must be at least one administrator",
  "Server|Geburtstag als JJJJ-MM-TT oder --MM-TT angeben":
      "Enter the birthday as YYYY-MM-DD or --MM-DD",
  "Server|Gäste können keine Administratoren sein":
      "Guests cannot be administrators",
  "Server|Dienstkonten können keine Administratoren sein":
      "Service accounts cannot be administrators",
  "Server|Bitte einen Namen angeben (höchstens 60 Zeichen)":
      "Please enter a name (at most 60 characters)",
  "Server|Benutzername: 2–32 Zeichen, nur Buchstaben, Ziffern, . _ -":
      "Username: 2–32 characters, only letters, digits, . _ -",
  "Server|Das Passwort muss mindestens 8 Zeichen haben":
      "The password must have at least 8 characters",
  "Server|Das Passwort darf höchstens 256 Zeichen haben":
      "The password may have at most 256 characters",
  "Server|Ungültige Serveradresse": "Invalid server address",
  "Server|Apple Kalender braucht HTTPS: den HTTPS-Port des Servers (FAMIO_TLS_PORT) einschalten oder die Adresse über den Reverse-Proxy verwenden.":
      "Apple Calendar needs HTTPS: turn on the server's HTTPS port (FAMIO_TLS_PORT) or use the address through the reverse proxy.",
  "Server|Apple Kalender": "Apple Calendar",
  "Server|Lege zuerst einen weiteren Administrator an oder übergib die Verwaltung.":
      "First add another administrator or hand over the administration.",
  "Server|Passwort zur Bestätigung falsch":
      "Password for confirmation is wrong",
  "Server|Bestätigungscode falsch": "Confirmation code is wrong",
  "Server|Aktuelles Passwort falsch": "Current password is wrong",
  "Server|Öffentliche Adresse": "Public address",
  "Server|Nicht eingetragen: Die Apps erreichen Famio nur im Heimnetz, und Google oder iCloud können Famio-Kalender nicht abonnieren.":
      "Not set: the apps only reach Famio in the home network, and Google or iCloud cannot subscribe to Famio calendars.",
  "Server|Server-Verwaltung → Einstellungen → Öffentliche Adresse":
      "Server administration → Settings → Public address",
  "Server|{url} ist über HTTPS erreichbar.": "{url} is reachable via HTTPS.",
  "Server|{url} antwortet dem Server nicht. Reverse-Proxy, DNS und Zertifikat prüfen (im Heimnetz kann es auch am Router liegen, der Anfragen an sich selbst nicht zurückleitet).":
      "{url} does not answer the server. Check the reverse proxy, DNS and certificate (in the home network it can also be the router, which does not route requests to itself back).",
  "Server|Reverse-Proxy (z. B. Nginx Proxy Manager)":
      "Reverse proxy (e.g. Nginx Proxy Manager)",
  "Server|Nur verschlüsselt": "Encrypted only",
  "Server|Anmeldung und Daten gehen nur über HTTPS.":
      "Sign-in and data only go over HTTPS.",
  "Server|Klartext aus dem Netz ist erlaubt (FAMIO_REQUIRE_TLS=false). Nur kurz für alte Apps nutzen.":
      "Plain text from the network is allowed (FAMIO_REQUIRE_TLS=false). Only use it briefly for old apps.",
  "Server|FAMIO_REQUIRE_TLS in der Server-Konfiguration":
      "FAMIO_REQUIRE_TLS in the server configuration",
  "Server|Schlüssel getrennt von den Daten": "Key separate from the data",
  "Server|Datenbank und Dateien sind verschlüsselt, der Schlüssel liegt woanders. Die Schlüsseldatei separat sichern!":
      "Database and files are encrypted, the key is somewhere else. Back up the key file separately!",
  "Server|Der Schlüssel liegt im Datenordner: Wer eine Sicherung hat, hat auch den Schlüssel. FAMIO_KEY_FILE auf einen anderen Ort setzen.":
      "The key is in the data folder: whoever has a backup also has the key. Put FAMIO_KEY_FILE somewhere else.",
  "Server|Die Daten sind nicht verschlüsselt.": "The data is not encrypted.",
  "Server|FAMIO_KEY_FILE in der Server-Konfiguration":
      "FAMIO_KEY_FILE in the server configuration",
  "Server|Familie eingeladen": "Family invited",
  "Server|{count} Mitglieder.": "{count} members.",
  "Server|Bisher nur du. Lade die Familie per QR-Code oder Link ein.":
      "Only you so far. Invite the family via QR code or link.",
  "Server|Server-Verwaltung → Benutzer → Mitglied hinzufügen":
      "Server administration → Users → Add member",
  "Server|Zwei-Faktor für dich": "Two-factor for you",
  "Server|Dein Admin-Konto ist mit einem zweiten Faktor geschützt.":
      "Your admin account is protected with a second factor.",
  "Server|Admins sollten einen zweiten Faktor (Authenticator-App) einrichten.":
      "Admins should set up a second factor (authenticator app).",
  "Server|Einstellungen → Anmeldung & Sicherheit":
      "Settings → Sign-in & security",
  "Server|Benachrichtigungen erreichen alle": "Notifications reach everyone",
  "Server|Jedes Mitglied bekommt Alarme und Erinnerungen aufs Handy.":
      "Every member gets alarms and reminders on their phone.",
  "Server|Noch nicht erreichbar: {names}. In deren App die Benachrichtigungen einschalten (Famio-eigene oder ntfy).":
      "Not reachable yet: {names}. Turn on notifications in their app (Famio's own or ntfy).",
  "Server|Einstellungen → Benachrichtigungen (in der jeweiligen App)":
      "Settings → Notifications (in each app)",
  "Server|Die eingebaute Sicherung ist aus (FAMIO_BACKUP_DIR=off). Dann muss Proxmox, Home Assistant oder ein anderes Werkzeug das Datenverzeichnis sichern.":
      "The built-in backup is off (FAMIO_BACKUP_DIR=off). Then Proxmox, Home Assistant or another tool must back up the data directory.",
  "Server|FAMIO_BACKUP_DIR in der Server-Konfiguration":
      "FAMIO_BACKUP_DIR in the server configuration",
  "Server|Die letzte nächtliche Sicherung ist geprüft und lässt sich wiederherstellen. Für den Ernstfall eine Kopie außer Haus aufbewahren.":
      "The last nightly backup is checked and can be restored. For emergencies, keep a copy outside the house.",
  "Server|Noch keine Sicherung – die erste entsteht heute Nacht um 3 Uhr oder mit „Jetzt sichern“.":
      "No backup yet – the first is made tonight at 3 a.m. or with “Back up now”.",
  "Server|Die letzte Sicherung ist älter als einen Tag. Fehler: {error}.":
      "The last backup is older than a day. Error: {error}.",
  "Server|keiner gemeldet": "none reported",
  "Server|Die letzte Sicherung ist noch nicht oder nicht erfolgreich geprüft.":
      "The last backup has not been checked yet or not successfully.",
  "Server|Server-Verwaltung → Status → Sicherungen":
      "Server administration → Status → Backups",
  "Server|Bundesland für Feiertage": "Federal state for public holidays",
  "Server|Feiertage und Schulferien erscheinen im Kalender.":
      "Public holidays and school holidays appear in the calendar.",
  "Server|Ohne Bundesland zeigt der Kalender keine Feiertage und Schulferien.":
      "Without a federal state the calendar shows no public or school holidays.",
  "Server|Server-Verwaltung → Einstellungen":
      "Server administration → Settings",
  "Server|Zur Bestätigung „{word}“ eingeben": "Type “{word}” to confirm",
  "Server|Passwort falsch": "Wrong password",
  "Server|Sicherungen sind ausgeschaltet (FAMIO_BACKUP_DIR=off)":
      "Backups are turned off (FAMIO_BACKUP_DIR=off)",
  "Server|Die Sicherung ist fehlgeschlagen: {error}":
      "The backup failed: {error}",
  "Server|Keine Sicherung gefunden": "No backup found",
  "Server|Du kannst dich nicht selbst löschen": "You cannot delete yourself",
  "Server|Server ist bereits eingerichtet": "Server is already set up",
  "Server|Einrichtungscode fehlt oder ist falsch. Er steht im Server-Log (z. B. docker logs famio).":
      "Setup code is missing or wrong. It is in the server log (e.g. docker logs famio).",
  "Server|Benutzername oder Passwort falsch": "Wrong username or password",
  "Server|Die Anmeldung ist abgelaufen. Bitte noch einmal mit Passwort.":
      "The sign-in has expired. Please sign in with the password again.",
  "Server|Der Code stimmt nicht": "The code is wrong",
  "Server|Zwei-Faktor ist schon eingerichtet – zum Wechseln des Handys zuerst ausschalten.":
      "Two-factor is already set up – to change phones, turn it off first.",
  "Server|Für dein Konto ist die Zwei-Faktor-Anmeldung Pflicht.":
      "Two-factor sign-in is required for your account.",
  "Server|Single Sign-On nicht verfügbar": "Single sign-on not available",
  "Server|Zuerst die öffentliche Adresse eintragen: der Anbieter leitet dorthin zurück.":
      "First enter the public address: the provider redirects there.",
  "Server|Unbekannter Umfang": "Unknown scope",
  "Server|Abo nicht gefunden": "Subscription not found",
  "Server|CalDAV nicht verfügbar": "CalDAV not available",
  "Server|Google-Anmeldung abgelaufen – bitte erneut anmelden":
      "Google sign-in expired – please sign in again",
  "Server|Kalender": "Calendar",
  "Server|Zeitraum angeben (from, to; höchstens 400 Tage)":
      "Give a period (from, to; at most 400 days)",
  "Server|Verbundener Kalender": "Connected calendar",
  "Server|Unbekannter Kalender": "Unknown calendar",
  "Server|Export fehlt": "Export missing",
  "Server|Datei ist größer als {mb} MB": "File is larger than {mb} MB",
  "Server|Datei nicht gefunden": "File not found",
  "Server|Keine Vorschau verfügbar": "No preview available",
  "Server|Einladungen fehlen": "Invitations missing",
  "Server|Diese Einladung gibt es nicht oder sie ist abgelaufen.":
      "This invitation does not exist or has expired.",
  "Server|Listen-Anbindungen fehlen": "List connections missing",
  "Server|Verbindung nicht gefunden": "Connection not found",
  "Server|Standort nicht verfügbar": "Location not available",
  "Server|Jemand": "Someone",
  "Server|{device} · Standort": "{device} · Location",
  "Server|Telefon": "Phone",
  "Server|Der Eltern-Code stimmt nicht": "The parents' code is wrong",
  "Server|Nur für Eltern (Administratoren)":
      "Only for parents (administrators)",
  "Server|Ungültiger Zeitplan": "Invalid schedule",
  "Server|Push nicht verfügbar": "Push not available",
  "Server|Nur Erwachsene": "Adults only",
  "Server|Benachrichtigungen fehlen": "Notifications missing",
  "Server|{device} · Benachrichtigungen": "{device} · Notifications",
  "Server|Benachrichtigungen funktionieren 🎉": "Notifications work 🎉",
  "Server|Notfallknopf fehlt": "Emergency button missing",
  "Server|{device} · Notruf": "{device} · Emergency",
  "Server|Position fehlt": "Position missing",
  "Server|Keine Sitzung zum Anmelden": "No session to sign in",
  "Server|Mo": "Mon",
  "Server|Di": "Tue",
  "Server|Mi": "Wed",
  "Server|Do": "Thu",
  "Server|Fr": "Fri",
  "Server|Sa": "Sat",
  "Server|So": "Sun",
  "Server|{weekday}, {day}.{month}.": "{weekday}, {month}/{day}",
  "Server|{day} ganztägig": "{day}, all day",
  "Server|{day} {hour}:{minute} Uhr": "{day} {hour}:{minute}",
  "Server|🚨 SOS von {name}": "🚨 SOS from {name}",
  "Server|{name} braucht Hilfe. Standort in Famio ansehen.":
      "{name} needs help. See the location in Famio.",
  "Server|{name} braucht Hilfe. Der Standort ist noch unbekannt.":
      "{name} needs help. The location is still unknown.",
  "Server|{name} kommt": "{name} is coming",
  "Server|{name} hat den Notfall gesehen und ist unterwegs.":
      "{name} has seen the emergency and is on the way.",
  "Server|Unbekannte Einstellung: {names}": "Unknown setting: {names}",
  "Server|Für Martin oder eine eigene Karte ist eine HTTPS-Kacheladresse nötig":
      "Martin or your own map needs an HTTPS tile address",
  "Server|Öffentliche Adresse muss mit https:// beginnen, z. B. https://famio.example.org":
      "The public address must start with https://, e.g. https://famio.example.org",
  "Server|Unbekannte Zeitzone „{text}“ (Beispiel: Europe/Berlin)":
      "Unknown time zone “{text}” (example: Europe/Berlin)",
  "Server|Kartenanbieter: osm, martin oder custom":
      "Map provider: osm, martin or custom",
  "Server|Ausblendbar sind: {names}": "Can be hidden: {names}",
  "Server|Bundesland als Kürzel, z. B. NW, BY oder BE":
      "Federal state as an abbreviation, e.g. NW, BY or BE",
  "Server|Zwei-Faktor-Pflicht: off, admins oder all":
      "Two-factor requirement: off, admins or all",
  "Server|Upload-Grenze: 1 bis {max} MB": "Upload limit: 1 to {max} MB",
  "Server|Externe Ziele brauchen eine HTTPS-Adresse ohne Zugangsdaten in der Adresse.":
      "External targets need an HTTPS address without credentials in the address.",
  "Server|Die Adresse {host} zeigt in ein privates Netzwerk. Lokale Ziele müssen vom Server ausdrücklich freigegeben werden.":
      "The address {host} points into a private network. Local targets must be allowed explicitly by the server.",
  "Server|Ungültige ID: {id}": "Invalid ID: {id}",
  "Server|Eintrag ist zu groß": "Entry is too large",
  "Server|Für dieses Konto nicht verfügbar": "Not available for this account",
  "Server|Notfall nicht gefunden": "Emergency not found",
  "Server|Der Notfall ist beendet": "The emergency has ended",
  "Server|Notfall beendet": "Emergency ended",
  "Server|Der Notfall von {name} ist beendet ({by}).":
      "{name}'s emergency has ended ({by}).",
  "Server|Gerade erst geklingelt – bitte eine Minute warten.":
      "Just rang – please wait a minute.",
  "Server|🔔 {name} sucht dich": "🔔 {name} is looking for you",
  "Server|Bitte melde dich bei {name}.": "Please get in touch with {name}.",
  "Server|Bitte einen kurzen Text": "Please a short text",
  "Server|{name} bittet um einen Check-in": "{name} asks for a check-in",
  "Server|Tippe in Famio auf „Check-in“, damit {name} weiß, wo du bist und dass alles ok ist.":
      "Tap “Check-in” in Famio so that {name} knows where you are and that everything is okay.",
  "Server|Bitte um einen Check-in": "Please check in",
  "Server|🔋 {name}s Handy hat {battery} % Akku":
      "🔋 {name}'s phone has {battery} % battery",
  "Server|Bald kann Famio {name}s Standort nicht mehr zeigen.":
      "Famio will soon no longer be able to show {name}'s location.",
  "Server|Akku fast leer": "Battery almost empty",
  "Server|Dienstkonten legt ein Admin direkt an":
      "An admin creates service accounts directly",
  "Server|Diese Einladung wurde gerade schon benutzt.":
      "This invitation has just been used.",
  "Server|Der Speicherplatz der Familie ist ausgeschöpft.":
      "The family's storage space is used up.",
  "Server|Leere Datei": "Empty file",
  "Server|Der Code braucht 4 bis 32 Zeichen ohne Leerzeichen":
      "The code needs 4 to 32 characters without spaces",
  "Server|Es ist noch kein Eltern-Code festgelegt. Ein Administrator kann ihn unter Einstellungen → Server festlegen.":
      "No parents' code has been set yet. An administrator can set it under Settings → Server.",
  "Server|Bitte die Einrichtung neu beginnen": "Please start the setup again",
  "Server|Der Code stimmt nicht. Uhrzeit von Handy und Server prüfen.":
      "The code is wrong. Check the time on the phone and the server.",
  "Server|Anbieter-Adresse muss mit https:// beginnen":
      "The provider address must start with https://",
  "Server|Client-ID fehlt": "Client ID missing",
  "Server|Client-Secret fehlt": "Client secret missing",
  "Server|Single Sign-On ist auf diesem Server nicht eingerichtet":
      "Single sign-on is not set up on this server",
  "Server|Bitte gleich noch einmal": "Please try again in a moment",
  "Server|Diese Anmeldung ist abgelaufen. Bitte in der App neu starten.":
      "This sign-in has expired. Please start again in the app.",
  "Server|Der Anbieter hat die Anmeldung abgelehnt ({error}).":
      "The provider refused the sign-in ({error}).",
  "Server|Kein Code erhalten": "No code received",
  "Server|Dieses Anmeldekonto gehört schon zu einem anderen Mitglied.":
      "This sign-in account already belongs to another member.",
  "Server|Verknüpft. Du kannst dieses Fenster schließen.":
      "Linked. You can close this window.",
  "Server|Zu diesem Anmeldekonto gibt es kein Famio-Konto. Zuerst in der App anmelden und unter Einstellungen → Anmeldung & Sicherheit „Single Sign-On verknüpfen“.":
      "There is no Famio account for this sign-in account. First sign in in the app and choose “Link single sign-on” under Settings → Sign-in & security.",
  "Server|Angemeldet. Du kannst dieses Fenster schließen und zu Famio zurückkehren.":
      "Signed in. You can close this window and return to Famio.",
  "Server|Anmeldung abgelaufen. Bitte neu starten.":
      "Sign-in expired. Please start again.",
  "Server|Anbieter antwortet nicht wie erwartet (HTTP {status} für {url})":
      "The provider does not answer as expected (HTTP {status} for {url})",
  "Server|Anbieter nicht erreichbar ({url}): {error}":
      "Provider not reachable ({url}): {error}",
  "Server|Unvollständige OpenID-Konfiguration ({key})":
      "Incomplete OpenID configuration ({key})",
  "Server|Anbieter nicht erreichbar: {error}":
      "Provider not reachable: {error}",
  "Server|Der Anbieter hat den Code nicht angenommen (HTTP {status}). Client-ID, Secret und Weiterleitungs-Adresse prüfen.":
      "The provider did not accept the code (HTTP {status}). Check client ID, secret and redirect address.",
  "Server|Kein ID-Token erhalten": "No ID token received",
  "Server|Ungültiges ID-Token": "Invalid ID token",
  "Server|ID-Token ungültig (Aussteller, Empfänger, Ablauf oder nonce)":
      "ID token invalid (issuer, audience, expiry or nonce)",
  "Server|Bitte die HTTPS-Adresse des ntfy-Themas angeben, z. B. https://ntfy.sh/famio-geheimer-name":
      "Please enter the HTTPS address of the ntfy topic, e.g. https://ntfy.sh/famio-secret-name",
  "Server|Höchstens 10 Geräte": "At most 10 devices",
  "Server|Gerät": "Device",
  "Server|Gerät nicht gefunden": "Device not found",
  "Server|Push-Benachrichtigungen funktionieren 🎉":
      "Push notifications work 🎉",
  "Server|Neuer Check-in": "New check-in",
  "Server|Neue Ortsmeldung": "New place notification",
  "Server|Anhang": "Attachment",
  "Server|{name} · Familie": "{name} · Family",
  "Server|Neue Nachricht": "New message",
  "Server|Neue Aufgabe für dich": "New task for you",
  "Server|Kommentar zu „{title}“": "Comment on “{title}”",
  "Server|Neuer Kommentar zu einem Termin": "New comment on an event",
  "Server|Neuer Termin: {title}": "New event: {title}",
  "Server|Neuer Termin für dich": "New event for you",
  "Server|{name} wünscht sich: {title} ({points} Punkte)":
      "{name} wishes for: {title} ({points} points)",
  "Server|Bitte bestätigen": "Please confirm",
  "Server|Eine Anfrage bei den Ämtern wartet": "A chores request is waiting",
  "Server|Bestätigt 👍": "Confirmed 👍",
  "Server|Leider abgelehnt": "Unfortunately declined",
  "Server|{title} ({sign}{points} Punkte)": "{title} ({sign}{points} points)",
  "Server|Deine Anfrage wurde bestätigt": "Your request was confirmed",
  "Server|Deine Anfrage wurde abgelehnt": "Your request was declined",
  "Server|Push-Server antwortet {status}": "Push server answers {status}",
  "Server|Push-Server nicht erreichbar": "Push server not reachable",
  "Server|Listen-Anbindungen sind in der Server-Verwaltung ausgeschaltet.":
      "List connections are turned off in the server administration.",
  "Server|Die Client-ID (Anwendungs-ID) hat die Form 00000000-0000-0000-0000-000000000000.":
      "The client ID (application ID) has the form 00000000-0000-0000-0000-000000000000.",
  "Server|Anmeldung nicht gefunden": "Sign-in not found",
  "Server|Bring! kennt nur Einkaufslisten.":
      "Bring! only knows shopping lists.",
  "Server|Diese Einkaufsliste gibt es nicht.":
      "This shopping list does not exist.",
  "Server|Keine Verbindung zu {provider}.": "No connection to {provider}.",
  "Server|die Famio-Liste gibt es nicht mehr":
      "the Famio list no longer exists",
  "Server|Famio {famio}, dort {remote} Einträge; {sent} gesendet, {taken} übernommen, {deleted} gelöscht":
      "Famio {famio}, there {remote} entries; {sent} sent, {taken} taken over, {deleted} deleted",
  "Server|Bring! hat E-Mail-Adresse oder Passwort nicht angenommen.":
      "Bring! did not accept the email address or password.",
  "Server|Bring! antwortet mit Fehler {status}.":
      "Bring! answers with error {status}.",
  "Server|Die Anmeldung bei Bring! ist abgelaufen. Bitte neu verbinden.":
      "The Bring! sign-in has expired. Please connect again.",
  "Server|Bring! hat die Liste in einem unbekannten Format geliefert (Felder: {fields}).":
      "Bring! delivered the list in an unknown format (fields: {fields}).",
  "Server|Microsoft lehnt die Anmeldung ab: {error}. Stimmt die Client-ID, und sind öffentliche Clients erlaubt?":
      "Microsoft refuses the sign-in: {error}. Is the client ID right, and are public clients allowed?",
  "Server|Der Code ist abgelaufen. Bitte neu beginnen.":
      "The code has expired. Please start again.",
  "Server|Microsoft hat die Anmeldung nicht bestätigt ({error}).":
      "Microsoft did not confirm the sign-in ({error}).",
  "Server|Die Anmeldung bei Microsoft ist abgelaufen. Bitte neu verbinden.":
      "The Microsoft sign-in has expired. Please connect again.",
  "Server|Microsoft hat den Zugriff abgelehnt. Bitte neu verbinden.":
      "Microsoft refused access. Please connect again.",
  "Server|Microsoft To Do antwortet mit Fehler {status}.":
      "Microsoft To Do answers with error {status}.",
  "Server|Zugriff verweigert (HTTP {status}). Ist es die geheime/öffentliche ICS-Adresse?":
      "Access denied (HTTP {status}). Is it the secret/public ICS address?",
  "Server|Kalender nicht gefunden (HTTP 404)": "Calendar not found (HTTP 404)",
  "Server|Abruf fehlgeschlagen (HTTP {code})": "Fetching failed (HTTP {code})",
  "Server|Unter dieser Adresse liegt keine Kalenderdatei (ICS)":
      "There is no calendar file (ICS) at this address",
  "Server|Zeitüberschreitung beim Abruf": "Timeout while fetching",
  "Server|Server nicht erreichbar ({message})":
      "Server not reachable ({message})",
  "Server|Ungültige Adresse oder Daten: {message}":
      "Invalid address or data: {message}",
  "Server|Import fehlgeschlagen: {error}": "Import failed: {error}",
  "Server|Adresse muss mit https:// oder webcal:// beginnen":
      "The address must start with https:// or webcal://",
  "Server|Kalenderdatei ist größer als 10 MB":
      "The calendar file is larger than 10 MB",
  "Server|Zu viele Weiterleitungen beim Kalenderabruf":
      "Too many redirects while fetching the calendar",
  "Server|Bitte einen Namen angeben": "Please enter a name",
  "Server|Zeitüberschreitung bei {host}": "Timeout at {host}",
  "Server|{host} nicht erreichbar ({message})":
      "{host} not reachable ({message})",
  "Server|Verschlüsselung zu {host} fehlgeschlagen (Zertifikat?)":
      "Encryption to {host} failed (certificate?)",
  "Server|Verbindung zu {host}: {message}": "Connection to {host}: {message}",
  "Server|Antwort von {host} ist zu groß": "Answer from {host} is too large",
  "Server|Anmeldung bei {host} fehlgeschlagen – Benutzername oder (App-)Passwort prüfen":
      "Sign-in at {host} failed – check the username or (app) password",
  "Server|Zu viele Weiterleitungen": "Too many redirects",
  "Server|Unerwartete Antwort von {host} (HTTP {status})":
      "Unexpected answer from {host} (HTTP {status})",
  "Server|Keine Kalender gefunden": "No calendars found",
  "Server|Unter dieser Adresse wurde kein CalDAV-Konto gefunden":
      "No CalDAV account was found at this address",
  "Server|Termin konnte nicht gespeichert werden (HTTP {status})":
      "Event could not be saved (HTTP {status})",
  "Server|Termin konnte nicht gelöscht werden (HTTP {status})":
      "Event could not be deleted (HTTP {status})",
  "Server|Ungültige Antwort des Kalenderservers":
      "Invalid answer from the calendar server",
  "Server|Google hat keinen dauerhaften Zugang erteilt. Bitte die Verbindung unter myaccount.google.com → Sicherheit → Drittanbieter-Apps entfernen und erneut anmelden.":
      "Google did not grant lasting access. Please remove the connection under myaccount.google.com → Security → Third-party apps and sign in again.",
  "Server|Google verweigert den Zugriff: Im Cloud-Projekt „Google Calendar API“ und „CalDAV API“ aktivieren.":
      "Google refuses access: enable “Google Calendar API” and “CalDAV API” in the cloud project.",
  "Server|Kalenderliste von Google nicht abrufbar (HTTP {status})":
      "Calendar list from Google not available (HTTP {status})",
  "Server|Google antwortet nicht": "Google does not answer",
  "Server|Google nicht erreichbar: {message}":
      "Google not reachable: {message}",
  "Server|Der Google-Zugang ist abgelaufen oder wurde widerrufen – bitte neu anmelden. (Im Cloud-Projekt den Veröffentlichungsstatus auf „In Produktion“ stellen, sonst endet er nach 7 Tagen.)":
      "The Google access has expired or was revoked – please sign in again. (In the cloud project, set the publishing status to “In production”, otherwise it ends after 7 days.)",
  "Server|Client-ID oder Client-Secret stimmt nicht":
      "Client ID or client secret is wrong",
  "Server|Google-Anmeldung fehlgeschlagen ({error})":
      "Google sign-in failed ({error})",
  "Server|Keine Kalender für Termine gefunden": "No calendars for events found",
  "Server|Benutzername und Passwort angeben": "Enter username and password",
  "Server|Abgleich fehlgeschlagen: {error}": "Sync failed: {error}",
  "Server|Kein Termin (VEVENT) enthalten": "Contains no event (VEVENT)",
  "Server|Bitte eine Adresse wie https://caldav.icloud.com angeben":
      "Please enter an address like https://caldav.icloud.com",
  "Server|Anmeldung mit Benutzername und App-Passwort nötig":
      "Sign-in with username and app password needed",
  "Server|Ungültiges XML": "Invalid XML",
  "Server|Termine der Familie aus Famio": "The family's events from Famio",
  "Server|Aufgaben der Familie aus Famio": "The family's tasks from Famio",
  "Server|Einkauf": "Shopping",
  "Server|Einkaufsliste aus Famio": "Shopping list from Famio",
  "Server|Leere Anfrage": "Empty request",
  "Server|{reason} – bitte den Termin in Famio anlegen.":
      "{reason} – please create the event in Famio.",
  "Server|Nicht unterstützt": "Not supported",
  "Server|Diese Liste nimmt nur Aufgaben (VTODO) an.":
      "This list only accepts tasks (VTODO).",
  "Server|famio.db fehlt": "famio.db missing",
  "Server|famio.db beschädigt: {check}": "famio.db damaged: {check}",
  "Server|famio.db lässt sich mit dem Datenschlüssel nicht öffnen ({message})":
      "famio.db cannot be opened with the data key ({message})",
  "Server|Keine Mitglieder in der Sicherung": "No members in the backup",
  "Server|files.db beschädigt: {check}": "files.db damaged: {check}",
  "Server|1 Datei ohne Inhalt in files.db":
      "1 file without content in files.db",
  "Server|{missing} Dateien ohne Inhalt in files.db":
      "{missing} files without content in files.db",
  "Server|files.db lässt sich mit dem Datenschlüssel nicht öffnen ({message})":
      "files.db cannot be opened with the data key ({message})",
  "Server|Deutlich weniger Einträge als jetzt ({records} statt {live}) – seit der Sicherung kam viel dazu, oder es fehlt etwas.":
      "Far fewer entries than now ({records} instead of {live}) – a lot was added since the backup, or something is missing.",
  "Server|Sicherung läuft bereits": "Backup is already running",
  "Server|Zu wenig Speicherplatz für die Sicherung: frei {free} MB, nötig etwa {needed} MB":
      "Not enough space for the backup: {free} MB free, about {needed} MB needed",
  "Server|Nur über die Seitenleiste von Home Assistant.":
      "Only through the Home Assistant sidebar.",
  "Server|Der Famio-Server ({upstream}) ist nicht erreichbar.":
      "The Famio server ({upstream}) is not reachable.",
  "Server|Der Server läuft. Verbinde die Famio-App mit dieser Adresse:":
      "The server is running. Connect the Famio app to this address:",
  "Server|Hallo {name}!": "Hello {name}!",
  "Server|Die Famio-App verbindest du mit:": "Connect the Famio app to:",
  "Server|Benutzername:": "Username:",
  "Server|Passwort ändern": "Change password",
  "Server|Passwort für die App festlegen": "Set a password for the app",
  "Server|Gespeichert.": "Saved.",
  "Server|Aktuelles Passwort": "Current password",
  "Server|Neues Passwort (min. 8 Zeichen)": "New password (min. 8 characters)",
  "Server|Speichern": "Save",
  "Server|Port in den Add-on-Einstellungen änderbar":
      "Port can be changed in the add-on settings",
  "Server|← Zurück zu Famio": "← Back to Famio",
  "Server|Famio im Browser öffnen": "Open Famio in the browser",
  "Server|Konto löschen": "Delete account",
  "Server|Famio-Konto löschen": "Delete Famio account",
  "Server|Du kannst dein Famio-Konto selbst löschen. Dabei werden Zugang, Sitzungen und persönliche Verbindungen entfernt; gemeinsam genutzte Familieneinträge bleiben für die anderen Mitglieder erhalten.":
      "You can delete your Famio account yourself. This removes the access, sessions and personal connections; shared family entries stay for the other members.",
  "Server|Bei Famio anmelden und Konto löschen":
      "Sign in to Famio and delete the account",
  "Server|Bitte Famio im Browser oder in der App öffnen und unter Einstellungen → Mein Konto löschen fortfahren.":
      "Please open Famio in the browser or in the app and continue under Settings → Delete my account.",
  "Server|Zur Bestätigung brauchst du dein Passwort und, falls aktiviert, deinen Zwei-Faktor-Code. Als letzter Administrator musst du die Verwaltung zuerst an ein anderes Mitglied übertragen.":
      "To confirm, you need your password and, if enabled, your two-factor code. As the last administrator, you must first hand over the administration to another member.",
};
