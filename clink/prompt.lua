local p = clink.promptfilter(30)
-- 
-- local function slurp(p)
--     local f = io.open(p, 'r')
--     if not f then return nil end
-- 
--     local s = f:read('*a')
--     f:close()
--     return s
-- end
-- 
-- local function current_branch_or_sha()
--     local gd = os.getcwd():gsub('\\', '/') .. '/.git'
-- 
--     -- prefer branch recorded by rebase
--     local hn = slurp(gd..'/rebase-merge/head-name') or slurp(gd..'/rebase-apply/head-name')
--     if hn then
--         return (hn:gsub('^refs/heads/',''):gsub('%s+$',''))
--     end
-- 
--     -- fall back to HEAD
--     local head = slurp(gd..'/HEAD') or ''
--     local b = head:match('ref:%s*refs/heads/(.-)%s*$')
--     if b then return b end
-- 
--     local sha = head:match('^%x+')
--     return sha and sha:sub(1,7) or nil
-- end

function p:filter(prompt)
    local esc, reset = '\x1b[', '\x1b[0m'
    local green, cyan, yellow, white = esc..'92m', esc..'36m', esc..'93m', esc..'37m'

--    local cwd = os.getcwd()
--    local git_branch = current_branch_or_sha()
--    if not git_branch then
--        git_branch = ''
--    else
--        git_branch = ' '..cyan..git_branch
--    end
--
--    return table.concat({ green, cwd, git_branch, white, ' >>>', reset, ' ' })
    return table.concat({ white, '>', reset, ' ' })
end

function p:rightfilter(prompt)
    local sep = #prompt > 0 and '  ' or ''
    return '\x1b['..settings.get('color.description')..'m'..os.date()..sep..prompt
end
