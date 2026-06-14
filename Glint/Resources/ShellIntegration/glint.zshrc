# Glint shell integration for zsh — written by Glint into
# ~/.config/glint/zsh-init/.zshrc and selected via ZDOTDIR at spawn time.
#
# What this layer adds on top of the user's own zshrc:
#   1. Per-pane $HISTFILE so the ↑ key in each pane only shows commands
#      typed in that pane (mimics Terminal.app's SHELL_SESSION_HISTORY,
#      but keyed on Glint's stable pane UUID so history survives restarts).
#   2. Optional history-driven ghost-text completion via
#      zsh-autosuggestions (→ / End to accept).
#
# We are intentionally NOT a .zshenv — we want the user's own .zshrc to
# run first so their HISTFILE / share_history / autosuggestions config (if
# any) is established, then we layer our overrides on top.

# ---------------------------------------------------------------------------
# 1. Source the user's real .zshrc first (zero-break compatibility).
# GLINT_USER_ZDOTDIR is set by Glint to whatever the user's ZDOTDIR was
# before we swapped it (or $HOME if it was unset).
# ---------------------------------------------------------------------------
if [[ -n ${GLINT_USER_ZDOTDIR-} && -r $GLINT_USER_ZDOTDIR/.zshrc ]]; then
    # Temporarily restore the user's ZDOTDIR so anything in their rc that
    # references $ZDOTDIR (oh-my-zsh, prezto, custom plugin paths) sees the
    # value they expect, not Glint's wrapper dir.
    _glint_saved_zdotdir=$ZDOTDIR
    ZDOTDIR=$GLINT_USER_ZDOTDIR
    source $GLINT_USER_ZDOTDIR/.zshrc
    ZDOTDIR=$_glint_saved_zdotdir
    unset _glint_saved_zdotdir
fi

# ---------------------------------------------------------------------------
# 2. Per-pane HISTFILE.
# Keyed on the stable pane UUID Glint injects at spawn — same pane across
# restarts gets the same history file. New panes seed from ~/.zsh_history
# so the first up-arrow isn't a wasteland.
# On pane close we append our session back into ~/.zsh_history (Apple's
# SHELL_SESSION_HISTORY pattern) so muscle-memory commands stay globally
# searchable from new panes.
# ---------------------------------------------------------------------------
if [[ -n ${GLINT_PANE_ID-} ]]; then
    _glint_hist_dir=${HOME}/.glint/history
    [[ -d $_glint_hist_dir ]] || mkdir -p $_glint_hist_dir
    # Sanitize the pane id (it's "<wsUUID>:<paneID>" — the colon is fine on
    # APFS but ugly in `ls`; underscore looks tidier and stays unique).
    _glint_hist_file=$_glint_hist_dir/${GLINT_PANE_ID//:/_}.history
    if [[ ! -f $_glint_hist_file && -f ${HOME}/.zsh_history ]]; then
        cp ${HOME}/.zsh_history $_glint_hist_file 2>/dev/null
    fi
    HISTFILE=$_glint_hist_file
    HISTSIZE=${HISTSIZE:-50000}
    SAVEHIST=${SAVEHIST:-50000}
    # Independence: do not pull other panes' commands into this session's
    # buffer between prompts.
    unsetopt share_history 2>/dev/null
    # Per-command append so a crashed pane doesn't lose its history.
    setopt inc_append_history
    setopt hist_ignore_dups

    # On pane exit: fold this pane's history back into the global file
    # so future fresh panes (and shells outside Glint) see what we typed.
    _glint_merge_history_on_exit() {
        [[ -f $HISTFILE ]] || return
        fc -W 2>/dev/null
        local global=${HOME}/.zsh_history
        # cat-append is good enough; zsh history lines are independent.
        # We accept a small dup risk on the global file in exchange for
        # not corrupting it under concurrent pane closes.
        cat $HISTFILE >> $global 2>/dev/null
    }
    # zshexit runs once when the shell exits cleanly; trap covers signals.
    typeset -ga zshexit_functions
    zshexit_functions+=(_glint_merge_history_on_exit)

    unset _glint_hist_dir _glint_hist_file
fi

# ---------------------------------------------------------------------------
# 3. History-driven ghost-text completion (zsh-autosuggestions).
# Skipped if the user already has it loaded — we respect their config.
# ---------------------------------------------------------------------------
if [[ -z ${ZSH_AUTOSUGGEST_VERSION-} && -r ${ZDOTDIR}/zsh-autosuggestions.zsh ]]; then
    # Quiet by default; user can re-enable with their own config.
    ZSH_AUTOSUGGEST_STRATEGY=(history)
    # Dim foreground 8 = ANSI bright black, readable on light & dark themes.
    : ${ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE:='fg=8'}
    # Disable for very long buffers so a giant paste doesn't spin.
    : ${ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE:=200}

    source ${ZDOTDIR}/zsh-autosuggestions.zsh

    # Keybindings — keep Tab as native zsh completion. Right / End fully
    # accept the suggestion; Ctrl-Right / Alt-F accept one word at a time
    # (zsh-autosuggestions auto-integrates with forward-word because
    # forward-word is in the default PARTIAL_ACCEPT_WIDGETS list).
    # ^[[C = Right arrow. ^E = End. ^[[1;5C = Ctrl-Right. ^[f = Alt-F.
    bindkey '^[[C'    autosuggest-accept 2>/dev/null
    bindkey '^E'      autosuggest-accept 2>/dev/null
    bindkey '^[[1;5C' forward-word       2>/dev/null
    bindkey '^[f'     forward-word       2>/dev/null
fi
