import 'dart:convert';

import 'collections.dart';
import 'sync_record.dart';
import 'models/absence.dart';
import 'models/assignment.dart';
import 'models/budget.dart';
import 'models/calendar_sync.dart';
import 'models/chat.dart';
import 'models/child_log.dart';
import 'models/chores.dart';
import 'models/conflict.dart';
import 'models/contact.dart';
import 'models/deadline.dart';
import 'models/document.dart';
import 'models/event.dart';
import 'models/event_comment.dart';
import 'models/inbox.dart';
import 'models/list_template.dart';
import 'models/loan.dart';
import 'models/medication.dart';
import 'models/note.dart';
import 'models/pantry.dart';
import 'models/kids.dart';
import 'models/location.dart';
import 'models/pregnancy.dart';
import 'models/recipe.dart';
import 'models/shopping.dart';
import 'models/sos.dart';
import 'models/task.dart';
import 'models/timetable.dart';
import 'models/trip.dart';
import 'models/member_emergency.dart';
import 'models/vacation.dart';
import 'models/waste.dart';
import 'models/wish.dart';

/// Checks known model fields without removing fields of newer clients.
/// Serializing the parsed model also evaluates lazily cast nested lists/maps.
void validateRecordData(SyncRecord record) {
  if (record.deleted) return;
  try {
    if (record.collection == Collections.tasks ||
        record.collection == Collections.events) {
      AssignmentSettings.fromData(record.data).toJson();
    }
    for (final field in [
      SyncRecord.visibilityKey,
      if (record.collection == Collections.tasks) 'assigneeIds',
    ]) {
      final value = record.data[field];
      if (value != null &&
          (value is! List || value.any((id) => id is! String))) {
        throw const FormatException('Invalid member list');
      }
    }
    record.visibleTo?.toList();
    recordFileIds(record).toList();
    final data = switch (record.collection) {
      Collections.assignmentResponses => AssignmentResponse.fromRecord(
        record,
      ).toData(),
      Collections.tasks => Task.fromRecord(record).toData(),
      Collections.shoppingLists => ShoppingList.fromRecord(record).toData(),
      Collections.shoppingItems => ShoppingItem.fromRecord(record).toData(),
      Collections.shoppingHistory => BoughtItem.fromRecord(record).toData(),
      Collections.events => CalendarEvent.fromRecord(record).toData(),
      Collections.externalEvents => CalendarEvent.fromRecord(record).toData(),
      Collections.calendarSubscriptions => CalendarSubscription.fromRecord(
        record,
      ).toData(),
      Collections.calendarSyncStatus => SubscriptionStatus.fromRecord(
        record,
      ).toData(),
      Collections.chatMessages => ChatMessage.fromRecord(record).toData(),
      Collections.chatReads => ChatRead.fromRecord(record).toData(),
      Collections.pollVotes => PollVote.fromRecord(record).toData(),
      Collections.documents => FamilyDocument.fromRecord(record).toData(),
      Collections.externalDocuments => FamilyDocument.fromRecord(
        record,
      ).toData(),
      Collections.inbox => InboxItem.fromRecord(record).toData(),
      Collections.children => Child.fromRecord(record).toData(),
      Collections.childEntries => ChildEntry.fromRecord(record).toData(),
      Collections.childLogs => ChildLog.fromRecord(record).toData(),
      Collections.contacts => FamilyContact.fromRecord(record).toData(),
      Collections.pregnancies => Pregnancy.fromRecord(record).toData(),
      Collections.recipes => Recipe.fromRecord(record).toData(),
      Collections.mealPlan => PlannedMeal.fromRecord(record).toData(),
      Collections.timetables => Timetable.fromRecord(record).toData(),
      Collections.budgetEntries => BudgetEntry.fromRecord(record).toData(),
      Collections.budgetSettings => BudgetSettings.fromRecord(record).toData(),
      Collections.places => Place.fromRecord(record).toData(),
      Collections.memberLocations => MemberLocation.fromRecord(record).toData(),
      Collections.locationAlerts => LocationAlert.fromRecord(record).toData(),
      Collections.locationSettings => LocationSettings.fromRecord(
        record,
      ).toData(),
      Collections.trips => Trip.fromRecord(record).toData(),
      Collections.chores => Chore.fromRecord(record).toData(),
      Collections.vacations => Vacation.fromRecord(record).toData(),
      Collections.absences => MemberAbsence.fromRecord(record).toData(),
      Collections.savingsGoals => SavingsGoal.fromRecord(record).toData(),
      Collections.memberEmergency => MemberEmergency.fromRecord(
        record,
      ).toData(),
      Collections.routines => Routine.fromRecord(record).toData(),
      Collections.routineRuns => RoutineRun.fromRecord(record).toData(),
      Collections.rewards => Reward.fromRecord(record).toData(),
      Collections.pointEntries => PointEntry.fromRecord(record).toData(),
      Collections.allowances => Allowance.fromRecord(record).toData(),
      Collections.moneyEntries => MoneyEntry.fromRecord(record).toData(),
      Collections.eventComments => EventComment.fromRecord(record).toData(),
      Collections.listTemplates => ListTemplate.fromRecord(record).toData(),
      Collections.pantryItems => PantryItem.fromRecord(record).toData(),
      Collections.medications => Medication.fromRecord(record).toData(),
      Collections.medicationIntakes => MedicationIntake.fromRecord(
        record,
      ).toData(),
      Collections.wishes => Wish.fromRecord(record).toData(),
      Collections.wishClaims => WishClaim.fromRecord(
        record,
      ).toData(record.visibleTo ?? const []),
      Collections.notes => FamilyNote.fromRecord(record).toData(),
      Collections.sosSettings => SosSettings.fromRecord(record).toData(),
      Collections.sosAlerts => SosAlert.fromRecord(record).toData(),
      Collections.wasteSettings => WasteSettings.fromRecord(record).toData(),
      Collections.deadlines => Deadline.fromRecord(record).toData(),
      Collections.loans => Loan.fromRecord(record).toData(),
      Collections.conflicts => SyncConflict.fromRecord(record).toData(),
      Collections.shoppingAisles => record.data,
      _ => record.data,
    };
    jsonEncode(data);
  } on JsonUnsupportedObjectError {
    throw const FormatException('Invalid record data');
  } on TypeError {
    throw const FormatException('Invalid record data');
  } on ArgumentError {
    throw const FormatException('Invalid record data');
  } on StateError {
    throw const FormatException('Invalid record data');
  }
}

