import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data.dart';
import 'nhac.dart';
import 'paper.dart';
import 'portal.dart';

/// Hồ sơ sinh viên, đọc từ `/api/student/info`.
class InfoScreen extends StatefulWidget {
  const InfoScreen({
    super.key,
    required this.session,
    required this.onLogout,
    this.portal,
  });
  final Session session;
  final VoidCallback onLogout;
  final Portal? portal;

  @override
  State<InfoScreen> createState() => _InfoScreenState();
}

/// Nhóm thông tin: tiêu đề, màu giấy, rồi (icon, nhãn, key).
const _groups = <(String, Color, List<(IconData, String, String)>)>[
  (
    'Học vụ',
    Paper.mint,
    [
      (Icons.class_rounded, 'Lớp', 'LopSinhVien'),
      (Icons.school_rounded, 'Khoá học', 'KhoaHoc'),
      (Icons.event_rounded, 'Niên khoá', 'NienKhoa'),
      (Icons.verified_rounded, 'Tình trạng', 'TinhTrangHoc'),
      (Icons.support_agent_rounded, 'Cố vấn học tập', 'CoVanHocTap'),
    ],
  ),
  (
    'Liên hệ',
    Paper.sky,
    [
      (Icons.phone_rounded, 'Di động', 'DiDong'),
      (Icons.alternate_email_rounded, 'Email trường', 'EmailTruong'),
      (Icons.mail_outline_rounded, 'Email cá nhân', 'EmailCaNhan'),
      (Icons.home_rounded, 'Địa chỉ', 'DiaChi'),
      (Icons.location_city_rounded, 'Tỉnh/Thành', 'TinhThanh'),
      (Icons.map_rounded, 'Quận/Huyện', 'QuanHuyen'),
      (Icons.flag_rounded, 'Quốc gia', 'QuocGia'),
    ],
  ),
  (
    'Cá nhân',
    Paper.peach,
    [
      (Icons.cake_rounded, 'Ngày sinh', 'NgaySinh'),
      (Icons.wc_rounded, 'Giới tính', 'GioiTinh'),
      (Icons.badge_rounded, 'CMND/CCCD', 'CMND'),
      (Icons.groups_rounded, 'Dân tộc', 'DanToc'),
      (Icons.temple_buddhist_rounded, 'Tôn giáo', 'TonGiao'),
    ],
  ),
];

/// Nhấn giữ là copy — số điện thoại, email, CCCD toàn thứ phải dán đi chỗ khác.
Widget copyable(BuildContext context, String text, Widget child) =>
    GestureDetector(
      // Không có opaque thì chỉ đúng chữ mới bắt được, khoảng trống bên cạnh
      // nhấn giữ không ăn.
      behavior: HitTestBehavior.opaque,
      onLongPress: text.isEmpty
          ? null
          : () {
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Đã copy: $text'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
      child: child,
    );

/// Portal trả sai vài ô, sửa lại cho đúng trước khi hiện.
String field(Map<String, dynamic> info, String key) {
  final mssv = clean(info['MaSinhVien']);
  if (key == 'EmailTruong') return mssv.isEmpty ? '' : '$mssv@dlu.edu.vn';
  final v = clean(info[key]);
  if (key == 'QuocGia' && v.toLowerCase().replaceAll(' ', '') == 'vietnam') {
    return 'Việt Nam';
  }
  return v;
}

class _InfoScreenState extends State<InfoScreen> with Reloadable<InfoScreen> {
  @override
  Future<void> reload() => _load();

  Map<String, dynamic>? _info;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await (widget.portal ?? Portal()).studentInfo(
        widget.session.token,
      );
      if (mounted) {
        setState(() {
          _info = info;
          _error = null;
        });
      }
    } on PortalError catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

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
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Hồ sơ sinh viên',
                    style: TextStyle(
                      fontFamily: 'Baloo',
                      fontWeight: FontWeight.w800,
                      fontSize: 30,
                      color: Paper.ink,
                    ),
                  ),
                ),
                if (Navigator.of(context).canPop())
                  PaperButton(
                    label: 'Quay lại',
                    color: Paper.card,
                    onColor: Paper.ink,
                    onPressed: () => Navigator.pop(context),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              PaperBox(
                color: Paper.rose,
                child: Text(_error!, style: const TextStyle(color: Paper.ink)),
              )
            else if (_info == null)
              PaperBox(
                child: Column(
                  children: [
                    for (var i = 0; i < 8; i++)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          children: [
                            Skeleton(width: 110, height: 13),
                            SizedBox(width: 20),
                            Expanded(child: Skeleton(height: 15)),
                          ],
                        ),
                      ),
                  ],
                ),
              )
            else ...[
              _Card(info: _info!),
              _StudentCard(info: _info!),
              for (final (title, color, fields) in _groups)
                _Group(
                  title: title,
                  color: color,
                  fields: fields,
                  info: _info!,
                ),
            ],
            const SizedBox(height: 20),
            const _NhacToggle(),
            const SizedBox(height: 20),
            PaperButton(label: 'Đăng xuất', onPressed: widget.onLogout),
            const SizedBox(height: 40),
          ],
        ),
      ),
    ),
  );
}

