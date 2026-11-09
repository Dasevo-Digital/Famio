# What's new in Famio?

The most important things of each version in a few lines. The app shows
its version's section once after an update; the detailed release notes are
with the releases.

## 2.0.44 – Drinks at a glance

- In the log's week and month view, a new card shows how much was drunk, on
  how many days and what: water, tea and so on.
- The history can now show drinks per day as well.

## 2.0.43 – Pee, poo and foot length

- The log has separate buttons for pee, poo and pee + poo. Pee takes a single
  tap; after poo Famio asks about the stool as before.
- Measurements now also record the foot length, with its own growth chart.
- The “Weight” button is now called “Measure”.

## 2.0.42 – Drinks and walks

- New in the log: drinks with type and amount. The overview counts them apart
  from milk.
- Walks run as a timer like sleep; the overview shows the time outdoors.
- With large text the quick buttons no longer break words in the middle, and
  the sleep and breastfeeding cards stay readable.
- Older apps show drinks and walks as a symptom. Please update all devices.

## 2.0.41 – Stool colour and photos in the log

- After “poo” Famio now asks for amount, consistency and colour. Every answer
  is optional; the sheet closes after the third.
- The colours include “pale/grey”.
- Every log entry can carry photos, for example of a rash for the doctor. This
  needs an up-to-date server.

## 2.0.40 – Diapers and stool

- The log now calls diapers pee, poo and pee + poo.
- You can rate the stool: hard, formed, soft or diarrhoea. After “poo” Famio
  asks right away; the answer is optional.
- The daily and weekly summaries show how often there was diarrhoea.
- With large text, the log editor and the children's cards fit on the screen
  again.

## 2.0.39 – The photo stays with the event

- Importing from photos keeps title and place apart: the place no longer becomes
  the title, and places below the date are recognised.
- The photo, scan or PDF stays attached to the event, so you can check it. A tick
  in the import turns this off.
- Events can now carry photos and files. This also needs an up-to-date server.
- On phones the import offers “Scan a document”.

## 2.0.38 – Edit recognised appointments

- Appointments from photos and texts can be edited in the event form before
  they are added: with the pencil on the suggestion, including date, time,
  place and people.
- Tables and lists of dates are read line by line.
- The place comes along from lines like “Where: Hall”.
- Sentences across several lines and dates like “Di 24.11” are recognised, and
  titles are tidier.
- Dates in the past, such as the date of a letter, are no longer preselected.

## 2.0.37 – Appointments from photos

- Invitations, school letters and doctor's cards: Famio now finds the date,
  time and title even when they stand on lines of their own.
- Dates with spaces like “13. 11. 2026” are recognised.
- iPhone: photos taken upright are read in the right order.

## 2.0.36 – Recipes come in more easily

- The recipe import now also takes the photo from Chefkoch and similar sites.
- Android: “Share to Famio” imports a link as a recipe right away. Everywhere
  this works from the family inbox, and the import has a button to paste the
  copied link.
- While editing, a recipe shows its photo. It can be removed, and older recipes
  can get theirs from the source.
- The chat counts unread messages faster.

## 2.0.35 – Tiles, salary and recipe photos

- Server administration → Areas now lets you hide each tile of the start page
  on its own. The area stays in the menu.
- Money: salary from the 15th on counts for the next month, so the salary of
  28 October shows in November. “Counts for the next month” changes this per
  booking, for other income too.
- Recipes show their photo again. The same went for “One year ago today”, the
  year in review and the slideshow.
- The recipe import also takes over the page's photo.

## 2.0.34 – Health data better protected

- New: app lock under Settings → This device. Famio then asks for your
  fingerprint, face or device PIN (Android, iPhone, iPad, Mac).
- Health data only goes to adults and people chosen for it, never to Home
  Assistant or the wall display. Children only see it if they are chosen.
- Only adults change medication plans and child profiles; children can
  still tick off doses.
- Medications with nobody chosen stay private, and new health documents
  start as "Only me".
- Guests and children only see confidential events they take part in. The
  widget, wall display and notifications show no title.
- With "Show contents" off, reminders give nothing away either.
- When an account is deleted, its own health data goes with it.

## 2.0.33 – Quick add

- The start page has "Quick add": a line like "Thursday 4 pm dentist",
  "tomorrow take out the bins" or "in 3 days pick up the parcel" becomes
  an event or a task. The editor opens filled in; you check it and save.
