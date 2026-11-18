# Configurations
Configurations of the most used apps &amp; utilities.

## Total Commander
The profile includes 23 file-color rules, keyboard shortcuts and three custom column views. The link colors use the NTLinks content plugin. [Set up the Total Commander profile](totalcmd/README.md).

![Total Commander file panels showing blue Mathematica notebooks beside source files, images and documents](/totalcmd/totalcmd_screen.png)

![Total Commander's Define colors by file type dialog showing the rules in priority order](/totalcmd/totalcmd_types_colors.png)

# Wezterm

![WezTerm screenshot](/wezterm/wezterm_screen.png)

# Clink

default_inputrc:
```
# Completion commands
# https://chrisant996.github.io/clink/clink.html#completion-commands
# 
#           complete
"\e[1;5B":  possible-completions    # Ctrl-Down
#           insert-completions
"\t":       menu-complete           # Tab
"\e[Z":     menu-complete-backward  # Shift-Tab
#           old-menu-complete
#           delete-char-or-list
```

clink_settings:
```
# name: Enable automatic suggestions
# type: boolean
autosuggest.enable = False
```
