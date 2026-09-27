/// Names of all synced collections.
///
/// Every piece of family data is stored as a [SyncRecord] in one of these
/// collections. The server rejects records for unknown collections, so a new
/// module needs an entry here.
abstract final class Collections {
  static const tasks = 'tasks';
  static const shoppingLists = 'shopping_lists';
  static const shoppingItems = 'shopping_items';
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

  static const all = {
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

  /// Collections clients may read but never write.
  static const serverOwned = {
    externalEvents,
    calendarSyncStatus,
    memberLocations,
    locationAlerts,
  };
}
