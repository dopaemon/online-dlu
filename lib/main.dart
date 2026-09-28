import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'behavior.dart';
import 'cache.dart';
import 'clock.dart';
import 'courses.dart';
import 'curriculum.dart';
import 'data.dart';
import 'exams.dart';
import 'graph.dart';
import 'info.dart';
import 'login.dart';
import 'marks.dart';
import 'news.dart';
import 'paper.dart';
import 'portal.dart';
import 'prefetch.dart';
import 'update_check.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Nền giấy luôn sáng, nên ép icon status bar / nav bar màu mực.
  // Không đặt thì Android vẽ icon trắng, mất tiêu trên nền kem.
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  await Cache.init();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'DLU Online',
    debugShowCheckedModeBanner: false,
    theme: Paper.theme(),
    // App chỉ có một bộ màu giấy; khai báo hẳn để máy đang dark mode
    // không bị Material tự chế biến thêm.
    themeMode: ThemeMode.light,
    // Cỡ chữ hệ thống to quá thì thanh tab và lưới lịch vỡ hàng; chặn ở 1.3.
    builder: (context, child) =>
        MediaQuery.withClampedTextScaling(maxScaleFactor: 1.3, child: child!),
    home: const Root(),
  );
}

/// Decides between the login screen and the app: with saved credentials we log
/// in again on every cold start, since the portal token only lives ~2h.
class Root extends StatefulWidget {
  const Root({super.key});

  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  Session? _session;
  String? _error;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resume();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Mở app lần nào cũng thử lấy số mới: màn hiện số trong máy ngay, lượt
  /// tải chạy song song. Token còn hạn thì khỏi đăng nhập lại.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final s = _session;
    if (s == null || !s.valid) {
      _resume();
    } else {
      unawaited(_napSan(s));
    }
  }

  Future<void> _resume() async {
    final saved = await Vault.read();
    if (saved == null) return setState(() => _checking = false);

    // Có phiên cũ thì vào app ngay, đăng nhập lại chạy ngầm.
    final cached = Cache.read('session')?.$1;
    if (cached != null) {
      _session = Session.fromMap(Map<String, dynamic>.from(cached as Map));
    }
    if (mounted) setState(() => _checking = _session == null);

    try {
      final s = await Portal().login(saved.$1, saved.$2);
      await Cache.write('session', s.toMap());
      if (mounted) setState(() => _session = s);
      // Vào app bằng phiên cũ thì token đã hết hạn (~2h), mọi màn nạp bằng nó
      // đều hỏng và nằm trống. Có token mới là nạp lại hết, đừng để người
      // dùng phải kéo xuống mới thấy hôm nay học gì.
      if (cached != null && mounted) await Cache.reloadAll();
      unawaited(_napSan(s));
    } on PortalError catch (e) {
      // Mạng hỏng thì cứ xài cache; sai mật khẩu mới đá về màn đăng nhập.
      if (e.offline && _session != null) return;
      await Vault.clear();
      await Cache.clear();
      if (mounted) {
        setState(() {
          _session = null;
          _error = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// Nạp sẵn phần còn lại cho offline, xong thì giao lại cho màn đang mở.
  Future<void> _napSan(Session s) async {
    await Prefetch.run(s);
    if (mounted) await Cache.reloadAll();
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: const [
                Skeleton(width: 220, height: 34, radius: 10),
                SizedBox(height: 20),
                Skeleton(height: 120, radius: 16, ink: true),
                SizedBox(height: 16),
                Skeleton(height: 320, radius: 16, ink: true),
              ],
            ),
          ),
        ),
      );
    }
    if (_session == null) {
      return LoginScreen(
        initialError: _error,
        onLoggedIn: (s) async {
          await Cache.write('session', s.toMap());
          unawaited(_napSan(s));
          if (mounted) {
            setState(() {
              _session = s;
              _error = null;
            });
          }
        },
      );
    }
    return Shell(
      session: _session!,
      onLogout: () async {
        await Vault.clear();
        await Cache.clear();
        if (mounted) setState(() => _session = null);
      },
    );
  }
}

