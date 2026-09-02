import 'package:flutter_test/flutter_test.dart';
import 'package:silsigan/utils/session_sync.dart';

void main() {
  group('planSessionSync', () {
    test('tombstone always wins', () {
      final plan = planSessionSync(
        localExists: true,
        tombstoned: true,
        localTitle: 'Meeting',
        serverTitle: 'Meeting',
      );
      expect(plan.action, SessionSyncAction.skip);
    });

    test('missing local row downloads', () {
      final plan = planSessionSync(
        localExists: false,
        tombstoned: false,
        serverTitle: 'Meeting',
      );
      expect(plan.action, SessionSyncAction.download);
    });

    test('local title backfills an untitled server copy', () {
      final plan = planSessionSync(
        localExists: true,
        tombstoned: false,
        localTitle: 'Q3 review',
        serverTitle: null,
      );
      expect(plan.action, SessionSyncAction.upload);
    });

    test('server title patches an untitled local copy', () {
      final plan = planSessionSync(
        localExists: true,
        tombstoned: false,
        localTitle: null,
        serverTitle: 'Q3 review',
      );
      expect(plan.action, SessionSyncAction.patchLocalTitle);
      expect(plan.titleToPatch, 'Q3 review');
    });

    test('matching titles skip', () {
      final plan = planSessionSync(
        localExists: true,
        tombstoned: false,
        localTitle: 'Q3 review',
        serverTitle: 'Q3 review',
      );
      expect(plan.action, SessionSyncAction.skip);
    });

    test('newer local rename is uploaded', () {
      final plan = planSessionSync(
        localExists: true,
        tombstoned: false,
        localTitle: 'New name',
        serverTitle: 'Old name',
        localUpdatedAt: DateTime.utc(2026, 9, 3, 12),
        serverUpdatedAt: DateTime.utc(2026, 9, 3, 11),
      );
      expect(plan.action, SessionSyncAction.upload);
    });

    test('newer server rename is patched locally', () {
      final plan = planSessionSync(
        localExists: true,
        tombstoned: false,
        localTitle: 'Old name',
        serverTitle: 'New name',
        localUpdatedAt: DateTime.utc(2026, 9, 3, 11),
        serverUpdatedAt: DateTime.utc(2026, 9, 3, 12),
      );
      expect(plan.action, SessionSyncAction.patchLocalTitle);
      expect(plan.titleToPatch, 'New name');
    });

    test('missing server timestamp prefers local title', () {
      expect(localIsNewer(DateTime.utc(2026, 9, 3), null), isTrue);
    });
  });

  group('helpers', () {
    test('asInt accepts num and numeric strings', () {
      expect(asInt(12), 12);
      expect(asInt(12.0), 12);
      expect(asInt('12'), 12);
      expect(asInt('x'), isNull);
      expect(asInt(null), isNull);
    });

    test('nonemptyTitle trims blanks', () {
      expect(nonemptyTitle('  hi  '), 'hi');
      expect(nonemptyTitle('   '), isNull);
      expect(nonemptyTitle(null), isNull);
    });
  });
}
