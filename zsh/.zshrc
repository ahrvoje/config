#!zsh

[ -f $HOME/.zshlocal ] && source $HOME/.zshlocal

# WezTerm shell-state protocol. All encoding and emission is done by zsh
# builtins: prompt hooks must never spawn base64, pwd, ps, or another helper.
_wez_base64_ascii() {
  emulate -L zsh
  local input=$1 alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
  local output='' ch
  local -i i a b c i1 i2 i3 i4 length=${#input}
  for (( i = 1; i <= length; i += 3 )); do
    printf -v a '%d' "'${input[i]}"
    b=0
    c=0
    (( i + 1 <= length )) && printf -v b '%d' "'${input[i + 1]}"
    (( i + 2 <= length )) && printf -v c '%d' "'${input[i + 2]}"
    i1=$(( a / 4 + 1 ))
    i2=$(( (a % 4) * 16 + b / 16 + 1 ))
    i3=$(( (b % 16) * 4 + c / 64 + 1 ))
    i4=$(( c % 64 + 1 ))
    output+=${alphabet[i1]}
    output+=${alphabet[i2]}
    if (( i + 1 <= length )); then
      output+=${alphabet[i3]}
    else
      output+='='
    fi
    if (( i + 2 <= length )); then
      output+=${alphabet[i4]}
    else
      output+='='
    fi
  done
  REPLY=$output
}

set_user_var() {
  # WEZTERM_PANE doesn't cross the wsl.exe boundary unless WSLENV forwards it,
  # so inside WSL emit unconditionally; other terminals ignore unknown OSC
  [[ -n $WEZTERM_PANE || -n $WSL_DISTRO_NAME ]] || return 0
  # write to the tty, not stdout: callers may run inside $(...) captures;
  # silently skip when there is no tty (e.g. pane already torn down on exit)
  {
    if [ -n "$TMUX" ]; then
      # tmux passthrough quotes the inner ESC by doubling it. tmux itself must
      # have `set -g allow-passthrough on`; do not spawn tmux here to mutate it.
      printf '\033Ptmux;\033\033]1337;SetUserVar=%s=%s\007\033\\' "$1" "$2"
    else
      printf '\033]1337;SetUserVar=%s=%s\007' "$1" "$2"
    fi
  } 2>/dev/null >/dev/tty
}

set_user_var_value() {
  _wez_set_user_vars "$1" "$2"
}

# Accept name/value pairs and send every OSC in one tty write. This keeps the
# prompt hook deterministic without paying one console syscall per field.
_wez_set_user_vars() {
  [[ -n $WEZTERM_PANE || -n $WSL_DISTRO_NAME ]] || return 0
  emulate -L zsh
  local output='' name value
  while (( $# >= 2 )); do
    name=$1
    value=$2
    shift 2
    _wez_base64_ascii "$value"
    if [[ -n $TMUX ]]; then
      output+=$'\ePtmux;\e\e]1337;SetUserVar='${name}'='${REPLY}$'\a\e\\'
    else
      output+=$'\e]1337;SetUserVar='${name}'='${REPLY}$'\a'
    fi
  done
  print -rn -- "$output" 2>/dev/null >/dev/tty
}

_wez_uri_encode_path() {
  emulate -L zsh
  unsetopt multibyte
  local input=$1 output='' ch hex
  local -i i
  for (( i = 1; i <= ${#input}; ++i )); do
    ch=${input[i]}
    if [[ $ch == [A-Za-z0-9/._~:-] ]]; then
      output+=$ch
    else
      printf -v hex '%%%02X' "'$ch"
      output+=$hex
    fi
  done
  REPLY=$output
}

_wez_emit_cwd() {
  [[ -n $WEZTERM_PANE || -n $WSL_DISTRO_NAME ]] || return 0
  _wez_uri_encode_path "$PWD"
  local _wez_encoded_cwd=$REPLY
  (( ++_wez_cwd_seq ))
  _wez_base64_ascii "$$:$_wez_cwd_seq"
  {
    if [[ -n $TMUX ]]; then
      printf '\033Ptmux;\033\033]7;file://%s%s\007\033\\\033Ptmux;\033\033]1337;SetUserVar=cwd_ready=%s\007\033\\' \
        "${HOST:-}" "$_wez_encoded_cwd" "$REPLY"
    else
      printf '\033]7;file://%s%s\007\033]1337;SetUserVar=cwd_ready=%s\007' \
        "${HOST:-}" "$_wez_encoded_cwd" "$REPLY"
    fi
  } 2>/dev/null >/dev/tty
  # This marker is deliberately emitted after OSC 7. WezTerm may read CWD
  # only after seeing it, so get_current_working_dir never falls back to ps.
}

typeset -gi _wez_command_seq=0
typeset -gi _wez_state_seq=0
typeset -gi _wez_cwd_seq=0
_wez_publish_state() {
  (( ++_wez_state_seq ))
  _wez_set_user_vars "$@" state_serial "$_wez_state_seq"
}

_wez_prompt_ready() {
  # OSC 7 is parsed first; state_serial then commits one coherent repaint.
  _wez_emit_cwd
  _wez_publish_state \
    shell_integration on \
    shell_name zsh \
    shell_prompt on \
    process_name zsh \
    command_token '' \
    nvim off \
    venv ${${VIRTUAL_ENV:+on}:-off} \
    zsh on
}

_wez_preexec() {
  emulate -L zsh
  local -a words
  words=(${(z)1})
  local token command=command
  for token in "${words[@]}"; do
    token=${(Q)token}
    # Leading NAME=value words alter the command environment; they are not
    # the process label. Parsing beyond this remains deliberately best-effort
    # display metadata and is never used to route a destructive action.
    if [[ $token == *=* && $token != */* ]]; then
      continue
    fi
    command=$token
    break
  done
  command=${command:t}
  command=${command:l}
  command=${command%.exe}
  command=${command//[^A-Za-z0-9_.+-]/}
  [[ -n $command ]] || command=command
  (( ++_wez_command_seq ))
  # Opaque identity only; elapsed time starts when WezTerm receives it. No
  # wall-clock timestamp crosses this protocol.
  _wez_publish_state \
    shell_prompt off \
    process_name "$command" \
    command_token "$$:$_wez_command_seq"
}

autoload -Uz add-zsh-hook
add-zsh-hook precmd _wez_prompt_ready
add-zsh-hook preexec _wez_preexec
_z_wez_zshexit() {
  _wez_publish_state \
    shell_prompt off \
    command_token '' \
    process_name '' \
    shell_integration off \
    zsh off
}
add-zsh-hook zshexit _z_wez_zshexit

# Establish a conservative state before the first precmd hook and clear flags
# a process killed in this pane may have left behind.
_wez_publish_state \
  shell_integration on \
  shell_name zsh \
  shell_prompt off \
  process_name zsh \
  command_token '' \
  zsh on \
  fzf off \
  nvim off \
  venv ${${VIRTUAL_ENV:+on}:-off}

# special Windows-specific cases for msys64/usr/bin/zsh.exe
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || "$MSYSTEM" != "" || "$WSL_DISTRO_NAME" != "" ]]; then
  zmodload zsh/terminfo 2>/dev/null

  for map in emacs viins; do
    # Home key
    bindkey -M $map '^[[H'  beginning-of-line     # ESC [ H
    bindkey -M $map '^[OH'  beginning-of-line     # ESC O H
    bindkey -M $map '^[[1~' beginning-of-line     # ESC [ 1 ~
  
    # End key
    bindkey -M $map '^[[F'  end-of-line           # ESC [ F
    bindkey -M $map '^[OF'  end-of-line           # ESC O F
    bindkey -M $map '^[[4~' end-of-line           # ESC [ 4 ~
  
    # Delete / PgUp / PgDn keys
    bindkey -M $map '^[[3~' delete-char           # Delete
    bindkey -M $map '^[[5~' up-line-or-history    # PageUp
    bindkey -M $map '^[[6~' down-line-or-history  # PageDown

    # Insert key
    bindkey -M $map "${terminfo[kich1]:-^[[2~}" overwrite-mode
  done
fi

# normalize git conventions matching GitHub Desktop for Windows
# msys/cygwin only — NOT WSL, where autocrlf/filemode would mangle a native Linux checkout
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || -n "$MSYSTEM" ]]; then
  # only when missing — otherwise three git spawns + config rewrites per shell
  () {
    local cfg=
    [[ -r $HOME/.gitconfig ]] && cfg="$(<$HOME/.gitconfig)"
    if [[ $cfg != *"autocrlf = true"* || $cfg != *"filemode = false"* || $cfg != *"ignorecase = true"* ]]; then
      git config --global core.autocrlf true
      git config --global core.filemode false
      git config --global core.ignorecase true
    fi
  }
fi

# History file and size
HISTFILE=$HOME/.zsh_history
HISTSIZE=100000
SAVEHIST=100000

setopt SHARE_HISTORY       # write each command as it runs and pull in new ones from other panes (implies INC_APPEND_HISTORY)
setopt HIST_FCNTL_LOCK     # lock HISTFILE during writes; safe across parallel panes
setopt HIST_IGNORE_DUPS    # skip command repeated back-to-back
setopt HIST_IGNORE_SPACE   # skip commands starting with a space
setopt HIST_REDUCE_BLANKS  # strip superfluous whitespace

# Keep a history of visited directories
DIRSTACKFILE="$HOME/.zdirs"  # dirs stack persistent across sessions
if [[ -f "$DIRSTACKFILE" ]] && (( ${#dirstack} == 0 )); then
	dirstack=("${(@f)"$(< "$DIRSTACKFILE")"}")
	[[ -d "${dirstack[1]}" ]] && cd -- "${dirstack[1]}"
fi
chpwd_dirstack() {
	# write-then-rename avoids interleaved/corrupted content when multiple panes cd concurrently
	local tmp="$DIRSTACKFILE.$$"
	print -l -- "$PWD" "${(u)dirstack[@]}" > "$tmp" && mv -f -- "$tmp" "$DIRSTACKFILE"
}
add-zsh-hook -Uz chpwd chpwd_dirstack

setopt AUTO_PUSHD          # push old dir onto stack on cd
setopt PUSHD_SILENT        # don't echo stack
setopt PUSHD_IGNORE_DUPS
setopt PUSHD_TO_HOME
DIRSTACKSIZE=10            # keep 10 recent dirs


alias -- -='cd -'
alias -- --='dirs -v'  # Print each dir stack entry on a separate line
alias -- -0='cd -0'
alias -- -1='cd -1'
alias -- -2='cd -2'
alias -- -3='cd -3'
alias -- -4='cd -4'
alias -- -5='cd -5'
alias -- -6='cd -6'
alias -- -7='cd -7'
alias -- -8='cd -8'
alias -- -9='cd -9'

alias ~="cd ~"
alias ..="cd .."
alias ...="cd ../.."
alias ....="cd ../../.."
alias .....="cd ../../../.."

# use eza instead of ls (keep plain ls if eza is missing)
(( $+commands[eza] )) && alias ls='eza -1laa'

# Prompt before overwrite
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Print each PATH entry on a separate line
alias path='echo -e ${PATH//:/\\n}'

# Get week number
alias week='date +%V'

alias gb='git branch'
alias gc='git commit'
alias gd='git diff'
alias gs='git status'
alias grep='grep -i --color=auto'

# completion system, cached dump skips the compaudit security scan on every start
# (on WSL, also set `skip_global_compinit=1` in ~/.zshenv so /etc/zsh/zshrc's own
# uncached compinit doesn't run first and pay that cost anyway)
autoload -Uz compinit
_zcompdump=${XDG_CACHE_HOME:-$HOME/.cache}/zcompdump
mkdir -p -- "${_zcompdump:h}"
if [[ -s $_zcompdump ]]; then
  compinit -C -d "$_zcompdump"
else
  compinit -d "$_zcompdump"
fi
unset _zcompdump

# fzf
# invoke config if exists
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

fzf_root=/
fzf_skip=.git,node_modules  # fzf's own default skip list
# special Windows-specific cases for msys64/usr/bin/zsh.exe
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || -n "$MSYSTEM" ]]; then
  fzf_root=(C:/ D:/)
  # whole-drive walk: skip huge system trees, and never follow symlinks —
  # Windows junctions (e.g. AppData\Local\Application Data) can self-loop and hang the walker
  fzf_skip="$fzf_skip,AppData,Windows,ProgramData,\$RECYCLE.BIN,System Volume Information"
elif [[ -n "$WSL_DISTRO_NAME" ]]; then
  # keep the walk on the Linux filesystem: /mnt/* drives go over 9P (painfully
  # slow), /proc and /sys are bottomless; use the msys zsh for Windows drives.
  # NOTE: skips match directory NAMES anywhere, so a repo dir literally named
  # e.g. 'sys' is skipped too — acceptable for a global search.
  fzf_skip="$fzf_skip,mnt,proc,sys,dev,run,snap,tmp"
fi

# Flag 'fzf is running' via user var while fzf owns the pane, so wezterm routes
# Esc/PageUp/PageDown to fzf. Needed because wezterm's process detection cannot
# see through wslhost/msys interop to know fzf is in the foreground, and fzf in
# --height mode never enters the alternate screen wezterm otherwise keys off.
_fzf_with_var() {
  set_user_var fzf b24=   # base64('on')
  "$@"
  local rc=$?
  set_user_var fzf b2Zm   # base64('off')
  return $rc
}
# cover fzf runs this config doesn't own (~/.fzf.zsh widgets, manual CLI use);
# the widgets below invoke fzf via `env`, which bypasses this function wrapper
fzf() { _fzf_with_var command fzf "$@" }

fzf_find_file_local() {
  local file
  zle -I  # release the line editor's grip on the TTY

  # </dev/tty forces TTY stdin so fzf uses its walker
  # ignore any default FZF_ commands
  file="$(
    _fzf_with_var env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
      fzf -i --height=80% --reverse --border \
          --walker=file,hidden,follow \
          --walker-root=. </dev/tty \
          --preview 'bat --style=numbers --color=always --line-range :200 {} || file -b {}' \
          --preview-window=right:50%
  )" || return

  [[ -n $file ]] && LBUFFER+="$file"
}
zle -N fzf_find_file_local
# Bind Alt-. in both keymaps
bindkey -M emacs '^[.' fzf_find_file_local
bindkey -M viins '^[.' fzf_find_file_local

fzf_find_file_global() {
  local file
  zle -I  # release the line editor's grip on the TTY

  # </dev/tty forces TTY stdin so fzf uses its walker
  # ignore any default FZF_ commands
  file="$(
    _fzf_with_var env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
      fzf -i --height=80% --reverse --border \
          --walker=file,hidden \
          --walker-root="${fzf_root[@]}" \
          --walker-skip="$fzf_skip" </dev/tty \
          --preview 'bat --style=numbers --color=always --line-range :200 {} || file -b {}' \
          --preview-window=right:50%
  )" || return

  [[ -n $file ]] && LBUFFER+="$file"
}
zle -N fzf_find_file_global
# Bind Alt-f in both keymaps
bindkey -M emacs '^[f' fzf_find_file_global
bindkey -M viins '^[f' fzf_find_file_global

fzf_cd() {
  local dir
  zle -I  # let full-screen UI take the TTY

  dir="$(
    _fzf_with_var env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
      fzf -i --height=80% --reverse --border \
        --walker=dir,hidden \
        --walker-root="${fzf_root[@]}" \
        --walker-skip="$fzf_skip" \
        --prompt='cd> ' \
        --preview 'ls -la {} 2>/dev/null || echo "{}"' \
        --preview-window=right:50%:wrap \
        < /dev/tty
  )" || return

  [[ -n $dir ]] && builtin cd -- "$dir" && zle reset-prompt
}
zle -N fzf_cd
# Bind to Alt-c 
bindkey -M emacs '^[c' fzf_cd
bindkey -M viins '^[c' fzf_cd

fzf_history_search() {
  local cmd
  zle -I  # release ZLE before full-screen UI

  # Use newest-first, no numbers: much faster and no parsing needed
  cmd="$(
    _fzf_with_var env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
      fzf --height=80% --reverse --border \
        --prompt='history> ' --no-sort \
        --query "$LBUFFER" \
        < <(builtin fc -rln 1)
  )" || return

  [[ -n $cmd ]] && LBUFFER="$cmd"
}
zle -N fzf_history_search
# Bind to Alt-r
bindkey -M emacs '^[r' fzf_history_search
bindkey -M viins '^[r' fzf_history_search

# show active python venv at the start of the prompt, e.g. "(myenv) "
export VIRTUAL_ENV_DISABLE_PROMPT=1  # venv activate must not edit PS1 itself
_venv_prompt() {
  if [[ -n $VIRTUAL_ENV ]]; then
    local name=${VIRTUAL_ENV:t}
    # generic dir names tell nothing, show the project dir instead
    [[ $name == (.venv|venv) ]] && name=${VIRTUAL_ENV:h:t}
    psvar[1]="($name) "
  else
    psvar[1]=
  fi
}
add-zsh-hook precmd _venv_prompt
PROMPT="%B%F{11}%1v%f%b$PROMPT"
