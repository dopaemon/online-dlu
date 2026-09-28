import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:share_plus/share_plus.dart';

import 'clock.dart';
import 'data.dart';
import 'ics.dart';
import 'paper.dart';
import 'portal.dart';

/// Tuần ISO của một ngày — portal đánh số tuần theo chuẩn này (21/09/2026 = 39).
int isoWeek(DateTime d) {
  final thu = d.add(Duration(days: 4 - d.weekday));
  return thu.difference(DateTime(thu.year, 1, 1)).inDays ~/ 7 + 1;
}

/// Lịch học gom theo ngày trong tháng. Key = ngày, giá trị đã sắp theo tiết.
Map<int, List<dynamic>> itemsByDay(Iterable<dynamic> items, DateTime month) {
  final out = <int, List<dynamic>>{};
  for (final i in items) {
    final p = (i['StartDate'] as String).split('/'); // dd/MM/yyyy của thứ 2
    final monday = DateTime(int.parse(p[2]), int.parse(p[1]), int.parse(p[0]));
    final day = monday.add(Duration(days: toNum(i['DayOfWeek']).toInt() - 1));
    if (day.year != month.year || day.month != month.month) continue;
    out.putIfAbsent(day.day, () => []).add(i);
  }
  for (final l in out.values) {
    l.sort(
      (a, b) => toNum(a['PeriodID']).toInt() - toNum(b['PeriodID']).toInt(),
    );
  }
  return out;
}

/// Lịch cả tháng, gom theo ngày. Lấy nguyên tháng chứ không phải từng tuần:
/// tốn đúng mấy lần gọi mà đổi ngày, xem ngày khác đều khỏi đụng tới portal.
Future<Map<int, List<dynamic>>> fetchMonth(
  Portal portal,
  String token,
  DateTime month,
) async {
  final last = DateTime(month.year, month.month + 1, 0);
  final (year, term) = yearTermFor(month);
  final weeks = {
    for (var d = month; !d.isAfter(last); d = d.add(const Duration(days: 1)))
      isoWeek(d),
  };
  final fetched = await Future.wait(
    weeks.map(
      (w) => portal.weekSchedule(token, year: year, term: term, week: w),
    ),
  );
  return itemsByDay(fetched.expand((e) => e), month);
}

int periods(Iterable<dynamic> items) =>
    items.fold(0, (a, i) => a + toNum(i['NumberOfPeriods']).toInt());

/// Tiết 1-6 sáng, 7-10 chiều, 11-14 tối (theo bảng giờ giảng của trường).
String buoi(int periodID) =>
    periodID <= 6 ? 'Sáng' : (periodID <= 10 ? 'Chiều' : 'Tối');

/// Phút bắt đầu của từng tiết theo bảng giờ giảng của trường, mỗi tiết 50 phút.
// ponytail: trường chỉ công bố tiết 1-4, 7-14; tiết 5-6 suy ra tiếp nối tiết 4.
const _batDau = <int, int>{
  1: 7 * 60 + 30,
  2: 8 * 60 + 20,
  3: 9 * 60 + 30,
  4: 10 * 60 + 20,
  5: 11 * 60 + 10,
  6: 12 * 60,
  7: 13 * 60,
  8: 13 * 60 + 50,
  9: 14 * 60 + 50,
  10: 15 * 60 + 40,
  11: 16 * 60 + 40,
  12: 17 * 60 + 30,
  // Buổi tối cũng có giải lao 18h20 - 18h30, nên tiết 13 vào trễ 10 phút.
  13: 18 * 60 + 30,
  14: 19 * 60 + 20,
};

/// Phút bắt đầu của một tiết; tiết lạ thì null để nơi gọi khỏi bịa giờ.
int? batDauPhut(int tiet) => _batDau[tiet];

/// Mỗi tiết 50 phút.
const tietPhut = 50;

String _gio(int phut) =>
    '${phut ~/ 60}h${(phut % 60).toString().padLeft(2, '0')}';