/// Công tắc nhắc trước giờ vào lớp. Tắt ở đây thì xoá hết lịch hẹn đang
/// chờ; bật lại thì lượt nạp sau đặt lại từ đầu.
class _NhacToggle extends StatefulWidget {
  const _NhacToggle();

  @override
  State<_NhacToggle> createState() => _NhacToggleState();
}

class _NhacToggleState extends State<_NhacToggle> {
  bool? _bat;

  /// Máy có cho hẹn đúng phút không — không thì nhắc vẫn chạy nhưng được
  /// phép trễ, nên phải nói thẳng ra chứ đừng hứa suông 15 phút.
  bool _chinhXac = true;

  @override
  void initState() {
    super.initState();
    _doc();
  }

  Future<void> _doc() async {
    final bat = await Nhac.bat();
    final chinhXac = await Nhac.chinhXacDuoc();
    if (mounted) {
      setState(() {
        _bat = bat;
        _chinhXac = chinhXac;
      });
    }
  }

  Future<void> _doi(bool v) async {
    setState(() => _bat = v);
    await Nhac.datBat(v);
  }

  @override
  Widget build(BuildContext context) {
    final bat = _bat;
    if (bat == null) return const Skeleton(height: 64, radius: 16, ink: true);
    return Column(
      children: [
        PaperBox(
          color: bat ? Paper.mint : Paper.card,
          child: Row(
            children: [
              Icon(
                bat
                    ? Icons.notifications_active_rounded
                    : Icons.notifications_off_rounded,
                color: Paper.ink,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Nhắc trước giờ vào lớp',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: Paper.ink,
                      ),
                    ),
                    Text(
                      bat ? 'Báo trước 15 phút' : 'Đang tắt',
                      style: const TextStyle(fontSize: 13, color: Paper.ink2),
                    ),
                  ],
                ),
              ),
              Switch(
                value: bat,
                onChanged: _doi,
                activeThumbColor: Paper.ink,
                activeTrackColor: Paper.sun,
              ),
            ],
          ),
        ),
        if (bat && !_chinhXac) ...[
          const SizedBox(height: 10),
          PaperBox(
            color: Paper.peach,
            onTap: () async {
              await Nhac.xinChinhXac();
              await _doc();
            },
            child: const Row(
              children: [
                Icon(Icons.alarm_rounded, color: Paper.ink),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Máy đang chặn báo thức chính xác nên nhắc có thể trễ. '
                    'Bấm để mở phần cấp quyền.',
                    style: TextStyle(fontSize: 13, color: Paper.ink),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Thẻ đầu trang: tên + mã số + lớp.
class _Card extends StatelessWidget {
  const _Card({required this.info});
  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: PaperBox(
      color: Paper.sun,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Paper.paper,
              border: Paper.border,
              borderRadius: BorderRadius.circular(16),
              boxShadow: Paper.shadow(2),
            ),
            child: const Icon(Icons.person_rounded, size: 30, color: Paper.ink),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                copyable(
                  context,
                  clean(info['HoTen']),
                  Text(
                    clean(info['HoTen']),
                    style: const TextStyle(
                      fontFamily: 'Baloo',
                      fontWeight: FontWeight.w800,
                      fontSize: 22,
                      height: 1.1,
                      color: Paper.ink,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    copyable(
                      context,
                      clean(info['MaSinhVien']),
                      Pill(clean(info['MaSinhVien']), color: Paper.paper),
                    ),
                    if (clean(info['LopSinhVien']).isNotEmpty)
                      Pill(clean(info['LopSinhVien']), color: Paper.mint),
                    if (clean(info['TinhTrangHoc']).isNotEmpty)
                      Pill(clean(info['TinhTrangHoc']), color: Paper.sky),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Một nhóm thông tin, bỏ qua ô trống.
class _Group extends StatelessWidget {
  const _Group({
    required this.title,
    required this.color,
    required this.fields,
    required this.info,
  });
  final String title;
  final Color color;
  final List<(IconData, String, String)> fields;
  final Map<String, dynamic> info;

  @override
  Widget build(BuildContext context) {
    final rows = [
      for (final (icon, label, key) in fields)
        if (field(info, key).isNotEmpty) (icon, label, field(info, key)),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            color: color,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Baloo',
                fontWeight: FontWeight.w800,
                fontSize: 20,
                color: Paper.ink,
              ),
            ),
          ),
          const SizedBox(height: 8),
          PaperBox(
            child: Column(
              children: [for (final (i, l, v) in rows) _Row(i, l, v)],
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.icon, this.label, this.value);
  final IconData icon;
  final String label, value;

  @override
  Widget build(BuildContext context) => copyable(
    context,
    value,
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: Paper.ink3),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(color: Paper.ink3, fontSize: 12),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    color: Paper.ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Thẻ sinh viên: đưa cho thư viện / phòng thi quét, nội dung mã là MSSV.
/// Máy quét cũ chỉ đọc vạch, máy mới đọc QR — nên có nút đổi qua lại.
class _StudentCard extends StatefulWidget {
  const _StudentCard({required this.info});
  final Map<String, dynamic> info;

  @override
  State<_StudentCard> createState() => _StudentCardState();
}

class _StudentCardState extends State<_StudentCard> {
  bool _qr = false;

  @override
  Widget build(BuildContext context) {
    final mssv = clean(widget.info['MaSinhVien']);
    if (mssv.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: PaperBox(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Thẻ sinh viên',
                    style: TextStyle(
                      fontFamily: 'Baloo',
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      color: Paper.ink,
                    ),
                  ),
                ),
                PaperButton(
                  label: _qr ? 'Mã vạch' : 'Mã QR',
                  fontSize: 13,
                  color: Paper.sky,
                  onColor: Paper.ink,
                  onPressed: () => setState(() => _qr = !_qr),
                ),
              ],
            ),
            const SizedBox(height: 12),
            copyable(
              context,
              mssv,
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Paper.border,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: BarcodeWidget(
                    // Nền trắng, mực đen: máy quét cần tương phản thật, màu giấy
                    // kem làm vài đầu đọc đọc không ra.
                    barcode: _qr ? Barcode.qrCode() : Barcode.code128(),
                    data: mssv,
                    height: _qr ? 180 : 90,
                    width: _qr ? 180 : null,
                    drawText: !_qr,
                    color: Colors.black,
                    style: Paper.mono.copyWith(fontSize: 14),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '${clean(widget.info['HoTen'])} · ${field(widget.info, 'LopSinhVien')}',
              style: const TextStyle(color: Paper.ink2, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