- If the line can mean two days ("next Thursday"), Famio asks which one
  first.
- It also works in German and Spanish and is read on the device only.

## 2.0.32 – "That wasn't me" and Android back

- Under Settings → My devices, new sign-ins show "That wasn't me": Famio
  signs that device out and opens "Change password".
- Android: the back button first closes the open page, then goes to the
  start page. Until now it closed Famio right away.
- Android: sharing something from another app to Famio no longer opens a
  second Famio; it arrives in the running app.
- When a device is signed out from elsewhere, open windows close cleanly
  instead of showing an error.
- A changed family time zone reaches all apps at once.
- On computers, no further notifications arrived once the system could
  not show one (for example Linux without a notification service).
- With German or Spanish on a phone set to 12 hours, a time like 16:30
  could not be typed in. Now it can.
- The school bag card and input dialogs behave more reliably.

## 2.0.31 – Location in Home Assistant without jumps

- The Famio location in Home Assistant now changes only with a new
  position. Until now a new battery report made an old Famio position the
  newest again, and a person jumped back and forth between zones.
- Battery and location sharing are separate sensors per member instead.

## 2.0.30 – Calendar sync without hangs

- If a CalDAV calendar server gets stuck while answering, Famio syncs again
  next time instead of stopping until a restart.
- Importing a recipe from a web page gives up after 20 seconds without an
  answer.

## 2.0.29 – Limited waiting times

- The server fetches the app packages of a new version even when the
  connection to GitHub hangs in between.
- Documents from Paperless-ngx and pictures from PhotoVault report an error
  instead of loading forever when the service does not answer.
- If Paperless-ngx has more than 5,000 documents with the tag, Famio says
  so.

## 2.0.28 – Paperless-ngx and PhotoVault more reliable

- If Paperless-ngx or PhotoVault is disconnected while a sync is running,
  its documents or photos no longer stay behind.
- Changed settings apply right away, even while a sync was running.
- Documents from Paperless-ngx open even when Paperless-ngx sends no file
  size.

## 2.0.27 – Documents from Paperless-ngx

- An admin can connect their own Paperless-ngx (Server administration →
  Settings → Paperless-ngx). Documents with the chosen tag appear
  read-only under Documents.
- The expiry reminder comes from a date field the admin names, for
  example “Expiry date”.
- An existing connection to PaperBuddy is kept.

## 2.0.26 – Security update for connections

- Famio no longer trusts compromised intermediate certificates of the
  eMudhra certificate authority; on Android 14 and later it uses the
  system's updatable certificates for this. This applies to the app and
  the server.
- Small updates, among others for picking files.

## 2.0.25 – More robust list sync

- Bring! and Microsoft To Do: a hanging connection is aborted after
  20 seconds instead of running on in the background. After a connection
  error Famio asks once more.
- If the service cannot be reached at all, the account shows "No
  connection" instead of "did not respond in time".
- A short network problem no longer cancels signing in to Microsoft.

## 2.0.24 – More reliable offline copies

- After an upload Famio only keeps a file offline if the copy matches the
  uploaded content exactly. If the file changes meanwhile, it is loaded
  from the server when opened.
- Clearing the file storage while a copy is being made no longer leaves a
  half-written entry; incomplete offline copies are detected and loaded
  again.
- An offline copy that hangs no longer holds up the upload.
- The server keeps the name, type and size of attached files consistent
  and corrects wrong details from older versions once. Files with a wrong
  size can be opened again.

## 2.0.23 – Large files, time zones and export

- Large files can be opened and uploaded up to the server's limit; Famio
  loads them piece by piece instead of all at once into memory. In the
  browser the limit is 128 MB.
- The data export is written straight to a file, shows its progress and
  can be cancelled.
- Calendar, home screen, wall display and daily overview use the family's
  time zone, even when a device is set to another one.
- A calendar subscription that hangs no longer holds up the others, and
  no copy of the data stays in the browser after signing out.

## 2.0.22 – Trash and confirmed responsibilities

- Trash (Settings): deleted tasks, events, notes and documents can be
  restored for 30 days, from another device too. This needs a connection
  to the server.
- For tasks and drop-offs or pick-ups you can ask the person in charge to
  confirm explicitly (“I will do it” / “I cannot do it”). In a series of
  events each trip is confirmed on its own; if you like, Famio reminds
  about an open confirmation.

## 2.0.21 – Reminders on iPhone and iPad, safer sync

