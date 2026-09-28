import 'package:dlu_tkb/nhac.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 28/9 học tiết 1-4 (vào 7h30), 29/9 học tiết 7-10 (vào 13h00).
  final lich = {
    DateTime(2026, 9, 28): [
      {
        'BeginTime': 'Tiết: 1',
        'EndTime': 'Tiết: 4',
        'CurriculumName': 'Giải tích 2',
        'RoomID': 'A1.203',
      },
    ],
    DateTime(2026, 9, 29): [
      {
        'BeginTime': 'Tiết: 7',
        'EndTime': 'Tiết: 10',
        'CurriculumName': 'Vật lý',
        'RoomID': 'B2.101',
      },
    ],
  };

  test('nhắc trước giờ vào lớp đúng 15 phút', () {
    final moc = mocNhac(lich, DateTime(2026, 9, 27));
    expect(moc.length, 2);
    // Tiết 1 vào 7h30 -> rung lúc 7h15.
    expect(moc.first.luc, DateTime(2026, 9, 28, 7, 15));
    expect(moc.first.vao, DateTime(2026, 9, 28, 7, 30));
    expect(moc.first.tiet, 1);
    expect(moc.first.phong, 'A1.203');
    // Tiết 7 vào 13h00 -> rung lúc 12h45.
    expect(moc.last.luc, DateTime(2026, 9, 29, 12, 45));
  });

  test('mốc đã qua thì bỏ, còn lại sắp theo thời gian', () {
    // Đúng 7h20 ngày 28: mốc 7h15 trôi rồi, chỉ còn buổi hôm sau.
    final moc = mocNhac(lich, DateTime(2026, 9, 28, 7, 20));
    expect(moc.map((m) => m.luc), [DateTime(2026, 9, 29, 12, 45)]);

    // Đúng ngay mốc cũng coi như trễ — hẹn máy rung vào quá khứ thì vô nghĩa.
    expect(mocNhac(lich, DateTime(2026, 9, 28, 7, 15)).length, 1);
  });

  test('cắt bớt cho khỏi vượt trần alarm của máy', () {
    final nhieu = {
      for (var d = 1; d <= 20; d++)
        DateTime(2026, 10, d): [
          {'BeginTime': 'Tiết: 1', 'EndTime': 'Tiết: 2', 'CurriculumName': 'X'},
        ],
    };
    final moc = mocNhac(nhieu, DateTime(2026, 9, 30), toiDa: 5);
    expect(moc.length, 5);
    // Cắt phần xa nhất chứ không cắt bừa: giữ đúng 5 buổi gần nhất.
    expect(moc.first.luc, DateTime(2026, 10, 1, 7, 15));
    expect(moc.last.luc, DateTime(2026, 10, 5, 7, 15));
  });

  test('tiết lạ thì không bịa giờ để nhắc', () {
    final la = {
      DateTime(2026, 9, 28): [
        {'BeginTime': 'x', 'EndTime': 'y', 'CurriculumName': 'X'},
      ],
    };
    expect(mocNhac(la, DateTime(2026, 9, 27)), isEmpty);
  });
}
