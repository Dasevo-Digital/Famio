# Privacy information for Famio

As of: 25 November 2026 · [Deutsch](datenschutz.md) · [Español](datenschutz.es.md)

This is a translation of the German version. If the two differ, the German
version applies.

## Responsibility

Famio is self-hosted software. There is no central Famio service and no user
account run by the project. Responsible for the actual operation, the
accounts created and the data stored in them is the person or organisation
that runs the Famio server in question. They must give the members a contact
they can reach and, where required, further legally required information.

## Data processed

Depending on use, Famio stores in particular accounts and sessions, family
relationships, calendars, tasks, lists, messages, documents, photos, pantry
items, financial details, children's and health data, and exact location
histories. The server also keeps an audit log of security-relevant
administrative actions. Which categories are actually processed is decided
by the family or the operator.

The server's database and files are encrypted, and so are its nightly
backups. The server writes the audit log to the system log (for example the
journal), where that log's retention applies. The devices keep a local
database, also encrypted, and a file cache for offline use. Their key stays
in the device's keychain; on iPhone and iPad both are excluded from the
device backup. On Linux without a keychain the key is kept in the app's
settings once the user agrees.
On Android, the rows of the home screen widget "Famio today" and the access
of the background services (own notifications, location sharing) are
encrypted with a key from the Android Keystore; the widget's rows are only
kept while the widget is on the home screen.

Not encrypted on the device are:

- a copy of a document someone opens in another app; it is removed at the
  next clean-up after one hour at the latest;
- photos and files that the camera, the file picker and the scanner leave
  for Famio, until the operating system empties the app's cache;
- cached map tiles, and on the iPhone the family's places for place
  notifications and the coordinates of the weather location;
- the texts of notifications shown, if "Show contents" is switched on; for
  reminders about medication and children they include names;
- on Android, the texts of planned reminders, so that Android can plan them
  again after a restart; with "Show contents" they include names as well,
  without it only "Famio";
- on iPhone and iPad, what is sent to Famio from another app via "Share",
  until Famio takes it over, for one day at most.

Health data (medication, children's data with emergency details and log,
pregnancies, and documents in the Health category) is only given to adults
and to people explicitly selected. Photos attached to entries of a child's
log, for example of a rash, follow the same rules. Service accounts, for
example for Home Assistant or a wall display, never get it; children's
accounts only if they are selected. Guests and children's accounts only see
private events if they take part in them; service accounts only learn that
the time is taken. Notifications name them without a title. Children's
accounts only get entries of the family inbox (often scanned letters) if
they were filed with "Children can see it too", and always what they filed
themselves; guests and service accounts never get the inbox. Administrators
can manage accounts and passwords and can therefore technically gain access
to family data; such actions appear in the audit log. They can also look up
any member's location history and export the whole family's data (see
below). Whoever opens Famio for the first time through the Home Assistant
sidebar is a guest until an administrator sets their role.

## Retention and deletion

- Sessions expire after 90 days without use and can be revoked per device.
- If the Location section is hidden in the server administration, the server
  accepts no positions and the phones pause sharing.
- The location history can be set to 1 to 365 days; the default is seven
  days. The last position reported stays stored until a new one arrives,
  sharing is paused or the account is deleted. It also disappears when
  Famio is signed out on the phone, unless another device of the member
  shares; outside a schedule for sharing it cannot be seen. The server keeps
  the device name and the time of the last report of every sharing device
  as long as the location history; if several devices of a member share,
  the one switched on last counts.
- The server backs up its database every night, encrypted, and keeps seven
  daily and four weekly backups. Deleted entries and older positions remain
  in them for up to about five weeks.
- Conflict copies, which arise when the same entry is edited on two devices
  at the same time, contain the complete older version, including health
  data. Only the two people involved see them, and they are removed after
  60 days. Deletion marks without content for syncing devices are kept for
  180 days, delivered notices of Famio's own push connection for three days.
