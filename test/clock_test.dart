import 'dart:convert';
import 'dart:io';

import 'package:dlu_tkb/cache.dart';
import 'package:dlu_tkb/clock.dart';
import 'package:dlu_tkb/graph.dart';
import 'package:dlu_tkb/paper.dart';
import 'package:dlu_tkb/portal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  setUpAll(() async {
    Hive.init(Directory.systemTemp.createTempSync('dlu_test_clock').path);
    await Cache.open();
  });

  tearDown(() => Cache.clear());

  test('nhịp đồng hồ canh đúng đầu phút', () {
    expect(
      Clock.nextTick(DateTime(2026, 9, 27, 23, 59, 42, 500)),
      DateTime(2026, 9, 28),
    );
    expect(
      Clock.nextTick(DateTime(2026, 9, 27, 8, 0)),
      DateTime(2026, 9, 27, 8, 1),
    );
  });

  testWidgets('0h00 sang ngày có tiết thì hiện luôn, không gọi portal', (
    t,
  ) async {
    var calls = 0;
    final portal = Portal(
      client: MockClient((req) async {
        calls++;
        final tuan = req.url.queryParameters['tuan'];
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ResultDataSchedule': tuan != '40'
                  ? []
                  : [
                      {
                        'StartDate': '28/09/2026',
                        'DayOfWeek': 1,
                        'NumberOfPeriods': 4,
                        'PeriodID': 1,
                        'BeginTime': 'Tiết: 1',
                        'EndTime': 'Tiết: 4',
                        'CurriculumName': 'Toán',
                      },
                    ],
            }),
          ),
          200,
        );
      }),
    );

    // Nạp trước ngoài zone của test để cache Hive ghi xong hẳn.
    await t.runAsync(() async {
      // Hâm sẵn cả tháng sau: TodayLessons nạp hai tháng, mà ghi cache Hive
      // thật thì không chạy xong dưới đồng hồ giả của testWidgets.
      for (final m in [DateTime(2026, 9), DateTime(2026, 10)]) {
        await fetchMonth(portal, 't', m);
      }
    });

    // Mở app lúc 23:59 của một ngày nghỉ: chưa có gì để hiện. Tắt hẹn nhịp
    // để test tự tua giờ, và để không còn Timer treo lúc kết thúc.
    Clock.instance.set(DateTime(2026, 9, 27, 23, 59));
    Clock.instance.stop();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TodayLessons(
            session: Session(
              id: '1',
              fullName: 'A',
              token: 't',
              expire: DateTime(2030),
            ),
            portal: portal,
          ),
        ),
      ),
    );
    // pumpAndSettle không dùng được: đồng hồ chung luôn có Timer chờ sẵn.
    await t.pump();
    await t.pump();
    expect(find.byType(Skeleton), findsNothing, reason: 'vẫn đang tải');
    // Hôm nay nghỉ nên khỏi mục "Hôm nay", nhưng mai có tiết thì xem trước.
    expect(find.text('Hôm nay'), findsNothing);
    expect(find.text('Ngày mai'), findsOneWidget);
    expect(find.text('Toán'), findsWidgets);
    final daTai = calls;
    expect(daTai, greaterThan(0));

    // Qua 0h00: lịch nguyên tháng đã nằm trong máy nên hiện ngay, không
    // thêm một lần gọi portal nào. Mục "Ngày mai" thành "Hôm nay".
    Clock.instance.set(DateTime(2026, 9, 28));
    await t.pump();
    expect(find.text('Hôm nay'), findsOneWidget);
    expect(find.text('Ngày mai'), findsNothing);
    expect(find.text('Toán'), findsWidgets);
    expect(calls, daTai);
  });

  testWidgets('học xong hết hôm nay thì hiện thêm mục Ngày mai', (t) async {
    final portal = Portal(
      client: MockClient((req) async {
        // Tuần 40: thứ 2 (28/9) học sáng, thứ 3 (29/9) học chiều.
        final tuan = req.url.queryParameters['tuan'];
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'ResultDataSchedule': tuan != '40'
                  ? []
                  : [
                      {
                        'StartDate': '28/09/2026',
                        'DayOfWeek': 1,
                        'NumberOfPeriods': 4,
                        'PeriodID': 1,
                        'BeginTime': 'Tiết: 1',
                        'EndTime': 'Tiết: 4',
                        'CurriculumName': 'Toán',
                      },
                      {
                        'StartDate': '28/09/2026',
                        'DayOfWeek': 2,
                        'NumberOfPeriods': 4,
                        'PeriodID': 7,
                        'BeginTime': 'Tiết: 7',
                        'EndTime': 'Tiết: 10',
                        'CurriculumName': 'Lý',
                      },
                    ],
            }),
          ),
          200,
        );
      }),
    );
    await t.runAsync(() async {
      // Hâm sẵn cả tháng sau: TodayLessons nạp hai tháng, mà ghi cache Hive
      // thật thì không chạy xong dưới đồng hồ giả của testWidgets.
      for (final m in [DateTime(2026, 9), DateTime(2026, 10)]) {
        await fetchMonth(portal, 't', m);
      }
    });

    // 9h00 ngày 28: đang học tiết 2, chưa tan nên chưa nhắc ngày mai.
    Clock.instance.set(DateTime(2026, 9, 28, 9));
    Clock.instance.stop();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TodayLessons(
              session: Session(
                id: '1',
                fullName: 'A',
                token: 't',
                expire: DateTime(2030),
              ),
              portal: portal,
            ),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
    expect(find.text('Đang học tiết 2'), findsWidgets);
    expect(find.text('Ngày mai'), findsNothing);

    // 11h30: tan hết rồi thì mới xem trước ngày mai.
    Clock.instance.set(DateTime(2026, 9, 28, 11, 30));
    await t.pump();
    expect(find.text('Hôm nay'), findsOneWidget);
    expect(find.text('Ngày mai'), findsOneWidget);
    expect(find.text('Lý'), findsWidgets);
  });
}