/// Số tiết trong chuỗi portal trả về ('Tiết: 3' -> 3).
int tietNo(Object? v) =>
    int.tryParse(RegExp(r'\d+').firstMatch(clean(v))?.group(0) ?? '') ?? 0;

/// Giờ vào - giờ ra của một dải tiết. Tiết lạ thì trả null để khỏi bịa giờ.
(String, String)? khungGio(int tietDau, int tietCuoi) {
  final dau = _batDau[tietDau];
  final cuoi = _batDau[tietCuoi];
  if (dau == null || cuoi == null) return null;
  return (_gio(dau), _gio(cuoi + tietPhut));
}

/// Buổi sắp tới trong ngày: buổi đầu tiên chưa tan. Tan hết thì null.
dynamic tietKe(List<dynamic> items, DateTime now) {
  final phut = now.hour * 60 + now.minute;
  for (final i in items) {
    final cuoi = batDauPhut(tietNo(i['EndTime']));
    if (cuoi != null && phut < cuoi + tietPhut) return i;
  }
  return null;
}

/// Buổi học đang ở đoạn nào: chưa tới giờ, trong tiết, nghỉ giữa tiết, đã tan.
enum LessonPhase { chuaVao, dangHoc, raChoi, xong }

/// Đoạn hiện tại của một buổi. [tiet] là tiết đang học, hoặc tiết sắp vào khi
/// đang chờ / ra chơi; tan rồi thì null. [conPhut] là số phút còn lại của
/// chính đoạn đó — hết tiết, hết giờ ra chơi, hay tới giờ vào lớp.
typedef LessonNow = ({LessonPhase pha, int? tiet, int conPhut});

/// Buổi [item] đang tới đâu so với [now]. Tiết lạ thì null để khỏi bịa giờ.
///
/// Đi lần lượt từng tiết trong buổi nên buổi 1, 2, 3 hay 4 tiết đều đúng, và
/// khoảng trống giữa hai tiết (tiết 2 tan 9h10, tiết 3 vào 9h30) là ra chơi.
LessonNow? lessonNow(dynamic item, DateTime now) {
  final dau = tietNo(item['BeginTime']);
  final cuoi = tietNo(item['EndTime']);
  final vao = batDauPhut(dau);
  final tietCuoi = batDauPhut(cuoi);
  if (vao == null || tietCuoi == null) return null;
  final phut = now.hour * 60 + now.minute;
  if (phut < vao) {
    return (pha: LessonPhase.chuaVao, tiet: dau, conPhut: vao - phut);
  }
  for (var t = dau; t <= cuoi; t++) {
    final s = batDauPhut(t);
    if (s == null) continue;
    if (phut < s) return (pha: LessonPhase.raChoi, tiet: t, conPhut: s - phut);
    if (phut < s + tietPhut) {
      return (pha: LessonPhase.dangHoc, tiet: t, conPhut: s + tietPhut - phut);
    }
  }
  return (pha: LessonPhase.xong, tiet: null, conPhut: 0);
}

/// Nhãn và màu giấy cho đoạn hiện tại — có số tiết để biết đang ở tiết mấy.
(String, Color) phaseTag(LessonNow n) => switch (n.pha) {
  LessonPhase.chuaVao => ('Chưa vào lớp', Paper.card),
  LessonPhase.dangHoc => ('Đang học tiết ${n.tiet}', Paper.mint),
  LessonPhase.raChoi => ('Ra chơi', Paper.sun),
  LessonPhase.xong => ('Xong', Paper.paper),
};

/// Sắp phải đi rồi: còn 15 phút hoặc ít hơn tới giờ vào lớp.
bool sapToiGio(dynamic item, DateTime now) {
  final n = lessonNow(item, now);
  return n != null && n.pha == LessonPhase.chuaVao && n.conPhut <= 15;
}

/// '45 phút' / '2 giờ' / '1 giờ 5 phút'.
String _khoang(int phut) {
  if (phut < 60) return '$phut phút';
  final le = phut % 60;
  return '${phut ~/ 60} giờ${le == 0 ? '' : ' $le phút'}';
}

