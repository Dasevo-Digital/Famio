import 'package:sqlite3/sqlite3.dart';

import 'crypto/encrypted_db.dart';

/// Schema migrations, applied in order. Never edit an existing entry;
/// append a new one instead.
const _migrations = [
  '''
  CREATE TABLE users (
    id TEXT PRIMARY KEY,
    username TEXT NOT NULL UNIQUE COLLATE NOCASE,
    display_name TEXT NOT NULL,
    password_hash TEXT,
    is_admin INTEGER NOT NULL DEFAULT 0,
    color INTEGER,
    ha_user_id TEXT UNIQUE,
    created_at INTEGER NOT NULL
  );
  CREATE TABLE sessions (
    token_hash TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device TEXT,
    created_at INTEGER NOT NULL,
    last_seen INTEGER NOT NULL
  );
  CREATE TABLE records (
    collection TEXT NOT NULL,
    id TEXT NOT NULL,
    data TEXT NOT NULL,
    deleted INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL,
    updated_by TEXT,
    rev INTEGER NOT NULL UNIQUE,
    PRIMARY KEY (collection, id)
  );
  ''',
  '''
  CREATE TABLE calendar_feeds (
    id TEXT PRIMARY KEY,
    token TEXT NOT NULL UNIQUE,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    scope TEXT NOT NULL,
    created_at INTEGER NOT NULL
  );
  ''',
  '''
  ALTER TABLE records ADD COLUMN visible_to TEXT;
  CREATE INDEX records_rev ON records(rev);
  -- Members who lost access to a record; they get a tombstone at [rev].
  CREATE TABLE revocations (
    member_id TEXT NOT NULL,
    collection TEXT NOT NULL,
    id TEXT NOT NULL,
    rev INTEGER NOT NULL,
    PRIMARY KEY (member_id, collection, id)
  );
  CREATE TABLE files (
    id TEXT PRIMARY KEY,
    owner TEXT NOT NULL,
    name TEXT NOT NULL,
    mime TEXT NOT NULL,
    size INTEGER NOT NULL,
    created_at INTEGER NOT NULL
  );
  ''',
  '''
  -- Server settings changed by admins in the app; override env defaults.
  CREATE TABLE settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  );
  ''',
  '''
  ALTER TABLE calendar_feeds ADD COLUMN hide_details INTEGER NOT NULL DEFAULT 0;
  ''',
  '''
  -- Passwords for calendar apps connecting via CalDAV, one per device.
  CREATE TABLE app_passwords (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    secret_hash TEXT NOT NULL UNIQUE,
    include_confidential INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_used INTEGER
  );
  -- Two-way sync with calendars on other CalDAV servers (iCloud …).
  CREATE TABLE caldav_accounts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    server_url TEXT NOT NULL,
    username TEXT NOT NULL,
    password TEXT NOT NULL,
    calendar_url TEXT NOT NULL,
    calendar_name TEXT NOT NULL,
    only_mine INTEGER NOT NULL DEFAULT 0,
    private_import INTEGER NOT NULL DEFAULT 0,
    ctag TEXT,
    last_sync INTEGER,
    last_error TEXT,
    created_at INTEGER NOT NULL
  );
  -- Which remote resource belongs to which Famio event.
  CREATE TABLE caldav_links (
    account_id TEXT NOT NULL REFERENCES caldav_accounts(id) ON DELETE CASCADE,
    href TEXT NOT NULL,
    event_id TEXT,
    etag TEXT,
    rev INTEGER NOT NULL DEFAULT 0,
    origin TEXT NOT NULL,
    mode TEXT NOT NULL,
    PRIMARY KEY (account_id, href)
  );
  CREATE INDEX caldav_links_event ON caldav_links(account_id, event_id);
  -- Sessions limited to one purpose, e.g. location reports of a phone.
  ALTER TABLE sessions ADD COLUMN scope TEXT;
  CREATE TABLE location_points (
    member_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    at INTEGER NOT NULL,
    latitude REAL NOT NULL,
    longitude REAL NOT NULL,
    accuracy REAL,
    PRIMARY KEY (member_id, at)
  );
  CREATE TABLE location_state (
    member_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    paused INTEGER NOT NULL DEFAULT 0,
    paused_until INTEGER,
    paused_by TEXT,
    place_id TEXT,
    place_since INTEGER,
    last_fix INTEGER
  );
  ''',
  '''
  -- OAuth grant (JSON) of CalDAV accounts that need it, e.g. Google.
  ALTER TABLE caldav_accounts ADD COLUMN oauth TEXT;
  ''',
  '''
  -- Birthday of a member: "YYYY-MM-DD" or "--MM-DD" without the year.
  ALTER TABLE users ADD COLUMN birthday TEXT;
  ''',
  '''
  -- Who sees events from a CalDAV account besides its owner: JSON list of
  -- member ids, NULL for the whole family.
  ALTER TABLE caldav_accounts ADD COLUMN shared_with TEXT;
  UPDATE caldav_accounts SET shared_with = '[]' WHERE private_import = 1;
  -- Calendar profiles: connected calendars an admin switched off for a
  -- member (source = subscription id or "caldav:<account id>").
  CREATE TABLE calendar_hidden (
    member_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    source TEXT NOT NULL,
    PRIMARY KEY (member_id, source)
  );
  ''',
  '''
  -- adult, child or guest (see MemberRole).
  ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'adult';
  -- Push notifications via ntfy (or compatible), per member and device.
  CREATE TABLE push_targets (
    id TEXT PRIMARY KEY,
    member_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    url TEXT NOT NULL,
    token TEXT,
    details INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL,
    last_error TEXT
  );
  ''',
  '''
  -- Two-factor login with an authenticator app (TOTP, RFC 6238).
  ALTER TABLE users ADD COLUMN totp_secret TEXT;
  -- Secret shown during setup, active once a code was confirmed.
  ALTER TABLE users ADD COLUMN totp_pending TEXT;
  -- Last time step used: a code works only once.
  ALTER TABLE users ADD COLUMN totp_last_step INTEGER;
  CREATE TABLE recovery_codes (
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash TEXT NOT NULL,
    PRIMARY KEY (user_id, code_hash)
  );
  -- Accounts at a single sign-on provider (OpenID Connect) per member.
  CREATE TABLE sso_links (
    issuer TEXT NOT NULL,
    subject TEXT NOT NULL,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT,
    created_at INTEGER NOT NULL,
    PRIMARY KEY (issuer, subject)
  );
  -- How a session signed in: password, totp or sso (two-factor policy).
  ALTER TABLE sessions ADD COLUMN method TEXT;
  ''',
  '''
  -- What a service account (e.g. Home Assistant) may change.
  ALTER TABLE users ADD COLUMN service_access TEXT NOT NULL DEFAULT 'full';
  ''',
  '''
  -- Optional recurring local-time window for location sharing. Kept with the
  -- location state so it is never synchronised to unrelated family clients.
  ALTER TABLE location_state ADD COLUMN sharing_schedule TEXT;
  ''',
  '''
  -- Lists in other apps (Bring!, Microsoft To Do) kept in sync with tasks
  -- and shopping lists. Credentials are tokens, never passwords.
  CREATE TABLE list_accounts (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    provider TEXT NOT NULL,
    name TEXT NOT NULL,
    credentials TEXT NOT NULL,
    last_sync INTEGER,
    last_error TEXT,
    created_at INTEGER NOT NULL
  );
  -- Which Famio list ('tasks' or a shopping list id) goes with which list.
  CREATE TABLE list_links (
    account_id TEXT NOT NULL REFERENCES list_accounts(id) ON DELETE CASCADE,
    famio_list TEXT NOT NULL,
    remote_list TEXT NOT NULL,
    remote_name TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (account_id, famio_list)
  );
  -- Which entry there belongs to which Famio record, and the fingerprint of
  -- the state both sides last agreed on.
  CREATE TABLE list_items (
    account_id TEXT NOT NULL REFERENCES list_accounts(id) ON DELETE CASCADE,
    famio_list TEXT NOT NULL,
    item_id TEXT NOT NULL,
    remote_id TEXT NOT NULL,
    hash TEXT NOT NULL,
    PRIMARY KEY (account_id, famio_list, item_id)
  );
  ''',
  '''
  -- When a member's notifications arrive silently (QuietHours as JSON).
  CREATE TABLE quiet_hours (
    member_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    config TEXT NOT NULL
  );
  ''',
  '''
  -- Invitations: a one-time code (only its hash) for a new member.
  CREATE TABLE invites (
    id TEXT PRIMARY KEY,
    code_hash TEXT NOT NULL UNIQUE,
    role TEXT NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    created_by TEXT,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    used_at INTEGER,
    used_by TEXT
  );
  ''',
  '''
  -- The revision the records had at a server time: tells which deletion
  -- marks are old enough to clean up.
  CREATE TABLE rev_marks (
    at INTEGER PRIMARY KEY,
    rev INTEGER NOT NULL
  );
  ''',
  '''
  -- The language of a member's app (de, en, es) for push messages.
  ALTER TABLE users ADD COLUMN language TEXT;
  ''',
];

/// Opens (and migrates) the SQLite database at [path]; `:memory:` for tests.
/// With [hexKey] the database is encrypted (see [openEncrypted]).
Database openFamioDatabase(String path, {String? hexKey}) {
  final db = openEncrypted(path, hexKey: hexKey);
  db.execute('PRAGMA journal_mode = WAL;');
  // Safe with WAL (a crash never corrupts the file) and far fewer fsyncs.
  db.execute('PRAGMA synchronous = NORMAL;');
  db.execute('PRAGMA foreign_keys = ON;');
  final version = db.select('PRAGMA user_version').first.columnAt(0) as int;
  for (var i = version; i < _migrations.length; i++) {
    db.execute('BEGIN');
    try {
      db.execute(_migrations[i]);
      db.execute('PRAGMA user_version = ${i + 1}');
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
  return db;
}
