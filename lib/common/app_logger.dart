import 'package:logger/logger.dart';

final _logger = Logger(
  printer: PrettyPrinter(
    methodCount: 1,
    errorMethodCount: 8,
    lineLength: 80,
    colors: true,
    printEmojis: false,
  ),
);

class AppLogger {
  AppLogger._();

  static void d(String message, {Object? error}) =>
      _logger.d(message, error: error);

  static void i(String message, {Object? error}) =>
      _logger.i(message, error: error);

  static void w(String message, {Object? error, StackTrace? stackTrace}) =>
      _logger.w(message, error: error, stackTrace: stackTrace);

  static void e(String message, {Object? error, StackTrace? stackTrace}) =>
      _logger.e(message, error: error, stackTrace: stackTrace);
}