/// Còn bao lâu nữa hết đoạn đang chạy. Tan rồi hoặc tiết lạ thì null.
/// Không nhắc lại số tiết khi đang học — nhãn bên cạnh đã ghi rồi.
String? demNguoc(dynamic item, DateTime now) {
  final n = lessonNow(item, now);
  return switch (n?.pha) {
    null || LessonPhase.xong => null,
    LessonPhase.chuaVao => 'Còn ${_khoang(n!.conPhut)} nữa',
    LessonPhase.dangHoc => 'Còn ${_khoang(n!.conPhut)} nữa',
    LessonPhase.raChoi => 'Vào tiết ${n!.tiet} sau ${_khoang(n.conPhut)}',
  };
}

/// Màu ô lịch theo số buổi phải lên lớp trong ngày (sáng/chiều/tối).
Color dayColor(Iterable<dynamic> items) {
  final buoiTrongNgay = items
      .map((i) => buoi(toNum(i['PeriodID']).toInt()))
      .toSet();
  return switch (buoiTrongNgay.length) {
    0 => _nghi,
    1 => _motBuoi,
    2 => _haiBuoi,
    _ => _baBuoi,
  };
}

const _nghi = Color(0xFFF2E7CE); // nghỉ — không có tiết nào
const _motBuoi = Paper.mint; // xanh lá — học 1 buổi
const _haiBuoi = Paper.sky; // xanh dương — học 2 buổi
const _baBuoi = Paper.rose; // đỏ — học cả 3 buổi

/// Năm học / học kỳ của một tháng. HK01 tháng 8-1, HK02 tháng 2-6, HK03 tháng 7.
// ponytail: suy từ lịch chung của trường; nếu trường đổi mốc học kỳ thì sửa ở đây.
(String, String) yearTermFor(DateTime m) {
  final start = m.month >= 8 ? m.year : m.year - 1;
  final term = (m.month >= 8 || m.month == 1)
      ? 'HK01'
      : (m.month == 7 ? 'HK03' : 'HK02');
  return ('$start-${start + 1}', term);
}

/// Contribution graph của một tháng: mỗi ô một ngày, đậm theo số tiết.
class MonthGraph extends StatefulWidget {
  const MonthGraph({
    super.key,
    required this.session,
    required this.now,
    this.portal,
  });
  final Session session;
  final DateTime now;
  final Portal? portal;

  @override
  State<MonthGraph> createState() => _MonthGraphState();
}

class _MonthGraphState extends State<MonthGraph> with Reloadable<MonthGraph> {
  /// Nạp lại tháng đang xem, ghi đè cache trong bộ nhớ.
  @override
  Future<void> reload() async {
    final m = _month;
    try {
      final days = await _fetch(m);
      if (mounted) {
        setState(() {
          _cache[_key(m)] = days;
          _error = null;
        });
      }
    } on PortalError {
      // giữ nguyên lịch cũ
    }
  }

  /// Lịch đã tải, key là 'năm-tháng'. Tháng trước/sau được nạp sẵn nên bấm
  /// mũi tên là có ngay.
  final _cache = <String, Map<int, List<dynamic>>>{};
  String? _error;
  int? _pick; // ngày đang xem, null = hôm nay
  late DateTime _month = DateTime(widget.now.year, widget.now.month);

  Map<int, List<dynamic>>? get _days => _cache[_key(_month)];
  static String _key(DateTime m) => '${m.year}-${m.month}';

  @override
  void initState() {
    super.initState();
    _show(_month);
  }

  void _goto(DateTime m) {
    setState(() {
      _month = m;
      _error = null;
      _pick = null;
    });
    _show(m);
  }

  Future<void> _show(DateTime m) async {
    if (!await _grab(m)) return;
    for (final n in [
      DateTime(m.year, m.month + 1),
      DateTime(m.year, m.month - 1),
    ]) {
      await _grab(n, quiet: true);
    }
  }