/// Vỏ app: nội dung + thanh điều hướng giấy cắt dán ở đáy.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.session, required this.onLogout});
  final Session session;
  final VoidCallback onLogout;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 2; // mở app là Trang chủ

  @override
  // Nút back Android: đang ở tab khác thì về Trang chủ, ở Trang chủ mới thoát.
  Widget build(BuildContext context) => PopScope(
    canPop: _tab == 2,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) setState(() => _tab = 2);
    },
    child: Scaffold(
      body: DotBackground(
        child: Stack(
          children: [
            IndexedStack(
              index: _tab,
              children: [
                ScheduleTab(session: widget.session),
                ExamsTab(session: widget.session),
                HomeTab(
                  session: widget.session,
                  onGo: (i) => setState(() => _tab = i),
                ),
                MarksScreen(session: widget.session),
                InfoScreen(session: widget.session, onLogout: widget.onLogout),
              ],
            ),
            // nội dung cuộn xuống dưới status bar, làm mờ cho mượt
            const _TopBlur(),
            Align(
              alignment: Alignment.bottomCenter,
              child: PaperBar(
                index: _tab,
                onTap: (i) => setState(() => _tab = i),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Dải mờ dưới status bar để chữ cuộn qua không đè lên giờ / pin.
class _TopBlur extends StatelessWidget {
  const _TopBlur();

  @override
  // Chỉ là dải gradient màu giấy: BackdropFilter làm mờ cả khung hình
  // mỗi frame trong khi nền vốn đã một màu, nhìn không khác gì.
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: IgnorePointer(
      child: Container(
        height: MediaQuery.paddingOf(context).top,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Paper.paper, Paper.paper.withValues(alpha: 0)],
          ),
        ),
      ),
    ),
  );
}

/// Thanh đáy kiểu giấy cắt: nền kem, viền mực, bóng cứng, tab đang chọn là
/// một mẩu giấy màu dán hơi lệch phía sau icon.
class PaperBar extends StatelessWidget {
  const PaperBar({super.key, required this.index, required this.onTap});
  final int index;
  final ValueChanged<int> onTap;

  /// icon, ảnh (nếu có), nhãn, màu giấy, độ nghiêng.
  static const _items = <(IconData?, String?, String, Color, double)>[
    (Icons.calendar_month_rounded, null, 'Lịch', Paper.sun, -0.06),
    (Icons.edit_note_rounded, null, 'Thi', Paper.rose, 0.04),
    (null, 'assets/logo_icon.png', 'Trang chủ', Paper.peach, 0.0),
    (Icons.grade_rounded, null, 'Điểm', Paper.accent, -0.04),
    (Icons.badge_rounded, null, 'Hồ sơ', Paper.sky, 0.05),
  ];

  @override
  Widget build(BuildContext context) => SafeArea(
    top: false,
    child: Container(
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Paper.card,
        border: Paper.border,
        borderRadius: const BorderRadius.all(Radius.circular(24)),
        boxShadow: Paper.shadow(5),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < _items.length; i++)
            _Tab(item: _items[i], on: i == index, onTap: () => onTap(i)),
        ],
      ),
    ),
  );
}

class _Tab extends StatelessWidget {
  const _Tab({required this.item, required this.on, required this.onTap});
  final (IconData?, String?, String, Color, double) item;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final (icon, asset, label, color, tilt) = item;
    return Semantics(
      selected: on,
      child: Pressable(
        onTap: onTap,
        builder: (down) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Transform.rotate(
                angle: on ? tilt : 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: on ? color : Colors.transparent,
                    border: on ? Paper.border : null,
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                    boxShadow: on ? Paper.shadow(down ? 0 : 3) : null,
                  ),
                  child: asset != null
                      ? Opacity(
                          opacity: on ? 1 : 0.55,
                          child: Image.asset(
                            asset,
                            width: 26,
                            height: 26,
                            excludeFromSemantics: true,
                          ),
                        )
                      : Icon(
                          icon,
                          size: 22,
                          color: on ? Paper.ink : Paper.ink3,
                        ),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'Baloo',
                  fontSize: 12,
                  fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                  color: on ? Paper.ink : Paper.ink3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.session, required this.onGo});
  final Session session;
  final ValueChanged<int> onGo;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with Reloadable<HomeTab> {
  @override
  Future<void> reload() => _load();

  /// Lớp sinh viên chỉ có ở /api/student/info, nạp một lần khi mở app.
  String? _lop;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final i = await Portal().studentInfo(widget.session.token);
      if (mounted) setState(() => _lop = i['LopSinhVien'] as String?);
    } on PortalError {
      // giữ lớp cũ
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 940),
        child: PullRefresh(
          child: ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.paddingOf(context).top + 20,
              20,
              MediaQuery.paddingOf(context).bottom + 110,
            ),
            children: [
              Ticker(
                builder: (_, now) => _Header(now: now, session: widget.session),
              ),
              const SizedBox(height: 16),
              const UpdateBanner(),
              // Các thẻ hiện ra lần lượt cho đỡ khô khan.
              PopIn(
                child: _Me(session: widget.session, lop: _lop),
              ),
              const SizedBox(height: 20),
              PopIn(
                delay: const Duration(milliseconds: 70),
                child: TodayLessons(session: widget.session),
              ),
              PopIn(
                delay: const Duration(milliseconds: 140),
                child: Ticker(
                  builder: (_, now) =>
                      _NextExam(session: widget.session, now: now),
                ),
              ),
              PopIn(
                delay: const Duration(milliseconds: 180),
                child: _Menu(onGo: widget.onGo, session: widget.session),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.now, required this.session});
  final DateTime now;
  final Session session;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Đại Học Đà Lạt',
              style: TextStyle(
                fontFamily: 'Baloo',
                fontWeight: FontWeight.w800,
                fontSize: 34,
                height: 1.1,
                color: Paper.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${dayNames[now.weekday]}, ${now.day}/${now.month}/${now.year}',
              style: const TextStyle(color: Paper.ink2, fontSize: 14),
            ),
            // Mất mạng thì app vẫn hiện số cũ; nói rõ cũ từ lúc nào.
            if (Cache.syncedAt != null) ...[
              const SizedBox(height: 6),
              Pill(dataAge(Cache.syncedAt!, now), color: Paper.card),
            ],
          ],
        ),
      ),
      const SizedBox(width: 12),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Bell(session: session),
      ),
    ],
  );
}