- Reminders now reach iPhone and iPad too; Famio asks once for permission
  to send notifications.
- If the server cannot accept a change because an attachment is no longer
  shared, it stays on the device: the sync icon shows “Review changes”,
  everything else keeps syncing.
- Files can only be reached through real attachments, and a QR code for
  pairing expires when the approving device signs out.
- Vaccination schedule, ultrasound appointments and fever advice for
  children up to two years follow the current recommendations.
- Better contrast and a date picker that also fits narrow phones.

## 2.0.19 – Steadier in the background

- An error a background job misses no longer stops the server; it is
  logged and Famio keeps running.
- iPhone and iPad show up in the device list with their model instead of
  “localhost”.

## 2.0.18 – Gift ideas, loans and the school bag

- Gift ideas: on someone else's wish list you note ideas for a birthday or
  Christmas; that person never sees them.
- Lent & borrowed (Settings): who has what of yours and you of theirs,
  with a reminder on the day it is due back.
- School bag check: note in the timetable what each subject needs; the
  evening before, Famio lists tomorrow's subjects and things.
- Documents are also found by their content: when adding one, the device
  reads the text of a PDF or photo.
- During an absence, the stand-in also sees tasks only some may see.
- iPhone (installed from the Mac): Famio tells you in time when it has to
  be reinstalled.

## 2.0.17 – Inbox, stand-ins and pairing a device

- The family inbox on the start page collects what has no place yet (texts,
  links, files, also via “Share to Famio”); later it becomes a task, an
  event, a note, a document or a shopping item.
- Absences with a stand-in: while someone is away, another person takes
  over their chores and tasks (Chores → Absences).
- A new device signs in with a QR code from a signed-in device, without a
  password (there Settings → QR icon “Pair a new device”, on the new one “Pair an
  existing account”).
- Large data exports are more reliable, and Bring!/Microsoft To Do no
  longer get stuck.

## 2.0.16 – No more duplicate entries

- Adding something again that is still ticked off on the list brings that
  entry back; if it is still open, Famio says so instead of adding it twice.
- Lists connected to Bring! no longer get duplicate entries; existing ones
  are merged during the sync.

## 2.0.15 – Private shopping lists and appearance

- Each shopping list can be limited to certain people (list menu → “Who
  sees the list?”). Nobody else sees its items either.
- Light, dark or like the system: under Settings → This device →
  Appearance.

## 2.0.14 – Photos in full quality, more reliable location

- The photo viewer shows a preview first, then the original in full
  sharpness, also when zoomed.
- Photos from PhotoVault come in full size in the viewer and on the wall
  display instead of as a small thumbnail.
- If a phone has not reported for a day, “Who is where?” says so
  clearly; after two days the adults get a notice.
- Somebody far away now leaves “Home” even when the phone only sends
  imprecise positions.

## 2.0.13 – Viewing photos in Famio

- Tapping a photo opens it in Famio instead of as a download or in another
  app: swipe on, zoom and use the arrow keys. The button at the top right
  still hands on the original.
- If the library of the connected PhotoVault account is empty, the setting
  now says so and suggests the account the photos belong to.

## 2.0.12 – Random photos on the wall display

- The wall display can show random photos from the whole PhotoVault
  timeline, 100 new ones every three hours (Server administration →
  Settings → PhotoVault → Photos for the wall display).
- The slideshow takes new photos right away instead of keeping the old
  selection.
- Famio's description in HACS shows its pictures and links again.

## 2.0.11 – PhotoVault, staples and memories

- PhotoVault can be connected (Server administration → Settings): photos of
  the day in "One year ago today", an album on the wall display, chat
  photos as contributions to a PhotoVault link, and birthdays from the
  family tree if they are not noted anywhere yet.
- "One year ago today" on the start page shows milestones, trips and photos
  of the same day in earlier years.
- The shopping list suggests what you buy often. Staples with a rhythm go
  back on the list by themselves. The list can be shared as text.
- Photograph the receipt and the amount goes into the budget.
- Home Assistant automations send messages to the family chat or to single
  people.
- The web app can keep its data encrypted in the browser and then starts
  faster (Settings → This device).

## 2.0.10 – Android starts again

- On Android, Famio 2.0.8 and 2.0.9 stayed white after starting. This is
  fixed. If you have one of these versions, install 2.0.10 once by hand,
  because the app could not offer the update itself.
- Home Assistant shows the Famio icon for the integration and in the add-on
  store.

