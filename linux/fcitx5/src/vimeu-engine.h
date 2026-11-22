/*
 * fcitx5 front end for vimeu. Thin by design: key translation, preedit and
 * candidate display, timers, config. The state machine and the conversion
 * live in libvimeu.so (Swift, Sources/VimeuSession). DESIGN.md §8.
 */
#ifndef VIMEU_FCITX5_ENGINE_H
#define VIMEU_FCITX5_ENGINE_H

#include <array>
#include <memory>
#include <string>
#include <vector>

#include <fcitx-config/configuration.h>
#include <fcitx-config/option.h>
#include <fcitx-utils/event.h>
#include <fcitx-utils/i18n.h>
#include <fcitx/action.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>

#include "vimeu.h"

namespace fcitx {

// Mirrors the macOS IME's settings (README「変換の調整」, DESIGN.md §4.1).
FCITX_CONFIGURATION(
    VimeuConfig,
    Option<bool> liveConversion{this, "LiveConversion", "ライブ変換", true};
    Option<int, IntConstrain> liveConversionDelay{
        this, "LiveConversionDelay", "ライブ変換の待ち時間 (ms)", 0,
        IntConstrain(0, 60000)};
    Option<bool> autoCommit{this, "AutoCommit",
                            "ライブ変換の結果を一定時間後に自動確定する", false};
    Option<int, IntConstrain> autoCommitDelay{
        this, "AutoCommitDelay", "自動確定までの時間 (ms)", 3000,
        IntConstrain(100, 60000)};
    Option<bool> partialCommit{this, "PartialCommit", "長い入力を先頭から部分確定する",
                               true};
    Option<int, IntConstrain> partialCommitLength{
        this, "PartialCommitLength", "部分確定を始める読みの文字数", 40,
        IntConstrain(2, 1000)};
    Option<bool> partialCommitKana{
        this, "PartialCommitKana",
        "ライブ変換オフのときはひらがなのまま部分確定する", false};
    Option<bool> partialCommitRequiresStable{
        this, "PartialCommitRequiresStable",
        "候補が変わらないことを確認してから確定する", true};
    Option<int, IntConstrain> partialCommitStableLength{
        this, "PartialCommitStableLength", "候補安定を確認する追加入力の文字数", 5,
        IntConstrain(1, 1000)};
    Option<bool> reconvertOnBackspace{this, "ReconvertOnBackspace",
                                      "確定直後の Backspace で再変換する", true};);

class VimeuEngine;

/// Per-InputContext state: one vimeu_session.
class VimeuState : public InputContextProperty {
public:
    VimeuState(VimeuEngine *engine, InputContext *ic);
    ~VimeuState() override;
    VimeuState(const VimeuState &) = delete;
    VimeuState &operator=(const VimeuState &) = delete;

    vimeu_session *session() const { return session_; }
    InputContext *ic() const { return ic_; }
    void applySettings();
    /// fcitx may clear the panel itself (focus changes); forget what we sent.
    void forgetPreedit() {
        lastPreedit_.clear();
        lastPreeditConverting_ = false;
    }

private:
    static void cbSetPreedit(void *ud, const char *text, bool converting);
    static void cbCommit(void *ud, const char *text);
    static void cbShowCandidates(void *ud, const char *const *candidates,
                                 int32_t count, int32_t selected);
    static void cbSelectCandidate(void *ud, int32_t index);
    static void cbHideCandidates(void *ud);
    static bool cbSurroundingText(void *ud, const char **text, int32_t *cursor,
                                  int32_t *anchor);
    static void cbDeleteBeforeCursor(void *ud, int32_t count);
    static void cbStartTimer(void *ud, int32_t timer, int32_t ms);
    static void cbCancelTimer(void *ud, int32_t timer);
    static void cbOpenTuner(void *ud, const char *reading);

    void setPreedit(const std::string &text, bool converting);

    VimeuEngine *engine_;
    InputContext *ic_;
    vimeu_session *session_ = nullptr;
    /// Indexed by VIMEU_TIMER_*. Re-armed in place, never destroyed from
    /// inside its own callback (a live conversion can re-arm itself).
    std::array<std::unique_ptr<EventSourceTime>, 3> timers_;
    /// Keeps the surrounding text alive while Swift reads it.
    std::string surroundingCache_;
    /// Last preedit sent, so identical updates are not sent twice (the
    /// session refreshes after both the conversion and the key itself).
    std::string lastPreedit_;
    bool lastPreeditConverting_ = false;
};

class VimeuEngine final : public InputMethodEngineV2 {
public:
    explicit VimeuEngine(Instance *instance);
    ~VimeuEngine() override;

    void keyEvent(const InputMethodEntry &entry, KeyEvent &keyEvent) override;
    void activate(const InputMethodEntry &entry,
                  InputContextEvent &event) override;
    void deactivate(const InputMethodEntry &entry,
                    InputContextEvent &event) override;
    void reset(const InputMethodEntry &entry,
               InputContextEvent &event) override;

    const Configuration *getConfig() const override { return &config_; }
    void setConfig(const RawConfig &config) override;
    void reloadConfig() override;

    Instance *instance() const { return instance_; }
    vimeu_engine *core() const { return core_; }
    const VimeuConfig &config() const { return config_; }
    vimeu_settings settings() const;
    void openTuner(const char *reading);
    /// Re-read the user's TSV files in every session (inotify / tuner).
    void reloadUserDictionary();

private:
    VimeuState *state(InputContext *ic) { return ic->propertyFor(&factory_); }
    void pushSettingsToAllSessions();
    void updateLiveAction();
    void watchUserDictionary();

    Instance *instance_;
    vimeu_engine *core_ = nullptr;
    VimeuConfig config_;
    FactoryFor<VimeuState> factory_;
    SimpleAction liveAction_;
    SimpleAction tunerAction_;
    int inotifyFd_ = -1;
    std::unique_ptr<EventSourceIO> inotifyEvent_;
    std::unique_ptr<EventSourceTime> reloadDebounce_;
};

class VimeuEngineFactory : public AddonFactory {
public:
    AddonInstance *create(AddonManager *manager) override;
};

} // namespace fcitx

#endif
