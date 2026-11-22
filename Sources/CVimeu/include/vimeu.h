/*
 * vimeu C API — the boundary between the Swift conversion core (libvimeu.so)
 * and the fcitx5 addon. DESIGN.md §8.
 *
 * Threading: every function must be called from the same thread (fcitx5's
 * event loop). Callbacks are invoked synchronously from within the call that
 * triggered them.
 *
 * Strings are UTF-8. Strings passed into the library are copied; strings
 * passed to callbacks are valid only for the duration of the callback.
 */
#ifndef VIMEU_H
#define VIMEU_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct vimeu_engine vimeu_engine;   /* one per process */
typedef struct vimeu_session vimeu_session; /* one per input context */

/* Logical keys. VIMEU_KEY_CHAR carries the produced character. */
enum {
    VIMEU_KEY_CHAR = 0,
    VIMEU_KEY_SPACE = 1,
    VIMEU_KEY_ENTER = 2,
    VIMEU_KEY_BACKSPACE = 3,
    VIMEU_KEY_ESCAPE = 4,
    VIMEU_KEY_UP = 5,
    VIMEU_KEY_DOWN = 6,
    VIMEU_KEY_OTHER = 7,
};

/* Modifier bits (same values as fcitx::KeyState for Shift/Ctrl/Alt/Super). */
enum {
    VIMEU_MOD_SHIFT = 1u << 0,
    VIMEU_MOD_CONTROL = 1u << 2,
    VIMEU_MOD_ALT = 1u << 3,
    VIMEU_MOD_SUPER = 1u << 6,
};

/* Timer ids passed to start_timer / cancel_timer / vimeu_session_timer_fired. */
enum {
    VIMEU_TIMER_LIVE_CONVERSION = 1,
    VIMEU_TIMER_AUTO_COMMIT = 2,
};

typedef struct vimeu_callbacks {
    void *user_data;
    /* Show text as the composition; converting = a candidate is selected. */
    void (*set_preedit)(void *user_data, const char *text, bool converting);
    void (*commit)(void *user_data, const char *text);
    /* A new candidate list. */
    void (*show_candidates)(void *user_data, const char *const *candidates, int32_t count, int32_t selected);
    /* Move the selection within the list last shown. */
    void (*select_candidate)(void *user_data, int32_t index);
    void (*hide_candidates)(void *user_data);
    /* Return false if the client has no surrounding text. Offsets are in
     * Unicode scalars; *text must stay valid until the callback returns. */
    bool (*surrounding_text)(void *user_data, const char **text, int32_t *cursor, int32_t *anchor);
    /* Delete count Unicode scalars before the cursor. */
    void (*delete_before_cursor)(void *user_data, int32_t count);
    void (*start_timer)(void *user_data, int32_t timer, int32_t milliseconds);
    void (*cancel_timer)(void *user_data, int32_t timer);
    /* Open the tuning window; reading may be NULL. */
    void (*open_tuner)(void *user_data, const char *reading);
} vimeu_callbacks;

typedef struct vimeu_settings {
    bool live_conversion;
    int32_t live_conversion_delay_ms;
    bool auto_commit;
    int32_t auto_commit_delay_ms;
    bool partial_commit;
    int32_t partial_commit_length;
    int32_t partial_commit_mode; /* 0 = converted, 1 = reading */
    bool partial_commit_requires_stable;
    int32_t partial_commit_stable_length;
    bool reconvert_on_backspace;
} vimeu_settings;

/* Fill *out with the defaults the macOS IME uses. */
void vimeu_settings_default(vimeu_settings *out);

/* dictionary_path / user_dir may be NULL for the default search
 * ($VIMEU_DIC, $XDG_DATA_HOME/vimeu/vimeu.dic, /usr/share/vimeu/vimeu.dic) and
 * $XDG_DATA_HOME/vimeu. Never returns NULL: without a dictionary the engine
 * still does kana input; vimeu_engine_load_failure says why. */
vimeu_engine *vimeu_engine_open(const char *dictionary_path, const char *user_dir);
void vimeu_engine_close(vimeu_engine *engine);
/* NULL when the dictionary loaded. Owned by the engine. */
const char *vimeu_engine_load_failure(vimeu_engine *engine);
/* Owned by the engine. */
const char *vimeu_engine_user_dir(vimeu_engine *engine);
void vimeu_engine_reload_user_dict(vimeu_engine *engine);

/* callbacks is copied. */
vimeu_session *vimeu_session_new(vimeu_engine *engine, const vimeu_callbacks *callbacks);
void vimeu_session_free(vimeu_session *session);
void vimeu_session_set_settings(vimeu_session *session, const vimeu_settings *settings);
void vimeu_session_get_settings(vimeu_session *session, vimeu_settings *out);

/* Returns true if the key was consumed. */
bool vimeu_session_key(vimeu_session *session, int32_t key, uint32_t codepoint, uint32_t modifiers);
void vimeu_session_timer_fired(vimeu_session *session, int32_t timer);
/* Focus came in: drop anything left from the previous client. */
void vimeu_session_activate(vimeu_session *session);
/* Focus left / reset: commit (or discard) the composition. */
void vimeu_session_deactivate(vimeu_session *session, bool commit);
bool vimeu_session_is_composing(vimeu_session *session);
/* A candidate was clicked: commit it. */
void vimeu_session_select_candidate(vimeu_session *session, int32_t index);
/* The candidate window moved the cursor (paging): follow it. */
void vimeu_session_highlight_candidate(vimeu_session *session, int32_t index);
void vimeu_session_toggle_live_conversion(vimeu_session *session);
void vimeu_session_open_tuner(vimeu_session *session);

/* ── Tuning (vimeu-tune) ──────────────────────────────────────────────────
 * The tuning window's model. State and commands are JSON so this boundary
 * stays small; see Sources/VimeuSession/Tuner.swift for the fields. Edits are
 * saved to the user dictionary at once; the fcitx5 addon reloads it. */
typedef struct vimeu_tuner vimeu_tuner;

/* Same path rules as vimeu_engine_open. Never returns NULL; without a
 * dictionary the state's "ready" is false and "message" says why. */
vimeu_tuner *vimeu_tuner_open(const char *dictionary_path, const char *user_dir);
void vimeu_tuner_close(vimeu_tuner *tuner);
/* The whole state as a JSON object. Free with vimeu_string_free. */
char *vimeu_tuner_state(vimeu_tuner *tuner);
/* Run one command, e.g. {"op":"boostWord","reading":"かわ","surface":"皮","steps":1}.
 * Returns NULL on success, or an error message to free with vimeu_string_free. */
char *vimeu_tuner_run(vimeu_tuner *tuner, const char *command_json);
void vimeu_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* VIMEU_H */
