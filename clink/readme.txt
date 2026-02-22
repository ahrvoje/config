# put files into local clink profile directory, e.g.:
c:\Users\<USER>\AppData\Local\clink\clink_settings
c:\Users\<USER>\AppData\Local\clink\prompt_time.lua
c:\Users\<USER>\AppData\Local\clink\default_inputrc

# completions
git clone https://github.com/vladimir-kotikov/clink-completions
clink installscripts c:\Users\H\AppData\Local\clink\clink-completions\

# fzf
winget install fzf
git clone https://github.com/chrisant996/clink-fzf
clink installscripts c:\Users\H\AppData\Local\clink\clink-fzf\

# zoxide
winget install zoxide
git clone https://github.com/shunsambongi/clink-zoxide
clink installscripts c:\Users\H\AppData\Local\clink\clink-zoxide\
