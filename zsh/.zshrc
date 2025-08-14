path+=(
	/Applications/WezTerm.app/Contents/MacOS/
	/Applications/nvim-macos-arm64/bin/
)
export PATH

# Keep a history of visited directories
setopt AUTO_PUSHD      # push old dir onto stack on cd
setopt PUSHD_SILENT    # don't echo stack
DIRSTACKSIZE=10        # keep 10 recent dirs

alias dirs="dirs -v"  # Print each dir stack entry on a separate line
alias -- -='cd -'
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

# Prompt before overwrite
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# Print each PATH entry on a separate line
alias path='echo -e ${PATH//:/\\n}'

# Get week number
alias week='date +%V'

alias gs='git status'
alias grep='grep --color=auto'

# Enable parameter/command expansion in prompts
setopt PROMPT_SUBST

# Git branch info
autoload -Uz vcs_info
zstyle ':vcs_info:*' enable git
zstyle ':vcs_info:git:*' formats '%b'
precmd() {
	if git rev-parse --is-inside-work-tree &>/dev/null; then
		# Get branch name
		vcs_info
		
		branch_icon="⎇"
		[[ $(locale charmap) == "UTF-8" ]] && branch_icon=""
		
		if [[ -n $vcs_info_msg_0_ ]]; then
			git_branch=" %F{20}${branch_icon}${vcs_info_msg_0_}%f"  # gray
		fi

        # Count untracked files ("??" lines)
        local u_cnt
        u_cnt=$(git status --porcelain 2>/dev/null | awk '$1=="??"{c++} END{print c+0}')
        if (( u_cnt > 0 )); then
            git_untracked=" %F{16}u${u_cnt}%f "  # calm orange
        else
            git_untracked=" %F{10}u0%f "  # calm green
        fi

        # Count unstaged modified files (2nd status column == 'M')
        local m_cnt
        m_cnt=$(git status --porcelain 2>/dev/null | awk 'substr($0,2,1)=="M"{c++} END{print c+0}')
        if (( m_cnt > 0 )); then
            git_unstaged="%F{197}m${m_cnt}%f "  # calm red
        else
            git_unstaged="%F{10}m0%f "  # calm green
        fi

        # Count staged files (1st status column == 'M' or 'A' or 'R' etc.)
        local s_cnt
        s_cnt=$(git status --porcelain 2>/dev/null | awk 'substr($0,1,1)!=" " && substr($0,1,1)!="?"{c++} END{print c+0}')
        if (( s_cnt > 0 )); then
            git_staged="%F{197}s${s_cnt}%f"  # calm red
        else
            git_staged="%F{10}s0%f"  # calm green
        fi
    else
		git_branch=""
		git_untracked=""
		git_unstaged=""
		git_staged=""
	fi
}

# Left prompt: full path + optional git branch
# Use %~ for ~ in $HOME; use %/ for absolute path always.
PROMPT='%F{cyan}%~%f${git_branch}${git_untracked}${git_unstaged}${git_staged} > '

# Right prompt: time
RPROMPT='%*'
