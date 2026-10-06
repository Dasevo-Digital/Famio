/// Names of all synced collections.
///
/// Every piece of family data is stored as a [SyncRecord] in one of these
/// collections. The server rejects records for unknown collections, so a new
/// module needs an entry here.
abstract final class Collections {
  static const tasks = 'tasks';
  static const shoppingLists = 'shopping_lists';
  static const shoppingItems = 'shopping_items';

  /// The family's aisle corrections (one record, [shoppingAislesId]):
  /// article key → category key; outlives the items.
  static const shoppingAisles = 'shopping_aisles';
  static const shoppingAislesId = 'family';
  static const events = 'events';

  /// External calendars (ICS URLs) the server imports; edited by members.
  static const calendarSubscriptions = 'calendar_subscriptions';

  /// Events imported from [calendarSubscriptions]; written by the server only.
  static const externalEvents = 'external_events';

  /// Import status per subscription (same id); written by the server only.
  static const calendarSyncStatus = 'calendar_sync_status';

  static const chatMessages = 'chat_messages';
  static const chatReads = 'chat_reads';
  static const documents = 'documents';
  static const children = 'children';
  static const childEntries = 'child_entries';

  /// Daily log per child (feeding, sleep, diapers, fever …); guardians only.
  static const childLogs = 'child_logs';

  /// Important contacts (pediatrician, daycare, babysitter …).
  static const contacts = 'contacts';

  /// Pregnancies with appointments, checklists and contractions.
  static const pregnancies = 'pregnancies';

  /// Family recipes and the weekly meal plan.
  static const recipes = 'recipes';
  static const mealPlan = 'meal_plan';

  /// School timetables (record id = child id).
  static const timetables = 'timetables';

  /// Household budget: entries and one settings record (audience, limits).
  static const budgetEntries = 'budget_entries';
  static const budgetSettings = 'budget_settings';

  /// Places with a radius (home, school …); edited by members.
  static const places = 'places';

  /// Last position and sharing status per member (id = member id);
  /// written by the server from the devices' reports.
  static const memberLocations = 'member_locations';

  /// Arrival/departure notices per recipient; written by the server.
  static const locationAlerts = 'location_alerts';

  /// Chores (Ämter) with rotation and points.
  static const chores = 'chores';

  /// Kids' routines (morning, evening …) and their daily progress.
  static const routines = 'routines';
  static const routineRuns = 'routine_runs';

  /// Rewards that points can be exchanged for.
  static const rewards = 'rewards';

  /// Points earned (chores, routines, bonus) or spent (rewards).
  static const pointEntries = 'point_entries';

  /// Pocket money settings per child (id = member id) and the money
  /// account's bookings; weekly payments are booked by the server.
  static const allowances = 'allowances';
  static const moneyEntries = 'money_entries';

  /// Comments on calendar events.
  static const eventComments = 'event_comments';

  /// Votes in chat polls (id = message id + member).
  static const pollVotes = 'poll_votes';

  /// Reusable lists (packing lists …).
  static const listTemplates = 'list_templates';

  /// Supplies at home (fridge, freezer, pantry).
  static const pantryItems = 'pantry_items';

  /// Medication plans and taken doses; health data, chosen members only.
  static const medications = 'medications';
  static const medicationIntakes = 'medication_intakes';

  /// How the emergency button behaves (one record, adults only).
  static const sosSettings = 'sos_settings';

  /// Emergencies raised with the button; written by the server.
  static const sosAlerts = 'sos_alerts';

  static const all = {
    shoppingAisles,
    sosSettings,
    sosAlerts,
    chores,
    routines,
    routineRuns,
    rewards,
    pointEntries,
    allowances,
    moneyEntries,
    eventComments,
    pollVotes,
    listTemplates,
    pantryItems,
    medications,
    medicationIntakes,
    chatMessages,
    chatReads,
    documents,
    children,
    childEntries,
    childLogs,
    contacts,
    pregnancies,
    recipes,
    mealPlan,
    timetables,
    budgetEntries,
    budgetSettings,
    tasks,
    shoppingLists,
    shoppingItems,
    events,
    calendarSubscriptions,
    externalEvents,
    calendarSyncStatus,
    places,
    memberLocations,
    locationAlerts,
  };

  /// What guests (grandparents, babysitters …) receive at all.
  static const guestReadable = {
    shoppingAisles,
    tasks,
    shoppingLists,
    shoppingItems,
    events,
    eventComments,
    chatMessages,
    chatReads,
    pollVotes,
    recipes,
    mealPlan,
    contacts,
    chores,
    routines,
    routineRuns,
    listTemplates,
    pantryItems,
  };

  /// What guests may change: chatting, ticking off and commenting.
  static const guestWritable = {
    tasks,
    shoppingItems,
    eventComments,
    chatMessages,
    chatReads,
    pollVotes,
    routineRuns,
  };

  /// Managed by adults only; children earn points through [pointEntries]
  /// (as requests an adult confirms).
  static const adultOnly = {
    chores,
    rewards,
    allowances,
    moneyEntries,
    routines,
    sosSettings,
  };

  /// Collections clients may read but never write.
  static const serverOwned = {
    externalEvents,
    calendarSyncStatus,
    memberLocations,
    locationAlerts,
    sosAlerts,
  };
}
