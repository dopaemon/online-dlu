import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'data.dart';
import 'graph.dart';

/// Một lần nhắc: [luc] là lúc rung máy, [vao] là giờ thật sự vào lớp.
typedef MocNhac = ({
  DateTime luc,
  DateTime vao,
  String mon,
  String phong,
  int tiet,
});

/// Các mốc cần nhắc, lấy từ lịch đã nạp sẵn. Bỏ mốc đã qua so với [now], sắp
/// theo thời gian rồi cắt còn [toiDa] — Android có trần số alarm chờ, mà nhắc
/// xa cả tháng thì tới lúc đó lịch cũng đã đổi và được đặt lại rồi.
List<MocNhac> mocNhac(
  Map<DateTime, List<dynamic>> ngay,
  DateTime now, {
  Duration truoc = Nhac.truoc,
  int toiDa = 30,
}) {
  final out = <MocNhac>[];
  for (final e in ngay.entries) {
    for (final i in e.value) {
      final tiet = tietNo(i['BeginTime']);
      final phut = batDauPhut(tiet);
      if (phut == null) continue;
      final vao = e.key.add(Duration(minutes: phut));
      final luc = vao.subtract(truoc);
      if (!luc.isAfter(now)) continue;
      out.add((
        luc: luc,
        vao: vao,
        mon: subjectName(i['CurriculumName']),
        phong: clean(i['RoomID']),
        tiet: tiet,
      ));
    }
  }
  out.sort((a, b) => a.luc.compareTo(b.luc));
  return out.take(toiDa).toList();
}

/// Nhắc trước giờ vào lớp bằng thông báo hệ thống. Không đụng tới portal:
/// chỉ đọc lịch đã nạp sẵn rồi hẹn máy rung đúng giờ, nên tắt mạng vẫn kêu.
class Nhac {
  static const truoc = Duration(minutes: 15);
  static const _khoa = 'nhac_truoc_gio';
  static const _kenh = 'sap_vao_lop';

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _sanSang = false;

  /// Có bật nhắc không — mặc định bật, tắt hẳn thì dùng công tắc trong app
  /// hoặc chặn thông báo của app ở phần Cài đặt của máy.
  static Future<bool> bat() async =>
      (await SharedPreferences.getInstance()).getBool(_khoa) ?? true;

  static Future<void> datBat(bool v) async {
    (await SharedPreferences.getInstance()).setBool(_khoa, v);
    if (!v) await _plugin.cancelAll();
  }

  static AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Máy có cho hẹn đúng phút không. Android 14 trở lên mặc định là không,
  /// và hẹn xấp xỉ thì hệ thống được phép dồn trễ cả tiếng — nhắc trước 15
  /// phút mà tới nơi lớp đã vào rồi thì coi như hỏng.
  static Future<bool> chinhXacDuoc() async {
    try {
      return await _android?.canScheduleExactNotifications() ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Mở thẳng trang cấp quyền báo thức chính xác. Chỉ gọi khi người dùng tự
  /// bấm — không được lôi họ ra màn cài đặt giữa lúc app đang mở lên.
  static Future<void> xinChinhXac() async {
    try {
      await _moDau();
      await _android?.requestExactAlarmsPermission();
    } catch (_) {
      // Máy không có trang đó thì thôi.
    }
  }

  static Future<void> _moDau() async {
    if (_sanSang) return;
    tzdata.initializeTimeZones();
    // App của một trường ở Đà Lạt nên múi giờ cố định; khỏi thêm một
    // package chỉ để hỏi máy đang đứng ở đâu.
    tz.setLocalLocation(tz.getLocation('Asia/Ho_Chi_Minh'));
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    await _android?.requestNotificationsPermission();
    await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: true, sound: true);
    _sanSang = true;
  }

  /// Đặt lại toàn bộ lịch nhắc theo [ngay]. Xoá sạch rồi đặt từ đầu, khỏi
  /// phải dò xem cái nào đặt rồi — lịch trường đổi thì lượt sau tự đúng.
  ///
  /// Nuốt mọi lỗi: máy không cho thông báo, chưa cấp quyền, hay đang chạy
  /// trong test không có platform channel thì cũng không được phép làm hỏng
  /// lượt nạp dữ liệu đang gọi nó.
  static Future<void> datLai(Map<DateTime, List<dynamic>> ngay) async {
    try {
      if (!await bat()) return;
      await _moDau();
      await _plugin.cancelAll();
      var id = 0;
      for (final m in mocNhac(ngay, DateTime.now())) {
        await _dat(id++, m);
      }
    } catch (_) {
      // Không hẹn được thì thôi, app vẫn chạy bình thường.
    }
  }

  static Future<void> _dat(int id, MocNhac m) async {
    final phong = m.phong.isEmpty ? '' : ' — phòng ${m.phong}';
    Future<void> hen(AndroidScheduleMode che) => _plugin.zonedSchedule(
      id: id,
      title: 'Sắp vào lớp: ${m.mon}',
      body:
          'Tiết ${m.tiet} lúc '
          '${m.vao.hour}h${m.vao.minute.toString().padLeft(2, '0')}$phong',
      scheduledDate: tz.TZDateTime.from(m.luc, tz.local),
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _kenh,
          'Sắp vào lớp',
          channelDescription: 'Nhắc trước 15 phút khi tới giờ lên lớp',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: che,
    );

    try {
      await hen(AndroidScheduleMode.exactAllowWhileIdle);
    } catch (_) {
      // Android 12+ chưa cấp quyền hẹn chính xác: hẹn xấp xỉ vẫn hơn không
      // nhắc, máy chỉ được phép dồn trễ vài phút.
      await hen(AndroidScheduleMode.inexactAllowWhileIdle);
    }
  }
}
