import 'package:isar/isar.dart';

part 'models.g.dart';

@collection
class Session {
  Id id = Isar.autoIncrement;

  String? patientName;
  DateTime? createdAt;

  bool isFinished = false;

  @Backlink(to: 'session')
  final sessionDatas = IsarLinks<SessionData>();
}

@collection
class SessionData {
  Id id = Isar.autoIncrement;

  final session = IsarLink<Session>();

  late String fileName; // Nombre del archivo binario con los datos crudos
}