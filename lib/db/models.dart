import 'package:isar/isar.dart';

part 'models.g.dart';

@collection
class Session {
  Id id = Isar.autoIncrement;

  String? patientName;
  DateTime? createdAt;
}

@collection
class SessionData {
  Id id = Isar.autoIncrement;

  @Index()
  late int sessionId; // Referencia al ID de Session

  late List<int> data;
}