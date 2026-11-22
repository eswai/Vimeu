// End-to-end test: a real fcitx5 Instance loads the vimeu addon from the build
// tree and the testfrontend module feeds it keys. User config/data are not
// read (setupTestingEnvironment), and the user dictionary points at a fresh
// temporary directory.
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>

#include <fcitx-utils/event.h>
#include <fcitx-utils/eventdispatcher.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/testing.h>
#include <fcitx/addonmanager.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodgroup.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/instance.h>

#include "testfrontend_public.h"

using namespace fcitx;

namespace {

bool hasDictionary() { return std::filesystem::exists(VIMEU_TEST_DIC); }

std::string preedit(InputContext *ic) {
    return ic->inputPanel().clientPreedit().toString();
}

std::vector<std::string> candidates(InputContext *ic) {
    std::vector<std::string> out;
    auto list = ic->inputPanel().candidateList();
    if (!list) return out;
    auto *bulk = list->toBulk();
    FCITX_ASSERT(bulk);
    for (int i = 0; i < bulk->totalSize(); ++i) {
        out.push_back(bulk->candidateFromAll(i).text().toString());
    }
    return out;
}

bool contains(const std::vector<std::string> &v, const std::string &s) {
    return std::find(v.begin(), v.end(), s) != v.end();
}

void run(Instance *instance) {
    auto *vimeu = instance->addonManager().addon("vimeu", true);
    FCITX_ASSERT(vimeu);

    auto group = instance->inputMethodManager().currentGroup();
    group.inputMethodList().clear();
    group.inputMethodList().push_back(InputMethodGroupItem("keyboard-us"));
    group.inputMethodList().push_back(InputMethodGroupItem("vimeu"));
    group.setDefaultInputMethod("");
    instance->inputMethodManager().setGroup(group);

    auto *tf = instance->addonManager().addon("testfrontend");
    auto uuid = tf->call<ITestFrontend::createInputContext>("testapp");
    auto *ic = instance->inputContextManager().findByUUID(uuid);
    FCITX_ASSERT(ic);
    ic->setCapabilityFlags(CapabilityFlags{CapabilityFlag::Preedit,
                                           CapabilityFlag::SurroundingText});
    // By value: the reload check below runs from a timer after run() returns.
    auto key = [tf, uuid](const char *k) {
        return tf->call<ITestFrontend::sendKeyEvent>(uuid, Key(k), false);
    };
    auto type = [key](const char *s) {
        for (const char *p = s; *p; ++p) key(std::string(1, *p).c_str());
    };

    // Switch to vimeu.
    key("Control+space");
    FCITX_ASSERT(instance->inputMethod(ic) == "vimeu") << instance->inputMethod(ic);

    // Direct: unhandled keys go to the app.
    FCITX_ASSERT(!key("Return"));

    // Romaji → kana, Control+K forces katakana, Return commits it.
    type("kana");
    FCITX_ASSERT(!preedit(ic).empty());
    FCITX_ASSERT(key("Control+k"));
    FCITX_ASSERT(candidates(ic) == (std::vector<std::string>{"かな", "カナ"}));
    FCITX_ASSERT(preedit(ic) == "カナ") << preedit(ic);
    tf->call<ITestFrontend::pushCommitExpectation>("カナ");
    FCITX_ASSERT(key("Return"));
    FCITX_ASSERT(preedit(ic).empty());
    FCITX_ASSERT(!ic->inputPanel().candidateList());

    // Backspace right after the commit reconverts it (surrounding text check).
    ic->surroundingText().setText("あいカナ", 4, 4);
    FCITX_ASSERT(key("BackSpace"));
    FCITX_ASSERT(preedit(ic) == "カナ") << preedit(ic);
    FCITX_ASSERT(contains(candidates(ic), "カナ"));
    // Esc rewinds to the reading, then clears it — nothing is committed.
    FCITX_ASSERT(key("Escape"));
    FCITX_ASSERT(!ic->inputPanel().candidateList());
    FCITX_ASSERT(key("Escape"));
    FCITX_ASSERT(preedit(ic).empty());

    // A mismatching surrounding text leaves Backspace to the app.
    type("ka");
    tf->call<ITestFrontend::pushCommitExpectation>("か");
    FCITX_ASSERT(key("Control+j"));
    FCITX_ASSERT(key("Return"));
    ic->surroundingText().setText("x", 1, 1);
    FCITX_ASSERT(!key("BackSpace"));

    // Alt+Space types a full-width space.
    tf->call<ITestFrontend::pushCommitExpectation>("　");
    FCITX_ASSERT(key("Alt+space"));

    if (hasDictionary()) {
        // Live conversion shows the best path inline.
        type("kyouhaiitenkidesune");
        FCITX_ASSERT(preedit(ic).find("天気") != std::string::npos) << preedit(ic);
        FCITX_ASSERT(key("Escape"));

        // Space lists the n-best followed by the kana forms, 10 to a page.
        type("kawa");
        FCITX_ASSERT(key("space"));
        auto list = candidates(ic);
        FCITX_ASSERT(list.size() > 2);
        FCITX_ASSERT(contains(list, "川"));
        FCITX_ASSERT(contains(list, "カワ"));
        auto *pageable = ic->inputPanel().candidateList()->toPageable();
        FCITX_ASSERT(pageable);
        // Down moves the selection; the preedit follows it.
        FCITX_ASSERT(key("Down"));
        FCITX_ASSERT(preedit(ic) == list[1]) << preedit(ic);
        // The number key picks within the page and commits.
        tf->call<ITestFrontend::pushCommitExpectation>(list[0]);
        FCITX_ASSERT(key("1"));
        FCITX_ASSERT(!ic->inputPanel().candidateList());

        // A user dictionary edit (as vimeu-tune saves it: temp file + rename)
        // is picked up without restarting fcitx5. Cost 0 puts 皮 first.
        FCITX_ASSERT(list[0] != "皮");
        const auto dir = std::filesystem::path(getenv("XDG_DATA_HOME")) / "vimeu";
        {
            std::ofstream out(dir / "user_word.tsv.tmp");
            out << "reading\tsurface\tcost\tdisabled\tupdated_at\n"
                << "かわ\t皮\t0\t0\t0\n";
        }
        std::filesystem::rename(dir / "user_word.tsv.tmp", dir / "user_word.tsv");
        static std::unique_ptr<EventSourceTime> wait;
        wait = instance->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, now(CLOCK_MONOTONIC) + 600 * 1000, 0,
            [instance, tf, uuid, ic, type, key](EventSourceTime *, uint64_t) {
                type("kawa");
                FCITX_ASSERT(key("space"));
                auto edited = candidates(ic);
                FCITX_ASSERT(!edited.empty() && edited[0] == "皮") << edited[0];
                tf->call<ITestFrontend::pushCommitExpectation>("皮");
                FCITX_ASSERT(key("Return"));
                tf->call<ITestFrontend::destroyInputContext>(uuid);
                instance->exit();
                return true;
            });
        return;
    }
    FCITX_WARN() << "dict/vimeu.dic not built: skipping dictionary checks";
    tf->call<ITestFrontend::destroyInputContext>(uuid);
    instance->exit();
}

} // namespace

int main() {
    // Never touch the real user dictionary.
    auto tmp = std::filesystem::temp_directory_path() /
               ("vimeu-fcitx5-test-" + std::to_string(getpid()));
    std::filesystem::create_directories(tmp);
    setenv("XDG_DATA_HOME", tmp.c_str(), 1);
    setenv("VIMEU_DIC", VIMEU_TEST_DIC, 1);

    setupTestingEnvironment(TESTING_BINARY_DIR, {"lib/fcitx5"}, {"share/fcitx5"});

    char arg0[] = "testvimeu";
    char arg1[] = "--disable=all";
    char arg2[] = "--enable=testim,testfrontend,testui,vimeu";
    char *argv[] = {arg0, arg1, arg2};
    fcitx::Log::setLogRule("default=5,vimeu=5");
    Instance instance(FCITX_ARRAY_SIZE(argv), argv);
    instance.addonManager().registerDefaultLoader(nullptr);
    EventDispatcher dispatcher;
    dispatcher.attach(&instance.eventLoop());
    dispatcher.schedule([&instance]() { run(&instance); });
    instance.exec();
    std::filesystem::remove_all(tmp);
    return 0;
}