class _Me extends StatelessWidget {
  const _Me({required this.session, required this.lop});
  final Session session;
  final String? lop;

  @override
  Widget build(BuildContext context) => PaperBox(
    color: Paper.sun,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          session.fullName,
          style: const TextStyle(
            fontFamily: 'Baloo',
            fontWeight: FontWeight.w800,
            fontSize: 22,
            height: 1.2,
            color: Paper.ink,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'MSSV ${session.id}',
          style: Paper.mono.copyWith(fontSize: 15, color: Paper.ink),
        ),
        const SizedBox(height: 2),
        Text(
          'Lớp ${lop ?? '…'}',
          style: const TextStyle(fontSize: 15, color: Paper.ink2),
        ),
      ],
    ),
  );
}

/// Tab Lịch: chỉ có biểu đồ tháng.
class ScheduleTab extends StatelessWidget {
  const ScheduleTab({super.key, required this.session});
  final Session session;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 940),
      child: PullRefresh(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            MediaQuery.paddingOf(context).top + 20,
            20,
            MediaQuery.paddingOf(context).bottom + 110,
          ),
          children: [
            const Text(
              'Thời khoá biểu',
              style: TextStyle(
                fontFamily: 'Baloo',
                fontWeight: FontWeight.w800,
                fontSize: 30,
                color: Paper.ink,
              ),
            ),
            const SizedBox(height: 12),
            Ticker(
              builder: (_, now) => MonthGraph(session: session, now: now),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Ca thi gần nhất còn lại, lấy từ cùng API với tab Thi.
class _NextExam extends StatefulWidget {
  const _NextExam({required this.session, required this.now});
  final Session session;
  final DateTime now;

  @override
  State<_NextExam> createState() => _NextExamState();
}

class _NextExamState extends State<_NextExam> with Reloadable<_NextExam> {
  List<dynamic>? _exams;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Future<void> reload() => _load();

  Future<void> _load() async {
    try {
      final e = await Portal().exams(widget.session.token);
      if (mounted) setState(() => _exams = e);
    } on PortalError {
      if (mounted) setState(() => _exams ??= const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_exams == null) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 20),
        child: Skeleton(height: 120, radius: 16, ink: true),
      );
    }
    final today = DateTime(widget.now.year, widget.now.month, widget.now.day);
    final next = sortExams(_exams!, today)
        .where((e) => !parseDMY(e['NgayThi'] as String).isBefore(today))
        .firstOrNull;
    if (next == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Sắp thi',
            style: TextStyle(
              fontFamily: 'Baloo',
              fontWeight: FontWeight.w800,
              fontSize: 22,
              color: Paper.ink,
            ),
          ),
          const SizedBox(height: 10),
          ExamCard(next, today: today),
        ],
      ),
    );
  }
}

/// Thẻ menu: bấm là nhảy qua tab tương ứng.
class _Menu extends StatelessWidget {
  const _Menu({required this.onGo, required this.session});
  final ValueChanged<int> onGo;
  final Session session;

  /// tab -1 = mở trang riêng thay vì chuyển tab.
  static const _items = [
    (0, Icons.calendar_month_rounded, 'Thời khoá biểu', Paper.sun),
    (1, Icons.edit_note_rounded, 'Lịch thi', Paper.rose),
    (3, Icons.grade_rounded, 'Điểm', Paper.accent),
    (-1, Icons.menu_book_rounded, 'Học phần', Paper.mint),
    (-2, Icons.emoji_events_rounded, 'Điểm rèn luyện', Paper.peach),
    (-4, Icons.fact_check_rounded, 'Phiếu rèn luyện', Paper.mint),
    (-3, Icons.school_rounded, 'Chương trình đào tạo', Paper.sky),
    (4, Icons.badge_rounded, 'Hồ sơ', Paper.sky),
  ];

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        'Menu',
        style: TextStyle(
          fontFamily: 'Baloo',
          fontWeight: FontWeight.w800,
          fontSize: 22,
          color: Paper.ink,
        ),
      ),
      const SizedBox(height: 10),
      _khung(context),
    ],
  );

  Widget _khung(BuildContext context) => PaperBox(
    child: Column(
      children: [
        for (final (tab, icon, label, color) in _items)
          Pressable(
            onTap: () => tab >= 0
                ? onGo(tab)
                : Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => switch (tab) {
                        -1 => CoursesTab(session: session),
                        -2 => BehaviorScreen(session: session),
                        -4 => BehaviorDetailScreen(session: session),
                        _ => CurriculumScreen(session: session),
                      },
                    ),
                  ),
            builder: (down) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: color,
                      border: Paper.border,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: Paper.shadow(down ? 0 : 2),
                    ),
                    child: Icon(icon, size: 20, color: Paper.ink),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'Baloo',
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                        color: Paper.ink,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: Paper.ink3),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