  /// Tải một tháng vào cache, trả về false khi lỗi hoặc widget đã đóng.
  Future<bool> _grab(DateTime m, {bool quiet = false}) async {
    if (_cache.containsKey(_key(m))) return true;
    try {
      final days = await _fetch(m);
      if (!mounted) return false;
      setState(() {
        _cache[_key(m)] = days;
        _error = null;
      });
      return true;
    } on PortalError catch (e) {
      if (mounted && !quiet) setState(() => _error = e.message);
      return false;
    }
  }

  Future<Map<int, List<dynamic>>> _fetch(DateTime month) =>
      fetchMonth(widget.portal ?? Portal(), widget.session.token, month);

  /// Chép lịch tháng sang app Lịch của máy qua file .ics.
  /// Hỏi trước vì đây là việc bước ra khỏi app.
  /// Khung để chụp đúng tấm lịch, không dính cả màn hình.
  final _anhKey = GlobalKey();

  /// Chụp tấm lịch thành ảnh rồi đưa vào bảng chia sẻ — gửi cho bạn cùng lớp
  /// nhanh hơn là tả bằng lời.
  Future<void> _chiaSeAnh(DateTime month) async {
    final khung = _anhKey.currentContext?.findRenderObject();
    if (khung is! RenderRepaintBoundary) return;
    // pixelRatio 3: đọc rõ trên màn retina mà file vẫn dưới 1 MB.
    final anh = await khung.toImage(pixelRatio: 3);
    final png = await anh.toByteData(format: ImageByteFormat.png);
    anh.dispose();
    if (png == null) return;
    final ten = 'lich-${month.month}-${month.year}.png';
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            png.buffer.asUint8List(),
            mimeType: 'image/png',
            name: ten,
          ),
        ],
        fileNameOverrides: [ten],
        text: 'Lịch học tháng ${month.month}/${month.year}',
      ),
    );
  }

  Future<void> _xuatLich(DateTime month) async {
    final days = _days;
    if (days == null) return;
    final n = icsCount(days);
    final ok = await confirmDialog(
      context,
      title: 'Thêm lịch tháng ${month.month}/${month.year} vào Lịch?',
      body:
          '$n buổi học sẽ được chép sang ứng dụng Lịch của máy, '
          'kèm nhắc trước giờ vào lớp 15 phút.\n\n'
          'Bấm Thêm rồi chọn Lịch trong danh sách hiện ra.',
      ok: 'Thêm',
    );
    if (!ok || !mounted) return;
    final ten = 'lich-${month.month}-${month.year}.ics';
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            utf8.encode(icsMonth(month, days)),
            mimeType: 'text/calendar',
            name: ten,
          ),
        ],
        fileNameOverrides: [ten],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final month = _month;
    final thisMonth =
        month.year == widget.now.year && month.month == widget.now.month;
    final days = DateTime(month.year, month.month + 1, 0).day;
    final lead = month.weekday - 1; // ô trống trước ngày 1
    final pick = _pick ?? (thisMonth ? widget.now.day : 1);
    return Column(
      children: [
        RepaintBoundary(
          key: _anhKey,
          child: PaperBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _Arrow(
                      icon: Icons.chevron_left_rounded,
                      onTap: () => _goto(DateTime(month.year, month.month - 1)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Semantics(
                        button: true,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () async {
                            final m = await showDialog<DateTime>(
                              context: context,
                              builder: (_) => _MonthPicker(month: month),
                            );
                            if (m != null) _goto(m);
                          },
                          // Chữ cao ~22pt, đệm thêm cho đủ ngưỡng chạm 44pt.
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    'Tháng ${month.month}/${month.year}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Baloo',
                                      fontWeight: FontWeight.w800,
                                      fontSize: 22,
                                      color: Paper.ink,
                                    ),
                                  ),
                                ),
                                const Icon(
                                  Icons.expand_more_rounded,
                                  size: 22,
                                  color: Paper.ink2,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _Arrow(
                      icon: Icons.chevron_right_rounded,
                      onTap: () => _goto(DateTime(month.year, month.month + 1)),
                    ),
                    // Số tiết nằm dưới hàng chú thích: để trên này thì hai nút
                    // mũi tên với nó chen nhau, tên tháng bị cắt mất năm.
                    if (_error != null) ...[
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _error!,
                          maxLines: 2,
                          style: const TextStyle(
                            color: Paper.ink3,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                // Nhãn thứ để ô trống trước ngày 1 nhìn ra là lịch, không phải
                // khoảng hở thừa.
                Row(
                  children: [
                    for (final d in const [
                      'T2',
                      'T3',
                      'T4',
                      'T5',
                      'T6',
                      'T7',
                      'CN',
                    ])
                      Expanded(
                        child: Text(
                          d,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Paper.ink3,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                GridView.count(
                  crossAxisCount: 7,
                  shrinkWrap: true,
                  // Không đặt thì GridView tự chèn padding bằng status bar,
                  // thành ra hở nguyên một hàng phía trên ngày 1.
                  padding: EdgeInsets.zero,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 1.15,
                  crossAxisSpacing: 6,
                  mainAxisSpacing: 6,
                  children: [
                    for (var i = 0; i < lead; i++) const SizedBox(),
                    if (_days == null)
                      for (var d = 1; d <= days; d++)
                        const Skeleton(height: 44, radius: 6, ink: true)
                    else
                      for (var d = 1; d <= days; d++)
                        _Cell(
                          day: d,
                          items: _days?[d] ?? const [],
                          today: thisMonth && d == widget.now.day,
                          picked: d == pick,
                          onTap: () => setState(() => _pick = d),
                        ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const _Legend(color: _motBuoi, label: '1 buổi'),
                    const _Legend(color: _haiBuoi, label: '2 buổi'),
                    const _Legend(color: _baBuoi, label: '3 buổi'),
                    const _Legend(color: _nghi, label: 'Nghỉ'),
                    if (_days == null)
                      const Skeleton(width: 48, height: 12)
                    else
                      Text(
                        '${periods(_days!.values.expand((e) => e))} tiết',
                        style: const TextStyle(
                          color: Paper.ink3,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                  ],
                ),
                if (_days != null && icsCount(_days!) > 0) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      PaperButton(
                        label: 'Thêm vào Lịch',
                        fontSize: 13,
                        color: Paper.mint,
                        onColor: Paper.ink,
                        onPressed: () => _xuatLich(month),
                      ),
                      PaperButton(
                        label: 'Chia sẻ ảnh',
                        fontSize: 13,
                        color: Paper.sky,
                        onColor: Paper.ink,
                        onPressed: () => _chiaSeAnh(month),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _DayCard(
          day: DateTime(month.year, month.month, pick),
          now: thisMonth && pick == widget.now.day ? widget.now : null,
          items: _days?[pick] ?? const [],
          loading: _days == null && _error == null,
          onToday: thisMonth && pick == widget.now.day
              ? null
              : () => _goto(DateTime(widget.now.year, widget.now.month)),
        ),
      ],
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.items,
    required this.loading,
    required this.onToday,
    this.now,
  });
  final DateTime day;
  final DateTime? now;
  final List<dynamic> items;
  final bool loading;
  final VoidCallback? onToday;

  @override
  Widget build(BuildContext context) => PaperBox(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${dayNames[day.weekday]}, ${day.day}/${day.month}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Baloo',
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: Paper.ink,
                ),
              ),
            ),
            if (onToday != null)
              PaperButton(
                label: 'Xem ngày hôm nay',
                fontSize: 13,
                color: Paper.sky,
                onColor: Paper.ink,
                onPressed: onToday!,
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (loading)
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Skeleton(width: 190, height: 16),
              SizedBox(height: 10),
              Skeleton(width: 240, height: 24, radius: 12),
              SizedBox(height: 10),
              Skeleton(width: 130, height: 12),
            ],
          )
        else if (items.isEmpty)
          Container(
            color: Paper.sun,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: const Text(
              'Không có tiết',
              style: TextStyle(
                fontFamily: 'Baloo',
                fontWeight: FontWeight.w800,
                fontSize: 30,
                height: 1.25,
                color: Paper.ink,
              ),
            ),
          )
        else
          for (final (n, i) in items.indexed)
            _Lesson(
              i,
              delay: Duration(milliseconds: 70 * n),
              now: now,
            ),
      ],
    ),
  );
}

class _Lesson extends StatelessWidget {
  const _Lesson(this.i, {this.delay = Duration.zero, this.now});
  final dynamic i;
  final Duration delay;

  /// Chỉ ngày hôm nay mới có trạng thái; ngày khác để null.
  final DateTime? now;

  @override
  Widget build(BuildContext context) {
    final dau = tietNo(i['BeginTime']);
    final cuoi = tietNo(i['EndTime']);
    final gio = khungGio(dau, cuoi);
    final pha = now == null ? null : lessonNow(i, now!);
    return PopIn(
      delay: delay,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Cột giờ vào - giờ ra, nối bằng một vạch cho ra dáng timeline.
              if (gio != null) ...[
                SizedBox(
                  width: 46,
                  child: Column(
                    children: [
                      Text(
                        gio.$1,
                        style: const TextStyle(
                          fontFamily: 'Baloo',
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          color: Paper.ink,
                        ),
                      ),
                      Expanded(
                        child: Center(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 3),
                            color: Paper.ink3,
                          ),
                        ),
                      ),
                      Text(
                        gio.$2,
                        style: const TextStyle(fontSize: 13, color: Paper.ink3),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      clean(i['CurriculumName']),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Paper.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (pha != null)
                          Pill(phaseTag(pha).$1, color: phaseTag(pha).$2),
                        Pill('Tiết $dau-$cuoi', color: Paper.sun),
                        Pill(buoi(dau), color: Paper.mint),
                        Pill('Phòng ${i['RoomID']}', color: Paper.sky),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'GV: ${i['FullName'] ?? '—'}',
                      style: const TextStyle(fontSize: 13, color: Paper.ink2),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Ô màu + tên buổi trong phần chú thích.
class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: color,
          border: Border.all(color: Paper.ink, width: 1.5),
          borderRadius: BorderRadius.circular(4),
        ),
      ),
      const SizedBox(width: 5),
      Text(label, style: const TextStyle(color: Paper.ink3, fontSize: 12)),
    ],
  );
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.day,
    required this.items,
    required this.today,
    required this.picked,
    required this.onTap,
  });
  final int day;
  final List<dynamic> items;
  final bool today, picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => PopIn(
    // Lần lượt từng ngày cho ra hiệu ứng lướt qua tháng.
    delay: Duration(milliseconds: 8 * day),
    child: Pressable(
      onTap: onTap,
      builder: (down) => Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: dayColor(items),
          border: Border.all(color: Paper.ink, width: picked ? 3 : 1.5),
          borderRadius: BorderRadius.circular(6),
          boxShadow: picked ? Paper.shadow(down ? 0 : 2) : null,
        ),
        child: Text(
          '$day',
          style: TextStyle(
            fontSize: 12,
            color: Paper.ink,
            fontWeight: today ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
      ),
    ),
  );
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  // Nút bé tí thì khó bấm: đệm cho đủ 44pt theo chuẩn HIG.
  Widget build(BuildContext context) => Semantics(
    button: true,
    child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Paper.card,
          border: Paper.border,
          borderRadius: BorderRadius.circular(10),
          boxShadow: Paper.shadow(2),
        ),
        child: Icon(icon, size: 20, color: Paper.ink),
      ),
    ),
  );
}