- Signing out deletes the device's local database, cache and sign-in data.
  If changes have not reached the server yet, because the last sync does not
  work or the server holds them back, the app asks first. If the session
  ends in another way (a new password on another device, "Sign out
  everywhere") while changes are still waiting, only these changes stay on
  the device, encrypted; the app deletes the rest of the family's data. If
  the same account signs in again on the same server, the app loads
  everything again and sends them. They are deleted if another account
  signs in or someone signs in to another server, if they are discarded on
  the sign-in page, or after 14 days. If the server has removed the
  account, the app keeps nothing.
- If the local database cannot be opened (for example because it is
  damaged), the app sets it aside, encrypted, and loads everything again.
  The copy set aside is deleted when signing out, when another account signs
  in, and after 30 days.
- Administrators can delete the family data on the server. The deletion
  reaches the devices with the next sync. Connections to list apps,
  Paperless-ngx and PhotoVault are disconnected first, so that their entries
  do not come back.
- Adults and guests can delete their account themselves in the app; an
  adult removes children's accounts in the server administration.
- When an account is deleted, the server removes its emergency details and
  all entries only this person could see, such as private notes, documents
  with their files and health data; from the trash as well. Children's data
  remains as the family's data. What no adult apart from this person could
  see is then seen by the child's other guardians; if there are none, by all
  adults and whoever else was selected. So that the account's other devices
  learn of it, the server keeps check values of their sessions for up to 90
  days. Existing backups keep containing the deleted data until they expire.
- Single deleted tasks, events, notes and documents are kept with their
  attachments in the server's trash for up to 30 days. Members only see
  deleted items they may still see under their current rights; restoring
  also requires write access. After that time they can no longer be
  retrieved and are removed in the regular clean-up. A complete
  administrative deletion of the family data also empties the trash.
  Deletion marks for syncing devices, conflict copies and backups are
  separate from it.
- When confirming a responsibility is explicitly requested, the reply, the
  person responsible and the reference to the specific task or trip are
  stored. They are only visible to those allowed to see the entry they
  belong to. Reminders about open promises are optional and follow the
  existing push and quiet-time settings.
- Backups and copies in external calendar, cloud or push services must be
  deleted separately with their operator.

## Network connections and recipients

**Your own Famio server.** The app and the browser send the family, account
and device data needed for syncing to the server chosen by the operator.
HTTPS is the default. A public reverse proxy or hosting provider can
technically process connection data.

**OpenStreetMap or your own map server.** Opening the map loads tiles for the
area viewed. The map provider receives the IP address and the tile
coordinates, from which the area viewed can be derived. Because the family
map follows the members' positions and the map of an emergency call zooms in
closely, this reveals roughly where someone is. The web app also sends the
address of the Famio server (without a path) as referrer, because
OpenStreetMap refuses browser requests without a referrer. Your own map
server keeps this request within your own operation.

**Fonts of the web app.** The web app loads emojis and characters of other
languages from your own Famio server, not from Google. For Chinese, Japanese
and Korean characters the server fetches the matching font file once from
Google Fonts and keeps it afterwards; Google only sees the server's address,
not the family's.

**Open-Meteo.** Weather is opt-in per device. Sent are the coordinates of the
place "Home" (without it, those of the first place), rounded to 0.01 degrees,
and the technically necessary IP address. The provider may log requests
under its own rules.

**Text and barcode recognition (Android).** Events from photos and the
barcode scanner analyse the images on the phone; the images do not leave the
phone for this. A photo or scan of an event only goes to your own Famio
server as an attachment if "Save the original with the events" stays
switched on when taking it over. In the small package for 64-bit phones the
recognition models come from Google Play services, which download them once
on first use; Google sees the phone's request as with any other download
from Google Play. Under Settings → "Recognition without Google Play" there
is a package with built-in models. According to Google, however, ML Kit
also sends diagnostic and usage data to Google with built-in models: device,
app version, performance values and an identifier of the installation, not
the images or the recognised texts. The document scanner always comes from
Google Play services. On iPhone and iPad Apple's Vision recognises text and
barcodes on the device without sending anything.

**Text message for an emergency call.** If "Text message without internet"
is switched on and the phone has no connection, the emergency call goes as a
text message with name and position through the mobile operator to the
chosen numbers. Android sends it itself; on iPhone and iPad Famio opens the
iOS message window with the prepared text, and it only goes out after a tap
on "Send". iOS decides whether it sends it as a text message or as an
iMessage through Apple.

**Open Food Facts.** A barcode search in the pantry sends the scanned
barcode, the search for nutrition values (after agreeing once per device)
the search terms, each with the technically necessary IP address, to
`world.openfoodfacts.org`.

**Recipe import.** Whoever takes over a recipe from a web page calls up that
page: the app directly, the web app through the Famio server. If the page
refuses the app's request or delivers no recipe, the app tries once more and
then asks the Famio server to fetch the page; your own server learns the
page's address in doing so. The recipe's photo is always fetched by the
server and stored like an upload. The page's provider sees the IP address of
the device or the server, nothing else.

**ntfy.** Only once set up. The ntfy server configured receives the secret
topic, the IP address and at least a brief notice; for some notifications
this also names someone ("SOS from …", "… is coming"). If "Details" is
switched on, the actual notification is sent, for example arrivals at
places, trip destinations with arrival time or chat texts. In addition there
is a link to tap with a random identifier of the notification, also without
"Details". What Famio opens with it (for example a task or a chat) only the
recipient's app learns from their Famio server, as long as the notification
is stored there; the identifier reveals neither the entry nor who writes to
whom. According to its own privacy policy, the public service ntfy.sh keeps
messages for up to twelve hours and delivers them to phones through Google
(FCM) or Apple. On the iPhone, without Apple Push, ntfy is the only way for
notifications in the background, emergency calls included. Your own ntfy
server keeps this within your own operation.

**Web Push.** In the browser, the browser's push service (Google, Mozilla,
Apple or Microsoft) receives the encrypted notification, its urgency and the
public address of the Famio server; it cannot read the content.

