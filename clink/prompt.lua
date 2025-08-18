os.setenv("PROMPT", "$E[92m$P$E[36m $E[93m$+$E[37m$G$G$G$E[0m ")

local p = clink.promptfilter(30)

function p:filter(prompt)
    prompt
end

function p:rightfilter(prompt)
    local sep = #prompt > 0 and "  " or ""
    return "\x1b["..settings.get("color.description").."m"..os.date()..sep..prompt
end
