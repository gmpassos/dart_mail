import 'package:logging/logging.dart' as logging;

void logToConsole() {
  logging.Logger.root.level = logging.Level.FINE;
  logging.Logger.root.onRecord.listen(_onRecord);
}

void _onRecord(logging.LogRecord record) {
  final time = record.time.toIso8601String();
  final level = record.level.name;

  var hasError = record.error != null;

  var c = hasError ? '✖' : '»';

  var s = StringBuffer(
    '$c [$time] [$level] [${record.loggerName}] ${record.message}',
  );

  if (record.error != null) {
    s.writeln('$c [ERROR] ${record.error}');
  }
  if (record.stackTrace != null) {
    s.writeln(record.stackTrace);
  }

  print(s);

  Future.delayed(Duration(milliseconds: 100));
}
