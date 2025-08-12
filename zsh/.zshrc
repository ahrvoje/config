path+=(
	/Applications/WezTerm.app/Contents/MacOS/
	/Applications/nvim-macos-arm64/bin/
)

export PATH

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
PROMPT='%F{cyan}%~%f${git_branch}%f${git_untracked}${git_unstaged}${git_staged} > '

# Right prompt: time
RPROMPT='%*'
