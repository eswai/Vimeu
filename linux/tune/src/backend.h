#pragma once

#include <QObject>
#include <QString>
#include <QVariantMap>

struct vimeu_tuner;

// The tuning model in libvimeu.so (Sources/VimeuSession/Tuner.swift), as a
// QObject for QML. Every command saves the user dictionary at once and the
// whole state comes back as JSON; there is no unsaved work to lose.
class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap state READ state NOTIFY stateChanged)
    Q_PROPERTY(QString error READ error NOTIFY errorChanged)

public:
    // Empty paths use libvimeu's defaults ($VIMEU_DIC, XDG data dirs).
    explicit Backend(const QString &dictionaryPath = {}, const QString &userDirectory = {},
                     QObject *parent = nullptr);
    ~Backend() override;
    Backend(const Backend &) = delete;
    Backend &operator=(const Backend &) = delete;

    QVariantMap state() const { return m_state; }
    QString stateJson() const { return m_stateJson; }
    QString error() const { return m_error; }

    // One command object, as Tuner.parse reads it ({"op": "boostWord", ...}).
    // Returns false and sets `error` when the core rejects it.
    Q_INVOKABLE bool run(const QVariantMap &command);

    Q_INVOKABLE void setReading(const QString &reading);
    Q_INVOKABLE void selectCandidate(int index);
    Q_INVOKABLE void boostWord(const QString &reading, const QString &surface, int steps);
    Q_INVOKABLE void setWordCost(const QString &reading, const QString &surface, int cost);
    Q_INVOKABLE void toggleWordDeleted(const QString &reading, const QString &surface, bool deleted);
    Q_INVOKABLE void resetWord(const QString &reading, const QString &surface);
    Q_INVOKABLE bool addWord(const QString &reading, const QString &surface, int cost);
    Q_INVOKABLE void boostConnection(int rid, int lid, int steps);
    Q_INVOKABLE void setConnectionCost(int rid, int lid, int cost);
    Q_INVOKABLE void toggleConnectionDisabled(int rid, int lid, bool disabled);
    Q_INVOKABLE void resetConnection(int rid, int lid);
    Q_INVOKABLE bool addCollocation(const QString &left, const QString &right, bool negative);
    Q_INVOKABLE void removeCollocation(const QString &left, const QString &right);

signals:
    void stateChanged();
    void errorChanged();
    // Another `vimeu-tune` was started (Control+; again): come to the front.
    void raiseRequested();

private:
    void refresh();
    void setError(const QString &error);

    vimeu_tuner *m_tuner = nullptr;
    QVariantMap m_state;
    QString m_stateJson;
    QString m_error;
};
