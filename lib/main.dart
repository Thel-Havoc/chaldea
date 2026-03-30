import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:catcher_2/catcher_2.dart';
import 'package:path_provider/path_provider.dart';

import 'package:chaldea/app/tools/app_window.dart';
import 'package:chaldea/packages/home_widget.dart';
import 'app/modules/common/blank_page.dart';
import 'app/ui/optimizer_app.dart';
import 'app/modules/home/bootstrap/startup_failed_page.dart';
import 'models/db.dart';
import 'packages/analysis/analysis.dart';
import 'packages/network.dart';
import 'packages/packages.dart';
import 'packages/split_route/split_route.dart';
import 'utils/catcher/catcher_util.dart';
import 'utils/catcher/server_feedback_handler.dart';
import 'utils/http_override.dart';
import 'generated/l10n.dart';
import 'utils/notification.dart';
import 'utils/utils.dart';
import 'app/optimizer/simulation/headless_worker.dart' show runWorkerProcess;

void main(List<String> args) async {
  // Subprocess worker mode: headless optimizer worker, no UI.
  if (args.contains('--worker')) {
    await runWorkerProcess(args);
    return;
  }
  // make sure flutter packages like path_provider is working now
  WidgetsFlutterBinding.ensureInitialized();
  dynamic initError, initStack;
  Catcher2Options? catcherOptions;
  try {
    await _initiateCommon();
    // Optimizer: always use the standard AppData path on Windows so we find
    // Chaldea's downloaded game data regardless of where the exe lives.
    // (Chaldea's default release-mode logic points to a 'userdata' folder
    // next to the exe, which is inside the build tree during development.)
    if (PlatformU.isWindows) {
      final appSupport = await getApplicationSupportDirectory();
      await db.paths.initRootPath(testAppPath: appSupport.path);
    }
    await db.initiate();
    // Localization must be initialized before any battle simulation runs.
    // S.current is used inside battle functions (e.g. AddState.shouldAddState)
    // and crashes with a null check error if no locale has been loaded yet.
    await S.load(const Locale('en'));
    AppAnalysis.instance.initiate();
    catcherOptions = CatcherUtil.getOptions(
      logPath: db.paths.crashLog,
      feedbackHandler: ServerFeedbackHandler(
        screenshotController: db.runtimeData.screenshotController,
        screenshotPath: joinPaths(db.paths.tempDir, 'crash.jpg'),
        attachments: [db.paths.appLog, db.paths.crashLog, db.paths.userDataPath],
        onGenerateAttachments: () => {
          'userdata.memory.json': Uint8List.fromList(utf8.encode(jsonEncode(db.userData))),
          'settings.memory.json': Uint8List.fromList(utf8.encode(jsonEncode(db.settings))),
        },
      ),
    );
  } catch (e, s) {
    initError = e;
    initStack = s;
    try {
      logger.e('initiate app failed at startup', e, s);
    } catch (e, s) {
      print(e);
      print(s);
    }
  }
  final app = initError == null ? const OptimizerApp() : StartupFailedPage(error: initError, stackTrace: initStack, wrapApp: true);
  if (kDebugMode) {
    runApp(app);
  } else {
    Catcher2(
      rootWidget: app,
      debugConfig: catcherOptions,
      profileConfig: catcherOptions,
      releaseConfig: catcherOptions,
      navigatorKey: kAppKey,
      ensureInitialized: true,
      enableLogger: kDebugMode,
    );
  }
}

Future<void> _initiateCommon() async {
  await AppWindowUtil.init();

  LicenseRegistry.addLicense(() async* {
    Map<String, String> licenses = {
      'MOONCELL': 'res/license/CC-BY-NC-SA-4.0.txt',
      'FANDOM': 'res/license/CC-BY-SA-3.0.txt',
      'Atlas Academy': 'res/license/ODC-BY 1.0.txt',
    };
    for (final entry in licenses.entries) {
      String license = await rootBundle.loadString(entry.value).catchError((e, s) async {
        logger.e('load license(${entry.key}, ${entry.value}) failed.', e, s);
        return 'load license failed';
      });
      yield LicenseEntryWithLineBreaks([entry.key], license);
    }
  });
  network.init();
  if (!kIsWeb) {
    HttpOverrides.global = CustomHttpOverrides();
  }
  SplitRoute.defaultMasterFillPageBuilder = (context) => const BlankPage();
  await LocalNotificationUtil.init();

  HomeWidgetX.init();
}
