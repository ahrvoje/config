#!zsh

[ -f $HOME/.zshlocal ] && source $HOME/.zshlocal

# set terminal UserVar 'zsh' to 'on'/'off' on enter/exit
set_user_var() {
  if [ -n "$TMUX" ]; then
    printf '\033Ptmux;\033]1337;SetUserVar=%s=%s\007\033\\' "$1" "$2"
  else
    printf '\033]1337;SetUserVar=%s=%s\007' "$1" "$2"
  fi
}
# on start    base64('on') = 'b24='
set_user_var zsh b24=
autoload -Uz add-zsh-hook
# on exit     base64('off') = 'b2Zm'
_z_wez_zshexit() { set_user_var zsh b2Zm }
add-zsh-hook zshexit _z_wez_zshexit

# special Windows-specific cases for msys64/usr/bin/zsh.exe
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || "$MSYSTEM" != "" || "$WSL_DISTRO_NAME" != "" ]]; then
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
    zmodload zsh/terminfo 2>/dev/null || true
    bindkey -M $map "${terminfo[kich1]-'^[[2~'}" overwrite-mode
  done
  
  # normalize git conventions matching GitHub Desktop for Windows
  git config --global core.autocrlf true
  git config --global core.filemode false
  git config --global core.ignorecase true
fi

# History file and size
HISTFILE=$HOME/.zsh_history
HISTSIZE=100000
SAVEHIST=100000

# Keep a history of visited directories
autoload -Uz add-zsh-hook

DIRSTACKFILE="$HOME/.zdirs"  # dirs stack persistent across sessions
if [[ -f "$DIRSTACKFILE" ]] && (( ${#dirstack} == 0 )); then
	dirstack=("${(@f)"$(< "$DIRSTACKFILE")"}")
	[[ -d "${dirstack[1]}" ]] && cd -- "${dirstack[1]}"
fi
chpwd_dirstack() {
	print -l -- "$PWD" "${(u)dirstack[@]}" > "$DIRSTACKFILE"
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

# use eza instead of ls
alias ls='eza -1laa'

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

# fzf
# invoke config if exists
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

fzf_root=/
# special Windows-specific cases for msys64/usr/bin/zsh.exe
if [[ "$OSTYPE" == msys* || "$OSTYPE" == cygwin* || -n "$MSYSTEM" ]]; then
  fzf_root=(C:/ D:/)
fi

fzf_find_file_local() {
  local file
  zle -I  # release the line editor's grip on the TTY

  # </dev/tty forces TTY stdin so fzf uses its walker
  # ignore any default FZF_ commands
  file="$(
    env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
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
    env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
      fzf -i --height=80% --reverse --border \
          --walker=file,hidden,follow \
          --walker-root="${fzf_root[@]}" </dev/tty \
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
    env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
      fzf -i --height=80% --reverse --border \
        --walker=dir,hidden,follow \
        --walker-root="${fzf_root[@]}" \
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
    env -u FZF_DEFAULT_COMMAND -u FZF_CTRL_T_COMMAND -u FZF_ALT_C_COMMAND \
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

eval "$(starship init zsh)"