## 2.0.9 – Week plan, contracts and savings goals

- The calendar prints a week plan for the fridge (printer icon):
  appointments, meals, chores and bins, one row per day.
- "Suggest the week" in the meal plan fills the free days from your
  favourite recipes, without repeating the last two weeks and with what the
  pantry has. After shopping, "Paid? Amount into the budget" adds the amount
  as an expense.
- Deadlines know contracts and subscriptions: Famio reminds you before the
  last day to cancel, and the monthly amount can go into the budget.
- Children set savings goals in their pocket money account and see when
  they will have enough.
- For appointments at family places, Famio reminds you when to leave
  (Settings → Push notifications).
- Adults can store their own emergency information (Settings → My emergency
  info); during an SOS alarm the other adults see it.
- Calendar apps keep the colour and order of the Famio calendars.

## 2.0.8 – Holidays, free times and a web app with notifications

- Holiday mode: enter a period under Chores → Holidays. Chores and routines
  are not due then, nobody is reminded of the bins, and pocket money can be
  skipped too.
- "When is everyone free?" in the calendar suggests free times in the next
  two weeks. One tap creates the appointment.
- "On my way" under Who is where?: pick a destination, the family learns the
  approximate arrival.
- When a new app version is out, members with older Android, Windows and
  Linux devices are told once.
- The web app loads faster, can show notifications even without an open
  tab (Settings → Push notifications) and can sign in with a passkey
  (Sign-in & security). Recipes can now be imported there too.
- On a computer, files can be dragged into the Famio window: as a task,
  document or into the chat, calendar files into the import.

## 2.0.7 – Cooking mode and sharing to Famio

- Recipes have a cooking mode: step by step, the screen stays on, times in
  the text start a timer with one tap.
- On Android, text, links, photos and files from other apps can be shared to
  Famio: to the shopping list, as a task, note or document, or to the chat.
- If you like, a daily overview arrives every morning with appointments,
  tasks, bins and weather (Settings → Push notifications).
- Places can be marked as a shop: whoever arrives there gets the open
  shopping items.
- Passwords that are easy to guess are refused; two-factor sign-in can now
  be required for all adults, too.
- The Android update for 64-bit phones is about 32 MB; appointments from
  photos and the barcode scanner then load their recognition once through
  Google Play.
- Around the clock change on October 25, nothing slips to the day before or
  after anymore.

## 2.0.6 – Scan documents

- Every file picker offers "Scan a document": the pages become a PDF on
  the phone, for example for documents or tasks.
- If someone signs in to your account on another device, your other
  devices get a notification.
- The task editor is shorter. Checklist, files and "Who may see it?" sit
  behind a button.
- The web app no longer loads fonts from Google.
- Updates through the server are about 40% smaller on 64-bit Android
  phones.
- Chores, pocket money paydays and the age in months are correct around
  the daylight saving time change, too.

## 2.0.5 – Nicer Android widgets

- "Famio today" shows the logo and date at the top and each row in the
  color of its area, in a dark design when the phone is dark.
- The emergency button has a gradient and fits every cell size.

## 2.0.4 – Files on tasks

- Besides photos, tasks can now have PDFs and other files, such as a form
  or instructions.
- In "Who is where?" adults can hide members without a phone, for the
  whole family. "Hidden" brings them back.
- After an update the web app loads the new version right away.

## 2.0.3 – Tasks for several people

- A task can belong to several people. Each gets the reminder and finds
  the task under "Mine".
- Under "Who may see it?" a task can be limited to you or selected
  people. Whoever takes care of it always sees it.
- Guests now only see tasks assigned or shown to them.
- The map in the web app loads again.

## 2.0.2 – Tips and setup

- On the first visit to an area, a short tip explains what is easy to
  miss there. "No more tips" turns them off, the settings turn them back
  on.
- Single points of the setup checklist can be ignored and shown again.
- Server administration shows what is set up for single sign-on,
  PaperBuddy and app updates, and then offers "Change".
- Logo and side bar stay sharp in a large window on screens without Retina
  resolution, for example over remote desktop.
- Server monitoring now also reports when a backup is missing.

## 2.0.1 – Photos on tasks

- All adults now see a newly added child. Anyone who does not see a child
  gets a hint instead of adding it a second time.
- Tasks can have photos, from the camera or the gallery.
- A child's log shows a day, a week or a month and goes back in time, with
  the average per day.
- An app older than the server says so on the start page. Administrators
  see the version on every device.

