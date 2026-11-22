#include <QDir>
#include <QFile>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QQuickWindow>
#include <QTemporaryDir>
#include <QtTest>

#include "backend.h"
#include "theme.h"

class VimeuTuneTests : public QObject {
    Q_OBJECT

private slots:
    void missingDictionaryIsReported()
    {
        QTemporaryDir dir;
        Backend backend(dir.filePath("none.dic"), dir.path());
        QCOMPARE(backend.state().value("ready").toBool(), false);
        QVERIFY(backend.state().value("message").toString().contains("辞書"));
        QVERIFY(!backend.addWord("か", "蚊", 0));
        QVERIFY(!backend.error().isEmpty());
    }

    void readingConvertsAndEditsAreSaved()
    {
        if (!QFile::exists(VIMEU_TEST_DIC)) QSKIP("dict/vimeu.dic not built");
        QTemporaryDir dir;
        Backend backend(VIMEU_TEST_DIC, dir.path());
        QSignalSpy changed(&backend, &Backend::stateChanged);

        backend.setReading("kawa");
        QCOMPARE(backend.state().value("reading").toString(), QString("かわ"));
        QVERIFY(changed.count() >= 1);
        const auto candidates = backend.state().value("candidates").toList();
        QVERIFY(candidates.size() > 2);
        QVERIFY(candidates.first().toMap().value("text").toString() != "皮");

        QVERIFY(backend.addWord("かわ", "皮", 0));
        QCOMPARE(backend.state().value("candidates").toList().first().toMap().value("text").toString(), QString("皮"));
        QVERIFY(backend.error().isEmpty());
        QVERIFY(QFile::exists(dir.filePath("user_word.tsv")));

        backend.resetWord("かわ", "皮");
        QVERIFY(backend.state().value("candidates").toList().first().toMap().value("text").toString() != "皮");
    }

    void badCommandSetsError()
    {
        QTemporaryDir dir;
        Backend backend(dir.filePath("none.dic"), dir.path());
        QVERIFY(!backend.run({{"op", "nope"}}));
        QVERIFY(backend.error().contains("nope"));
        QVERIFY(backend.run({{"op", "setReading"}, {"reading", "a"}}));
        QVERIFY(backend.error().isEmpty());
    }

    // The real QML loads and renders with a state (catches QML errors that
    // only show at runtime).
    void windowLoads()
    {
        if (!QFile::exists(VIMEU_TEST_DIC)) QSKIP("dict/vimeu.dic not built");
        QTemporaryDir dir;
        QQuickStyle::setStyle("Material");
        Theme theme(dir.path());
        Backend backend(VIMEU_TEST_DIC, dir.path());
        backend.setReading("kawawomuku");
        QQmlApplicationEngine engine;
        QList<QQmlError> warnings;
        connect(&engine, &QQmlApplicationEngine::warnings, this, [&](const QList<QQmlError> &w) { warnings << w; });
        engine.rootContext()->setContextProperty("theme", &theme);
        engine.rootContext()->setContextProperty("backend", &backend);
        engine.load(QUrl("qrc:/Main.qml"));
        QCOMPARE(engine.rootObjects().size(), 1);
        auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().first());
        QVERIFY(window);
        QVERIFY(QTest::qWaitForWindowExposed(window));
        backend.selectCandidate(1);
        QTest::qWait(50);
        for (const auto &w : warnings) qWarning() << w.toString();
        QVERIFY2(warnings.isEmpty(), "QML warnings");
    }

    void themeFallsBack()
    {
        QTemporaryDir dir;
        Theme theme(dir.path());
        QCOMPARE(theme.accent(), QString("#FFD60A"));
        QCOMPARE(theme.accentForeground(), QString("black"));
    }

    void themeReadsAccent()
    {
        QTemporaryDir dir;
        QDir(dir.path()).mkpath("theme");
        QFile colors(dir.path() + "/theme/colors.toml");
        QVERIFY(colors.open(QIODevice::WriteOnly));
        colors.write("accent = \"#112233\"\n");
        colors.close();
        Theme theme(dir.path());
        QCOMPARE(theme.accent(), QString("#112233"));
        QCOMPARE(theme.accentForeground(), QString("white"));
    }

    void themeFollowsHyprlandRounding()
    {
        QTemporaryDir dir;
        const QString response = dir.filePath("response.json"), command = dir.filePath("hyprctl");
        auto write = [](const QString &path, const QByteArray &data) {
            QFile file(path);
            return file.open(QIODevice::WriteOnly) && file.write(data) == data.size();
        };
        QVERIFY(write(command, "#!/bin/sh\ncat '" + response.toUtf8() + "'\n"));
        QVERIFY(QFile::setPermissions(command, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
        QVERIFY(write(response, "{\"int\":0}"));
        Theme theme(dir.path(), nullptr, command);
        QCOMPARE(theme.radius(), 0);
        QVERIFY(write(response, "{\"int\":6}"));
        QTRY_COMPARE(theme.radius(), 6);
    }
};

QTEST_MAIN(VimeuTuneTests)
#include "vimeu-tune_tests.moc"
