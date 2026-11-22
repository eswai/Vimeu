#include "backend.h"

#include <QJsonDocument>
#include <QJsonObject>

#include "vimeu.h"

namespace {

QByteArray pathArgument(const QString &path) { return path.toUtf8(); }

} // namespace

Backend::Backend(const QString &dictionaryPath, const QString &userDirectory, QObject *parent)
    : QObject(parent) {
    const QByteArray dic = pathArgument(dictionaryPath), user = pathArgument(userDirectory);
    m_tuner = vimeu_tuner_open(dic.isEmpty() ? nullptr : dic.constData(),
                               user.isEmpty() ? nullptr : user.constData());
    refresh();
}

Backend::~Backend() { vimeu_tuner_close(m_tuner); }

void Backend::refresh() {
    char *json = vimeu_tuner_state(m_tuner);
    m_stateJson = QString::fromUtf8(json);
    vimeu_string_free(json);
    m_state = QJsonDocument::fromJson(m_stateJson.toUtf8()).object().toVariantMap();
    emit stateChanged();
}

void Backend::setError(const QString &error) {
    if (error == m_error) return;
    m_error = error;
    emit errorChanged();
}

bool Backend::run(const QVariantMap &command) {
    const QByteArray json = QJsonDocument(QJsonObject::fromVariantMap(command)).toJson(QJsonDocument::Compact);
    char *failure = vimeu_tuner_run(m_tuner, json.constData());
    const bool ok = failure == nullptr;
    setError(ok ? QString() : QString::fromUtf8(failure));
    vimeu_string_free(failure);
    refresh();
    return ok;
}

void Backend::setReading(const QString &reading) {
    run({{"op", "setReading"}, {"reading", reading}});
}

void Backend::selectCandidate(int index) {
    run({{"op", "selectCandidate"}, {"index", index}});
}

void Backend::boostWord(const QString &reading, const QString &surface, int steps) {
    run({{"op", "boostWord"}, {"reading", reading}, {"surface", surface}, {"steps", steps}});
}

void Backend::setWordCost(const QString &reading, const QString &surface, int cost) {
    run({{"op", "setWordCost"}, {"reading", reading}, {"surface", surface}, {"cost", cost}});
}

void Backend::toggleWordDeleted(const QString &reading, const QString &surface, bool deleted) {
    run({{"op", deleted ? "reviveWord" : "deleteWord"}, {"reading", reading}, {"surface", surface}});
}

void Backend::resetWord(const QString &reading, const QString &surface) {
    run({{"op", "resetWord"}, {"reading", reading}, {"surface", surface}});
}

bool Backend::addWord(const QString &reading, const QString &surface, int cost) {
    return run({{"op", "addWord"}, {"reading", reading}, {"surface", surface}, {"cost", cost}});
}

void Backend::boostConnection(int rid, int lid, int steps) {
    run({{"op", "boostConnection"}, {"rid", rid}, {"lid", lid}, {"steps", steps}});
}

void Backend::setConnectionCost(int rid, int lid, int cost) {
    run({{"op", "setConnectionCost"}, {"rid", rid}, {"lid", lid}, {"cost", cost}});
}

void Backend::toggleConnectionDisabled(int rid, int lid, bool disabled) {
    run({{"op", disabled ? "reviveConnection" : "disableConnection"}, {"rid", rid}, {"lid", lid}});
}

void Backend::resetConnection(int rid, int lid) {
    run({{"op", "resetConnection"}, {"rid", rid}, {"lid", lid}});
}

bool Backend::addCollocation(const QString &left, const QString &right, bool negative) {
    return run({{"op", "addCollocation"}, {"left", left}, {"right", right},
                {"polarity", negative ? "negative" : "positive"}});
}

void Backend::removeCollocation(const QString &left, const QString &right) {
    run({{"op", "removeCollocation"}, {"left", left}, {"right", right}});
}