## 2.0.0 – Updates from your own server

- New versions for Android, Windows and Linux now come through the Famio
  server: a notice on the start page downloads, checks and installs them.
  Administrators turn this on under "App updates through the server".
- Take over calendar files (.ics): under "Recognize events" or straight
  from mail and files with "Open with Famio", on every device. Series stay
  series, a second import updates instead of duplicating.
- A short tour shows the most important areas. It is offered once on the
  start page and is always available in the settings.
- On Windows and Linux Famio now runs only once; starting it again brings
  the open window to the front.
- The Home Assistant integration can be installed through HACS.
- The setup checklist recognizes the public address also behind routers
  without hairpin NAT and only counts members with the app for
  notifications.
- The logo at the top left stays sharp in large windows.

## 1.0.16 – Development up to adulthood

- For children, stages of development explain what is going on: from what
  a newborn sees and hears through the terrible twos to puberty.
- Many new milestones up to adulthood, such as fontanelles, teeth,
  thinking and puberty – matching the sex in the child's profile.

## 1.0.15 – Easier-to-read colours

- Text, buttons and badges in the colours of each area are now easy to read
  even without “High contrast”. Icons and tiles stay colourful.
- Initials on coloured member circles are white or dark, whichever is
  easier to read.

## 1.0.14 – Events recognised in three languages

- “Recognise events” now also reads English and Spanish dates and times,
  such as “October 16 at 7 pm” or “16 de octubre a las 19:00”.
- Suggested titles come without weekdays and filler words.

## 1.0.13 – More connections

- Steps of tasks appear in Apple Reminders as subtasks and in Microsoft
  To Do as steps.
- Add shortages from PreppSuite to the shopping list (shopping list → ⋮).
- Import a bank statement into the budget (CSV or CAMT, read on the device
  only).
- Nutrition per serving for recipes from Open Food Facts.
- Documents from PaperBuddy with their deadlines under Documents.
- Year in review with numbers, milestones, trips and photos, also as a
  PDF.
- Home Assistant: sensors for chores, the next waste collection and the
  countdown.

## 1.0.12 – English and Spanish

- Famio now speaks English and Spanish too. The app follows the device
  language; you can choose one under Settings → Language.
- Notifications arrive in the language of each phone.
- After an update the app shows once what's new; any time under
  Settings → “What's new?”.
- Android: “Famio emergency” widget for the home screen.
- For admins, the start page shows a checklist until the setup is
  finished.
- Larger tap targets, better use with large text and with the screen
  reader.

## 1.0.11 – Safer syncing

- If two of you change the same thing without seeing the other's change,
  nothing gets lost silently any more: the start page shows “A change
  overlapped”, you compare and decide.
- The server checks every nightly backup whether it can be restored
  (Server administration → Status → “Check backup”).
- The Docker server runs without root rights.

## 1.0.10 – Anticipation and order

- Countdown: mark events, the start page counts the days (“12 days until
  the beach”).
- Week preview on Sundays at 6 p.m. with events, rides and birthdays.
- Waste calendar: who puts out which bin and when, with a reminder the
  evening before.
- Packing lists for trips, per person, with a reminder before departure.
- Deadlines and maintenance: car inspection, heating, vet – reminded in
  time.
- Milestones matching the age; photos and documents take up at most
  500 MB on the device.

## 1.0.9 – Wishes and rides

- Wish lists for birthdays and Christmas; the person wishing does not see
  who gets what.
- Set in the event who drops off and who picks up – with its own reminder.
- Recognize events in PDFs, such as a letter from school.
- Emergency button and check-in also in Home Assistant.

## 1.0.8 – Emergency button

- Emergency button for kids: loud alarm for the parents with location,
  call, siren and text message without internet.
- Let a child's phone ring, check-in “I've arrived”, warning when the
  battery is low.
- Quiet times for notifications, invitations via QR code.
- Shopping sorted by aisle, public and school holidays in the calendar,
  pinboard, checklists in tasks and events from photos.

## 1.0.7

- When syncing with Bring! and other list apps, finished entries no longer
  come back.

## 1.0.6

- The “Undo” bar disappears by itself again.
- The Bring! sync understands more answers of the Bring! interface.

## 1.0.5 – Other apps

- Tasks and shopping lists in Apple Reminders, Bring! and Microsoft To Do.
- Repeating tasks, search across everything, “Undo” when deleting and
  “Export my data”.
