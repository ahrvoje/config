#!zsh

# Debian/Ubuntu's /etc/zsh/zshrc runs its own uncached `compinit` (full compaudit
# scan) before this user's .zshrc gets a chance to install a cached one. Skip it
# here so only the cached compinit in .zshrc ever runs. Harmless on hosts without
# that system rc (msys64, macOS).
skip_global_compinit=1