/// Chọn tháng / năm: một tờ giấy với 12 ô tháng và năm đổi bằng mũi tên.
class _MonthPicker extends StatefulWidget {
  const _MonthPicker({required this.month});
  final DateTime month;

  @override
  State<_MonthPicker> createState() => _MonthPickerState();
}

class _MonthPickerState extends State<_MonthPicker> {
  late int _year = widget.month.year;

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: Colors.transparent,
    child: Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Paper.paper,
        border: Paper.border,
        borderRadius: BorderRadius.circular(20),
        boxShadow: Paper.shadow(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _Arrow(
                icon: Icons.chevron_left_rounded,
                onTap: () => setState(() => _year--),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '$_year',
                  style: const TextStyle(
                    fontFamily: 'Baloo',
                    fontWeight: FontWeight.w800,
                    fontSize: 22,
                    color: Paper.ink,
                  ),
                ),
              ),
              _Arrow(
                icon: Icons.chevron_right_rounded,
                onTap: () => setState(() => _year++),
              ),
            ],
          ),
          const SizedBox(height: 14),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 1.6,
            children: [
              for (var m = 1; m <= 12; m++)
                Semantics(
                  button: true,
                  child: GestureDetector(
                    onTap: () => Navigator.pop(context, DateTime(_year, m)),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color:
                            m == widget.month.month &&
                                _year == widget.month.year
                            ? Paper.sun
                            : Paper.card,
                        border: Paper.border,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: Paper.shadow(2),
                      ),
                      child: Text(
                        'Th $m',
                        style: const TextStyle(
                          fontFamily: 'Baloo',
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: Paper.ink,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Tiết của hôm nay, tự ẩn nếu hôm nay nghỉ.
class TodayLessons extends StatefulWidget {
  const TodayLessons({super.key, required this.session, this.portal});
  final Session session;
  final Portal? portal;

  @override
  State<TodayLessons> createState() => _TodayLessonsState();
}

class _TodayLessonsState extends State<TodayLessons>
    with Reloadable<TodayLessons> {
  @override
  Future<void> reload() => _load(DateTime.now(), lai: true);

  /// Lịch theo ngày tuyệt đối, gồm tháng này và tháng sau. Nạp sẵn cả khối
  /// nên 0h00 qua ngày mới là hiện luôn tiết hôm sau, và ngày cuối tháng
  /// vẫn xem trước được ngày mai — không phải hỏi lại portal lần nào.
  Map<DateTime, List<dynamic>>? _ngay;
  DateTime? _thang;
  bool _dangTai = false;

  @override
  void initState() {
    super.initState();
    _load(Clock.instance.value);
  }

  Future<void> _load(DateTime now, {bool lai = false}) async {
    final thang = DateTime(now.year, now.month);
    if (_dangTai || (!lai && _thang == thang)) return;
    _dangTai = true;
    final p = widget.portal ?? Portal();
    try {
      final ngay = await _theoNgay(p, thang);
      // Tháng sau nữa: ngày cuối tháng thì "Ngày mai" nằm bên đó. Prefetch
      // đã kéo sẵn ba tháng vào cache nên lượt này thường không đụng portal.
      try {
        ngay.addAll(await _theoNgay(p, DateTime(thang.year, thang.month + 1)));
      } on PortalError {
        // Thiếu tháng sau thì chỉ mất mục xem trước, hôm nay vẫn hiện.
      }
      if (mounted) {
        setState(() {
          _ngay = ngay;
          _thang = thang;
        });
      }
    } on PortalError {
      if (mounted) setState(() => _ngay ??= const {});
    } finally {
      _dangTai = false;
    }
  }

  /// Lịch một tháng, đổi khoá từ ngày-trong-tháng sang ngày tuyệt đối để
  /// nhiều tháng gộp chung một map mà không đụng khoá nhau.
  Future<Map<DateTime, List<dynamic>>> _theoNgay(
    Portal p,
    DateTime thang,
  ) async {
    final d = await fetchMonth(p, widget.session.token, thang);
    return {
      for (final e in d.entries)
        DateTime(thang.year, thang.month, e.key): e.value,
    };
  }

  @override
  Widget build(BuildContext context) => Ticker(
    builder: (context, now) {
      // Sang tháng mới thì mới phải gọi portal, còn sang ngày mới thì dữ
      // liệu đã nằm sẵn trong máy.
      if (_thang != null && _thang != DateTime(now.year, now.month)) {
        scheduleMicrotask(() => _load(now));
      }
      if (_ngay == null) {
        return const Padding(
          padding: EdgeInsets.only(bottom: 20),
          child: Skeleton(height: 120, radius: 16, ink: true),
        );
      }
      final homNay = DateTime(now.year, now.month, now.day);
      final items = _ngay![homNay] ?? const [];
      final ke = tietKe(items, now);
      // Hôm nay tan hết (hay hôm nay nghỉ) thì nhìn trước ngày mai luôn. Qua
      // 0h00 là homNay nhích lên, mục "Ngày mai" tự thành "Hôm nay".
      final maiItems = ke == null
          ? (_ngay![homNay.add(const Duration(days: 1))] ?? const [])
          : const [];
      if (items.isEmpty && maiItems.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (items.isNotEmpty)
              _Ngay(tieuDe: 'Hôm nay', items: items, ke: ke, now: now),
            if (maiItems.isNotEmpty) ...[
              if (items.isNotEmpty) const SizedBox(height: 20),
              _Ngay(tieuDe: 'Ngày mai', items: maiItems),
            ],
          ],
        ),
      );
    },
  );
}

/// Một ngày trên Trang chủ: tiêu đề, thẻ nổi cho buổi sắp tới rồi cả danh
/// sách. Ngày mai thì [now] để null — chưa tới nên chưa có trạng thái gì.
class _Ngay extends StatelessWidget {
  const _Ngay({required this.tieuDe, required this.items, this.ke, this.now});
  final String tieuDe;
  final List<dynamic> items;
  final dynamic ke;
  final DateTime? now;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        tieuDe,
        style: const TextStyle(
          fontFamily: 'Baloo',
          fontWeight: FontWeight.w800,
          fontSize: 22,
          color: Paper.ink,
        ),
      ),
      const SizedBox(height: 10),
      if (ke != null && now != null) ...[
        _TietKe(item: ke, now: now!),
        const SizedBox(height: 10),
      ],
      PaperBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (n, i) in items.indexed)
              _Lesson(
                i,
                delay: Duration(milliseconds: 70 * n),
                now: now,
              ),
          ],
        ),
      ),
    ],
  );
}

