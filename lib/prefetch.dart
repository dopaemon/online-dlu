import 'dart:async';

import 'cache.dart';
import 'graph.dart';
import 'nhac.dart';
import 'portal.dart';

/// Nạp sẵn mọi thứ vào máy ngay khi mở app, để mất mạng vẫn mở được và các
/// màn sau bấm vào là có ngay.
///
/// Gọi tuần tự chứ không bắn một lượt: server trường yếu, mà đằng nào người
/// dùng cũng chỉ nhìn một màn tại một thời điểm. Lượt này luôn lấy số mới
/// (chạy trong zone mang [Cache.forceKey] nên bỏ qua cache) — màn hình vẫn
/// hiện số cũ trong máy, lấy về kịp thì mốc dữ liệu nhích lên ngay, không
/// kịp thì thôi, để lần mở sau.
class Prefetch {
  /// Một lượt nạp tại một thời điểm, khỏi nhân đôi số lần gọi portal.
  static bool _dangChay = false;

  /// Lượt nạp gần nhất xong lúc nào — chỉ để xem, không chặn lượt sau: mở
  /// app lần nào cũng phải thử lấy số mới.
  static DateTime? xongLuc;

  static Future<void> run(Session session, {Portal? portal}) => runZoned(
    () => _chay(session, portal),
    zoneValues: {Cache.forceKey: true},
  );

  static Future<void> _chay(Session session, Portal? portal) async {
    if (_dangChay) return;
    _dangChay = true;
    final p = portal ?? Portal();
    final token = session.token;
    final now = DateTime.now();
    final (year, term) = yearTermFor(now);
    try {
      await _thu(() => p.studentInfo(token));
      await _thu(() => p.exams(token));
      await _thu(() => p.messages(token));
      await _thu(() => p.behaviorScores(token));
      await _thu(() => p.behaviorDetail(token, year: year, term: term));
      await _thu(() => p.registrations(token, year: year, term: term));
      final program = await _thu(() => p.studyProgram(token));
      if (program != null) {
        await _thu(() => p.marks(token, program));
        await _thu(() => p.curriculum(token, program));
      }
      // Tháng này, tháng sau, rồi tháng trước: đúng ba tháng mà màn Lịch
      // đụng tới ngay khi mở. Thiếu tháng trước là chip "dữ liệu lúc..."
      // bị ghim vào mốc cũ của nó dù mọi thứ khác vừa lấy mới xong.
      final ngay = <DateTime, List<dynamic>>{};
      for (final m in [
        DateTime(now.year, now.month),
        DateTime(now.year, now.month + 1),
        DateTime(now.year, now.month - 1),
      ]) {
        final d = await _thu(() => fetchMonth(p, token, m));
        if (d == null) continue;
        ngay.addAll({
          for (final e in d.entries) DateTime(m.year, m.month, e.key): e.value,
        });
      }
      // Có lịch mới thì hẹn lại máy rung trước giờ vào lớp. Tháng trước nằm
      // trong đống này nhưng toàn ngày đã qua nên tự bị bỏ.
      await Nhac.datLai(ngay);
      xongLuc = DateTime.now();
    } finally {
      _dangChay = false;
    }
  }

  /// Một mục hỏng (portal lỗi, mất mạng) thì bỏ qua, đừng chặn các mục sau.
  static Future<T?> _thu<T>(Future<T> Function() f) async {
    try {
      return await f();
    } on PortalError {
      return null;
    }
  }
}
