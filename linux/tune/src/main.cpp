// vimeu-tune — the tuning window for vimeu: edit word, collocation and
// connection costs and see the conversion change as you go.
//
//   vimeu-tune [--reading よみ]        open the window (or bring the open one
//                                      to the reading, as Control+; does)
//   vimeu-tune state [--reading よみ]  print the tuning state as JSON, no display

#include <QCommandLineParser>
#include <QGuiApplication>
#include <QIcon>
#include <QLocalServer>
#include <QLocalSocket>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QTextStream>
#include <QUrl>

#include <unistd.h>

#include "backend.h"
#include "theme.h"

int main(int argc, char *argv[]) {
    // The state command must not need a display, so pick the platform before
    // QGuiApplication exists.
    const bool stateCommand = argc > 1 && QByteArray(argv[1]) == "state";
    if (stateCommand)
        qputenv("QT_QPA_PLATFORM", "offscreen");

    QGuiApplication app(argc, argv);
    app.setApplicationName("vimeu-tune");
    app.setApplicationVersion("0.1.0");
    app.setDesktopFileName("vimeu-tune");
    app.setWindowIcon(QIcon::fromTheme("vimeu-tune"));

    QCommandLineParser parser;
    parser.setApplicationDescription("vimeu の変換を調整する");
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument("command", "state: 状態を JSON で出力する（画面なし）", "[state]");
    const QCommandLineOption readingOption("reading", "最初に調整する読み", "よみ");
    const QCommandLineOption dictionaryOption("dictionary", "vimeu.dic の場所", "path");
    const QCommandLineOption userOption("user-dir", "ユーザー辞書のディレクトリ", "dir");
    parser.addOptions({readingOption, dictionaryOption, userOption});
    parser.process(app);
    const QString reading = parser.value(readingOption);

    if (stateCommand) {
        Backend backend(parser.value(dictionaryOption), parser.value(userOption));
        if (!reading.isEmpty())
            backend.setReading(reading);
        QTextStream(stdout) << backend.stateJson() << Qt::endl;
        if (!backend.state().value("ready").toBool()) {
            QTextStream(stderr) << backend.state().value("message").toString() << Qt::endl;
            return 1;
        }
        return 0;
    }

    // One window per user. fcitx5 starts a new process for every Control+;,
    // so a second one hands its reading to the first and leaves.
    const QString serverName = QStringLiteral("vimeu-tune-%1").arg(getuid());
    {
        QLocalSocket probe;
        probe.connectToServer(serverName);
        if (probe.waitForConnected(300)) {
            probe.write(reading.toUtf8() + '\n');
            probe.waitForBytesWritten(300);
            return 0;
        }
    }

    // Dense: Material's compact metrics (shorter fields, buttons and tabs).
    // The default variant is sized for touch and left the window looking
    // oversized on a desktop. An explicit setting in the environment wins.
    if (!qEnvironmentVariableIsSet("QT_QUICK_CONTROLS_MATERIAL_VARIANT"))
        qputenv("QT_QUICK_CONTROLS_MATERIAL_VARIANT", "Dense");
    QQuickStyle::setStyle("Material");

    Theme theme;
    Backend backend(parser.value(dictionaryOption), parser.value(userOption));
    if (!reading.isEmpty())
        backend.setReading(reading);

    QLocalServer::removeServer(serverName);
    QLocalServer server;
    server.listen(serverName);
    QObject::connect(&server, &QLocalServer::newConnection, &backend, [&server, &backend] {
        while (QLocalSocket *socket = server.nextPendingConnection()) {
            QObject::connect(socket, &QLocalSocket::readyRead, socket, [socket, &backend] {
                if (!socket->canReadLine()) return;
                const QString line = QString::fromUtf8(socket->readLine()).trimmed();
                if (!line.isEmpty())
                    backend.setReading(line);
                emit backend.raiseRequested();
                socket->disconnectFromServer();
            });
            QObject::connect(socket, &QLocalSocket::disconnected, socket, &QObject::deleteLater);
        }
    });

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("theme", &theme);
    engine.rootContext()->setContextProperty("backend", &backend);
    engine.load(QUrl("qrc:/Main.qml"));
    if (engine.rootObjects().isEmpty())
        return 1;

    return app.exec();
}
