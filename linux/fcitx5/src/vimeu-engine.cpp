#include "vimeu-engine.h"

#include <sys/inotify.h>
#include <unistd.h>

#include <cerrno>
#include <filesystem>
#include <cstring>
#include <ctime>

#include <fcitx-config/iniparser.h>
#include <fcitx-utils/key.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/misc.h>
#include <fcitx-utils/standardpaths.h>
#include <fcitx-utils/textformatflags.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/statusarea.h>
#include <fcitx/text.h>
#include <fcitx/userinterfacemanager.h>

namespace fcitx {

FCITX_DEFINE_LOG_CATEGORY(vimeu_log, "vimeu");
#define VIMEU_INFO() FCITX_LOGC(vimeu_log, Info)
#define VIMEU_WARN() FCITX_LOGC(vimeu_log, Warn)

namespace {

constexpr int kPageSize = 10;
constexpr const char *kConfigPath = "conf/vimeu.conf";

/// A candidate; clicking it commits through the session. The list and the
/// state both belong to the same InputContext, so the pointer cannot dangle.
class VimeuCandidateWord : public CandidateWord {
public:
    VimeuCandidateWord(VimeuState *state, int index, std::string text)
        : CandidateWord(Text(std::move(text))), state_(state), index_(index) {}

    void select(InputContext *) const override {
        vimeu_session_select_candidate(state_->session(), index_);
    }

private:
    VimeuState *state_;
    int index_;
};

/// fcitx KeyEvent → (VIMEU_KEY_*, code point). Returns false for keys the
/// session should never see (bare modifiers).
bool translateKey(const Key &key, int32_t *outKey, uint32_t *outCodepoint) {
    if (key.isModifier()) {
        return false;
    }
    *outCodepoint = 0;
    switch (key.sym()) {
    case FcitxKey_space:
    case FcitxKey_KP_Space:
        *outKey = VIMEU_KEY_SPACE;
        return true;
    case FcitxKey_Return:
    case FcitxKey_KP_Enter:
        *outKey = VIMEU_KEY_ENTER;
        return true;
    case FcitxKey_BackSpace:
        *outKey = VIMEU_KEY_BACKSPACE;
        return true;
    case FcitxKey_Escape:
        *outKey = VIMEU_KEY_ESCAPE;
        return true;
    case FcitxKey_Up:
    case FcitxKey_KP_Up:
        *outKey = VIMEU_KEY_UP;
        return true;
    case FcitxKey_Down:
    case FcitxKey_KP_Down:
        *outKey = VIMEU_KEY_DOWN;
        return true;
    default:
        break;
    }
    const uint32_t cp = Key::keySymToUnicode(key.sym());
    if (cp >= 0x20 && cp != 0x7f) {
        *outKey = VIMEU_KEY_CHAR;
        *outCodepoint = cp;
    } else {
        *outKey = VIMEU_KEY_OTHER;
    }
    return true;
}

uint32_t translateModifiers(KeyStates states) {
    uint32_t mods = 0;
    if (states.test(KeyState::Shift)) mods |= VIMEU_MOD_SHIFT;
    if (states.test(KeyState::Ctrl)) mods |= VIMEU_MOD_CONTROL;
    if (states.test(KeyState::Alt)) mods |= VIMEU_MOD_ALT;
    if (states.test(KeyState::Super) || states.test(KeyState::Super2)) {
        mods |= VIMEU_MOD_SUPER;
    }
    return mods;
}

} // namespace

// MARK: - VimeuState

VimeuState::VimeuState(VimeuEngine *engine, InputContext *ic)
    : engine_(engine), ic_(ic) {
    vimeu_callbacks cb{};
    cb.user_data = this;
    cb.set_preedit = &VimeuState::cbSetPreedit;
    cb.commit = &VimeuState::cbCommit;
    cb.show_candidates = &VimeuState::cbShowCandidates;
    cb.select_candidate = &VimeuState::cbSelectCandidate;
    cb.hide_candidates = &VimeuState::cbHideCandidates;
    cb.surrounding_text = &VimeuState::cbSurroundingText;
    cb.delete_before_cursor = &VimeuState::cbDeleteBeforeCursor;
    cb.start_timer = &VimeuState::cbStartTimer;
    cb.cancel_timer = &VimeuState::cbCancelTimer;
    cb.open_tuner = &VimeuState::cbOpenTuner;
    session_ = vimeu_session_new(engine_->core(), &cb);
    applySettings();
}

VimeuState::~VimeuState() {
    // Timers reference this state; drop them before the session.
    for (auto &t : timers_) t.reset();
    vimeu_session_free(session_);
}

void VimeuState::applySettings() {
    const vimeu_settings s = engine_->settings();
    vimeu_session_set_settings(session_, &s);
}

void VimeuState::setPreedit(const std::string &text, bool converting) {
    if (text == lastPreedit_ && converting == lastPreeditConverting_) return;
    lastPreedit_ = text;
    lastPreeditConverting_ = converting;
    Text t;
    if (!text.empty()) {
        TextFormatFlags flags = TextFormatFlag::Underline;
        if (converting) flags |= TextFormatFlag::HighLight;
        t.append(text, flags);
        t.setCursor(static_cast<int>(text.size()));
    }
    if (ic_->capabilityFlags().test(CapabilityFlag::Preedit)) {
        ic_->inputPanel().setClientPreedit(t);
        ic_->inputPanel().setPreedit(Text());
    } else {
        ic_->inputPanel().setPreedit(t);
    }
    ic_->updatePreedit();
    ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

void VimeuState::cbSetPreedit(void *ud, const char *text, bool converting) {
    static_cast<VimeuState *>(ud)->setPreedit(text ? text : "", converting);
}

void VimeuState::cbCommit(void *ud, const char *text) {
    auto *self = static_cast<VimeuState *>(ud);
    // The committed text replaces the composition shown so far.
    self->lastPreedit_.clear();
    self->lastPreeditConverting_ = false;
    self->ic_->inputPanel().setClientPreedit(Text());
    self->ic_->inputPanel().setPreedit(Text());
    self->ic_->updatePreedit();
    self->ic_->commitString(text ? text : "");
    self->ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

void VimeuState::cbShowCandidates(void *ud, const char *const *candidates,
                                  int32_t count, int32_t selected) {
    auto *self = static_cast<VimeuState *>(ud);
    auto list = std::make_unique<CommonCandidateList>();
    list->setPageSize(kPageSize);
    // 1–9 select within the page (the session handles the digits itself).
    list->setLabels({"1", "2", "3", "4", "5", "6", "7", "8", "9", " "});
    list->setLayoutHint(CandidateLayoutHint::Vertical);
    list->setCursorPositionAfterPaging(CursorPositionAfterPaging::ResetToFirst);
    for (int32_t i = 0; i < count; ++i) {
        list->append<VimeuCandidateWord>(self, i, candidates[i]);
    }
    if (count > 0) {
        list->setGlobalCursorIndex(selected);
        list->setPage(selected / kPageSize);
    }
    self->ic_->inputPanel().setCandidateList(std::move(list));
    self->ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

void VimeuState::cbSelectCandidate(void *ud, int32_t index) {
    auto *self = static_cast<VimeuState *>(ud);
    auto list = self->ic_->inputPanel().candidateList();
    auto *common = dynamic_cast<CommonCandidateList *>(list.get());
    if (!common || index < 0 || index >= common->totalSize()) return;
    common->setPage(index / kPageSize);
    common->setGlobalCursorIndex(index);
    self->ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

void VimeuState::cbHideCandidates(void *ud) {
    auto *self = static_cast<VimeuState *>(ud);
    if (!self->ic_->inputPanel().candidateList()) return;
    self->ic_->inputPanel().setCandidateList(nullptr);
    self->ic_->updateUserInterface(UserInterfaceComponent::InputPanel);
}

bool VimeuState::cbSurroundingText(void *ud, const char **text,
                                   int32_t *cursor, int32_t *anchor) {
    auto *self = static_cast<VimeuState *>(ud);
    if (!self->ic_->capabilityFlags().test(CapabilityFlag::SurroundingText)) {
        return false;
    }
    const auto &st = self->ic_->surroundingText();
    if (!st.isValid()) return false;
    self->surroundingCache_ = st.text();
    *text = self->surroundingCache_.c_str();
    *cursor = static_cast<int32_t>(st.cursor());
    *anchor = static_cast<int32_t>(st.anchor());
    return true;
}

void VimeuState::cbDeleteBeforeCursor(void *ud, int32_t count) {
    auto *self = static_cast<VimeuState *>(ud);
    if (count <= 0) return;
    self->ic_->deleteSurroundingText(-count, static_cast<unsigned int>(count));
}

void VimeuState::cbStartTimer(void *ud, int32_t timer, int32_t ms) {
    auto *self = static_cast<VimeuState *>(ud);
    if (timer < 0 || timer >= static_cast<int32_t>(self->timers_.size())) return;
    const uint64_t at = now(CLOCK_MONOTONIC) + static_cast<uint64_t>(ms) * 1000;
    auto &slot = self->timers_[timer];
    if (slot) {
        slot->setTime(at);
        slot->setOneShot();
        return;
    }
    slot = self->engine_->instance()->eventLoop().addTimeEvent(
        CLOCK_MONOTONIC, at, 1000, [self, timer](EventSourceTime *, uint64_t) {
            vimeu_session_timer_fired(self->session_, timer);
            return true;
        });
}

void VimeuState::cbCancelTimer(void *ud, int32_t timer) {
    auto *self = static_cast<VimeuState *>(ud);
    if (timer < 0 || timer >= static_cast<int32_t>(self->timers_.size())) return;
    if (auto &slot = self->timers_[timer]) {
        slot->setEnabled(false);
    }
}

void VimeuState::cbOpenTuner(void *ud, const char *reading) {
    static_cast<VimeuState *>(ud)->engine_->openTuner(reading);
}

// MARK: - VimeuEngine

VimeuEngine::VimeuEngine(Instance *instance)
    : instance_(instance), factory_([this](InputContext &ic) {
          return new VimeuState(this, &ic);
      }) {
    reloadConfig();

    core_ = vimeu_engine_open(nullptr, nullptr);
    if (const char *failure = vimeu_engine_load_failure(core_)) {
        VIMEU_WARN() << "dictionary unavailable, kana input only: " << failure;
    } else {
        VIMEU_INFO() << "dictionary loaded; user dictionary at "
                     << vimeu_engine_user_dir(core_);
    }

    liveAction_.setShortText("ライブ変換");
    liveAction_.setCheckable(true);
    liveAction_.connect<SimpleAction::Activated>([this](InputContext *ic) {
        config_.liveConversion.setValue(!*config_.liveConversion);
        safeSaveAsIni(config_, StandardPathsType::PkgConfig, kConfigPath);
        pushSettingsToAllSessions();
        updateLiveAction();
        liveAction_.update(ic);
    });
    instance_->userInterfaceManager().registerAction("vimeu-live-conversion",
                                                     &liveAction_);
    updateLiveAction();

    tunerAction_.setShortText("調整...");
    tunerAction_.connect<SimpleAction::Activated>([this](InputContext *ic) {
        if (auto *s = state(ic)) vimeu_session_open_tuner(s->session());
    });
    instance_->userInterfaceManager().registerAction("vimeu-tuner", &tunerAction_);

    instance_->inputContextManager().registerProperty("vimeuState", &factory_);
    watchUserDictionary();
}

VimeuEngine::~VimeuEngine() {
    inotifyEvent_.reset();
    reloadDebounce_.reset();
    if (inotifyFd_ >= 0) close(inotifyFd_);
    // Sessions still alive (freed when factory_ is destroyed after this
    // body) hold their own reference to the core, so this only drops ours.
    vimeu_engine_close(core_);
}

vimeu_settings VimeuEngine::settings() const {
    vimeu_settings s{};
    vimeu_settings_default(&s);
    s.live_conversion = *config_.liveConversion;
    s.live_conversion_delay_ms = *config_.liveConversionDelay;
    s.auto_commit = *config_.autoCommit;
    s.auto_commit_delay_ms = *config_.autoCommitDelay;
    s.partial_commit = *config_.partialCommit;
    s.partial_commit_length = *config_.partialCommitLength;
    s.partial_commit_mode = *config_.partialCommitKana ? 1 : 0;
    s.partial_commit_requires_stable = *config_.partialCommitRequiresStable;
    s.partial_commit_stable_length = *config_.partialCommitStableLength;
    s.reconvert_on_backspace = *config_.reconvertOnBackspace;
    return s;
}

void VimeuEngine::keyEvent(const InputMethodEntry &, KeyEvent &keyEvent) {
    if (keyEvent.isRelease()) return;
    auto *s = state(keyEvent.inputContext());
    if (!s) return;
    int32_t key = VIMEU_KEY_OTHER;
    uint32_t codepoint = 0;
    if (!translateKey(keyEvent.key(), &key, &codepoint)) return;
    const uint32_t mods = translateModifiers(keyEvent.key().states());
    if (vimeu_session_key(s->session(), key, codepoint, mods)) {
        keyEvent.filterAndAccept();
    }
}

void VimeuEngine::activate(const InputMethodEntry &, InputContextEvent &event) {
    auto *ic = event.inputContext();
    if (auto *s = state(ic)) {
        s->applySettings();
        s->forgetPreedit();
        vimeu_session_activate(s->session());
    }
    ic->statusArea().addAction(StatusGroup::InputMethod, &liveAction_);
    ic->statusArea().addAction(StatusGroup::InputMethod, &tunerAction_);
}

void VimeuEngine::deactivate(const InputMethodEntry &, InputContextEvent &event) {
    // Switching away from vimeu: keep what was typed.
    if (auto *s = state(event.inputContext())) {
        vimeu_session_deactivate(s->session(), true);
    }
}

void VimeuEngine::reset(const InputMethodEntry &, InputContextEvent &event) {
    auto *s = state(event.inputContext());
    if (!s) return;
    // Focus out: commit what is on screen, like IMK's commitComposition.
    // An explicit client reset (the app cleared the field, moved the caret
    // programmatically) has already dropped the preedit: discard.
    const bool commit = event.type() == EventType::InputContextFocusOut ||
                        event.type() == EventType::InputContextSwitchInputMethod;
    vimeu_session_deactivate(s->session(), commit);
    s->forgetPreedit();
}

void VimeuEngine::setConfig(const RawConfig &raw) {
    config_.load(raw, true);
    safeSaveAsIni(config_, StandardPathsType::PkgConfig, kConfigPath);
    pushSettingsToAllSessions();
    updateLiveAction();
}

void VimeuEngine::reloadConfig() {
    readAsIni(config_, StandardPathsType::PkgConfig, kConfigPath);
    pushSettingsToAllSessions();
    updateLiveAction();
}

void VimeuEngine::pushSettingsToAllSessions() {
    if (!core_) return;
    instance_->inputContextManager().foreach([this](InputContext *ic) {
        if (auto *s = state(ic)) s->applySettings();
        return true;
    });
}

void VimeuEngine::updateLiveAction() {
    liveAction_.setChecked(*config_.liveConversion);
    liveAction_.setLongText(*config_.liveConversion ? "ライブ変換: オン"
                                                    : "ライブ変換: オフ");
}

void VimeuEngine::openTuner(const char *reading) {
    std::vector<std::string> args{"vimeu-tune"};
    if (reading && *reading) {
        args.push_back("--reading");
        args.push_back(reading);
    }
    VIMEU_INFO() << "starting vimeu-tune";
    startProcess(args);
}

void VimeuEngine::reloadUserDictionary() {
    vimeu_engine_reload_user_dict(core_);
    VIMEU_INFO() << "user dictionary reloaded";
}

/// vimeu-tune (or a hand edit) rewrites user_*.tsv with a temp file + rename;
/// pick that up so the next conversion uses it. Coalesced over 200 ms because
/// one save touches several files.
void VimeuEngine::watchUserDictionary() {
    const char *dir = vimeu_engine_user_dir(core_);
    if (!dir) return;
    // Create it up front so the watch exists before the first edit.
    std::error_code ec;
    std::filesystem::create_directories(dir, ec);
    inotifyFd_ = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (inotifyFd_ < 0) {
        VIMEU_WARN() << "inotify_init1: " << std::strerror(errno);
        return;
    }
    if (inotify_add_watch(inotifyFd_, dir,
                          IN_CLOSE_WRITE | IN_MOVED_TO | IN_DELETE |
                              IN_CREATE) < 0) {
        // The directory appears with the first edit; until then there is
        // nothing to reload. vimeu-tune also asks for a reload explicitly.
        VIMEU_INFO() << "not watching " << dir << ": " << std::strerror(errno);
        close(inotifyFd_);
        inotifyFd_ = -1;
        return;
    }
    inotifyEvent_ = instance_->eventLoop().addIOEvent(
        inotifyFd_, IOEventFlag::In, [this](EventSourceIO *, int fd, IOEventFlags) {
            alignas(inotify_event) char buf[4096];
            while (read(fd, buf, sizeof(buf)) > 0) {
            }
            const uint64_t at = now(CLOCK_MONOTONIC) + 200 * 1000;
            if (reloadDebounce_) {
                reloadDebounce_->setTime(at);
                reloadDebounce_->setOneShot();
            } else {
                reloadDebounce_ = instance_->eventLoop().addTimeEvent(
                    CLOCK_MONOTONIC, at, 1000, [this](EventSourceTime *, uint64_t) {
                        reloadUserDictionary();
                        return true;
                    });
            }
            return true;
        });
}

AddonInstance *VimeuEngineFactory::create(AddonManager *manager) {
    return new VimeuEngine(manager->instance());
}

} // namespace fcitx

FCITX_ADDON_FACTORY_V2(vimeu, fcitx::VimeuEngineFactory);