/// Thẻ nổi cho buổi sắp tới: mở app ra là biết đi đâu, còn bao lâu.
class _TietKe extends StatelessWidget {
  const _TietKe({required this.item, required this.now});
  final dynamic item;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final dau = tietNo(item['BeginTime']);
    final cuoi = tietNo(item['EndTime']);
    final gio = khungGio(dau, cuoi);
    final con = demNguoc(item, now);
    final pha = lessonNow(item, now);
    final gap = sapToiGio(item, now);
    // Còn 15 phút thì đổi cả thẻ sang màu cảnh báo, liếc một cái là thấy.
    final mau = gap
        ? Paper.rose
        : (pha == null ? Paper.card : phaseTag(pha).$2);
    return PaperBox(
      color: gap ? Paper.peach : Paper.sun,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Nhãn theo trạng thái thật: chưa vào lớp / đang học / ra chơi.
              Pill(
                gap
                    ? 'Sắp vào lớp'
                    : (pha == null ? 'Sắp tới' : phaseTag(pha).$1),
                color: mau,
              ),
              if (con != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    con,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'Baloo',
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Paper.ink,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            subjectName(item['CurriculumName']),
            style: const TextStyle(
              fontFamily: 'Baloo',
              fontWeight: FontWeight.w800,
              fontSize: 20,
              height: 1.15,
              color: Paper.ink,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (gio != null) Pill('${gio.$1} - ${gio.$2}', color: Paper.card),
              Pill('Phòng ${item['RoomID']}', color: Paper.card),
              Pill('Tiết $dau-$cuoi', color: Paper.card),
            ],
          ),
        ],
      ),
    );
  }
}