**Calendar services.** ICS subscriptions, CalDAV and Google Calendar are only
used once set up. Events or sign-in data then leave the Famio server to the
extent the feature requires. Famio events marked as private are not
published in calendar subscriptions.

**Version check.** Only when an administrator taps "Check for a new version"
in the server administration does their app ask the project's public release
list on GitHub. No Famio data is sent; GitHub sees the device's IP address.
If update distribution through the Famio server is also explicitly switched
on, the server fetches the release list and the matching installation files
from GitHub. Incomplete downloads are retried in the background. GitHub and
its download servers see the Famio server's IP address; no Famio content is
sent. Without this setting the server makes none of these requests.

**Bring! and Microsoft To Do.** Only if a member connects their account and
assigns lists. The Famio server then sends the entries of the assigned lists
(for tasks title, note, due date and done status; for shopping lists item,
quantity and ticked status) to Bring! (Bring! Labs AG, Switzerland) or
Microsoft (Microsoft Graph) and fetches changes from there. Only sign-in
tokens are stored, not the password. The connection to Bring! uses an
interface that is not officially documented. A family can switch the feature
off completely in the server administration; disconnecting an account
deletes the tokens and assignments on the Famio server.

**Paperless-ngx and PhotoVault.** Only if an administrator connects them. The
Famio server then uses the stored access to fetch documents with their files
from Paperless-ngx (including those in the Health category), or photos and
birthdays from PhotoVault, and shows them to the members chosen. Famio also
passes the photos of the family chat to PhotoVault, with the sender's name
and the time, if that is set up.

**Home Assistant.** A service account for Home Assistant receives positions,
events (private ones only as time taken), tasks, lists, finances and the
family chat, but no health data, no documents and no inbox. Home Assistant
stores these values in its own history (recorder) according to its
settings; Famio cannot delete them there. In "client" mode the add-on stores
the sidebar's sessions unencrypted in its data folder, which is part of Home
Assistant's backups.

**OpenID Connect.** If sign-in through an identity provider is switched on,
the browser, the Famio server and the configured provider are connected with
each other. The provider processes the account and connection data needed
for signing in.

**Famio's own push connection.** Famio's direct push option keeps a
connection between the device and your own Famio server and uses no other
push provider. On iOS, delivery in the background without Apple Push is
limited.

## No telemetry by the project

Famio contains no usage analysis, advertising or automatic crash reporting
by the project. Reverse proxies, calendar, map, push or identity services
added by the operator may keep their own logs.

## Export, information and correction

Every member can create a ZIP file under Settings → "Export my data"
themselves, with all data they can see in Famio, including their files and
their location history (password confirmation). An adult administrator can
export the whole family's data in the server administration, for example to
move to another server. This export is a complete backup: it also contains
private entries, direct messages and health data of other members as well as
last positions and emergency calls, but no location histories. It appears in
the audit log, and the other adults get a notification. Neither export is
encrypted. The file is only created on the server for a short time for the
download and deleted afterwards. For correction and deletion and for further
information, members contact the operator of their Famio server. The Famio
project has no access to a self-hosted installation and can neither read nor
delete its contents.