bool recordDataIsValid(SyncRecord record) {
  try {
    validateRecordData(record);
    return true;
  } on FormatException {
    return false;
  }
}

/// Historical conflict payloads remain inspectable even when not restorable.
bool conflictIsRestorable(SyncConflict conflict) =>
    Collections.conflictTracked.contains(conflict.collection) &&
    conflict.recordId.isNotEmpty &&
    conflict.recordId.length <= 64 &&
    (conflict.lostDeleted ||
        recordDataIsValid(
          SyncRecord(
            collection: conflict.collection,
            id: conflict.recordId,
            data: conflict.lost,
            updatedAt: conflict.lostAt.millisecondsSinceEpoch,
          ),
        ));

/// Only attachment fields confer access; arbitrary text never does.
Iterable<String> recordFileIds(SyncRecord record) sync* {
  if (record.deleted) return;
  if (record.collection == Collections.conflicts) {
    final conflict = SyncConflict.fromRecord(record);
    if (!conflict.lostDeleted && conflict.collection != Collections.conflicts) {
      yield* recordFileIds(
        SyncRecord(
          collection: conflict.collection,
          id: conflict.recordId,
          data: conflict.lost,
          updatedAt: conflict.lostAt.millisecondsSinceEpoch,
        ),
      );
    }
    return;
  }
  final fields = switch (record.collection) {
    Collections.tasks || Collections.childEntries => ['photos'],
    Collections.children || Collections.recipes => ['photo'],
    Collections.chatMessages => ['attachment'],
    Collections.documents => ['file'],
    Collections.inbox => ['files'],
    _ => const <String>[],
  };
  for (final field in fields) {
    final value = record.data[field];
    if (value == null) continue;
    final values = field == 'photos' || field == 'files'
        ? value as List
        : [value];
    for (final entry in values) {
      final ref = FileRef.fromJson(entry);
      if (ref == null || ref.id.isEmpty) {
        throw const FormatException('Invalid file reference');
      }
      yield ref.id;
    }
  }
}
