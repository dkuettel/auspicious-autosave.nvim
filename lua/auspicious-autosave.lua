local M = {} -- public interface
local m = {} -- private

--- public interface ------------------------------------------

function M.setup()
    -- controls CursorHold and CursorHoldI events
    -- (idle time before they are triggered in milliseconds)
    -- might want to check that it's not set to a longer value again later
    vim.opt.updatetime = 500

    -- checks if files have changed on disk, especially on FocusGained
    vim.opt.autoread = true

    -- in case anything slips by the events
    -- (will write when windows change buffers in various ways)
    vim.opt.autowrite = true
    vim.opt.autowriteall = true

    m.register_events()
end

---@param buf? integer
---@return boolean
function M.enabled(buf)
    buf = m.real_buf(buf)
    return m.enableds[buf]
end

---@param v boolean
---@param buf? integer
function M.set(v, buf)
    buf = m.real_buf(buf)
    m.enableds[buf] = v
end

---@param buf? integer
function M.enable(buf)
    M.set(true, buf)
end

---@param buf? integer
function M.disable(buf)
    M.set(false, buf)
end

---@param buf? integer
---@return boolean
function M.toggle(buf)
    buf = m.real_buf(buf)
    m.enableds[buf] = not m.enableds[buf]
    return m.enableds[buf]
end

---@alias State "readonly" | "locked" | "autosave" |  "modified" | "saved" | "disappeared"
-- readonly     read-only file, no autosaving
-- locked       locked file (the file might still be writeable), no autosaving
-- autosave     normal autosave operation
-- modified     no autosaving, but the file has been modified
-- saved        no autosaving, the file has been saved and not changed since
-- disappeared  used to autosave, but then the file disappeared
--              wont autosave anymore, as that would recreate a file that was potentially removed on purpose
--              a manual :w or :bd can resolve the situation

---@param buf? integer
---@return State
function M.state(buf)
    buf = m.real_buf(buf)
    m.update_state(buf)
    return m.states[buf]
end

--- private ------------------------------------------

---@type boolean[]
m.enableds = {}

---@type State[]
m.states = {}

---@param buf integer
function m.update_state(buf)
    assert(buf > 0)

    local enabled = m.enableds[buf]
    if enabled == nil then
        enabled = true
    end

    local state = m.states[buf]
    local bo = vim.bo[buf]
    local name = vim.api.nvim_buf_get_name(buf)

    if bo.readonly then
        state = "readonly"
    elseif not bo.modifiable then
        state = "locked"
    elseif
        -- no file
        name == ""
        -- special buffers (help, terminal, popups, ...) dont need saving
        or bo.buftype ~= ""
        -- buffers that disappear anyway, probably they are not meant to be saved
        or (bo.bufhidden == "wipe" or bo.bufhidden == "delete")
        -- fugitive special buffers (eg, diff view where write means stage changes, do it explicitely)
        or string.find(name, "^fugitive://") ~= nil
        -- efs is slow
        or string.find(name, "^/efs/") ~= nil
        -- neogit commits the automatic comments in the message when using autosave (?)
        or bo.filetype == "NeogitCommitMessage"
        -- explicit manual saving
        or not enabled
    then -- at this point it's a buffer we don't want to autosave
        if bo.modified then
            state = "modified"
        else
            state = "saved"
        end
    else -- at this point it's a normal buffer that we want to autosave
        if vim.uv.fs_stat(name) then ---@diagnostic disable-line: undefined-field
            state = "autosave"
        else
            if state == nil then
                -- NOTE use to check what lands here when it shouldnt
                -- vim.print { name = name, buftype = bo.buftype, bufhidden = bo.bufhidden, filetype = bo.filetype }
                -- in this case it is a new file
                vim.api.nvim_buf_call(buf, function()
                    vim.cmd([[:silent write ++p]])
                end)
                state = "autosave"
            else
                state = "disappeared"
            end
        end
    end

    m.enableds[buf] = enabled
    m.states[buf] = state
end

---@param context vim.api.keyset.create_autocmd.callback_args
function m.on_buffer_event(context)
    -- NOTE we reevaluate the situation every time again
    -- we dont use vim.b.autosave from last time, because things could change
    -- vim.b.autosave is mainly set so that it can be used for the status line
    m.update_state(context.buf)

    if m.states[context.buf] == "autosave" then
        -- :update only saves if the file has been modified, no-op otherwise
        -- ++p makes parent folders if necessary
        -- :silent prevents "xyz bytes write" from popping up everytime, but also hides error messages
        -- :lockmarks prevents marks like [ and ] from changing
        vim.cmd("lockmarks silent update ++p")
    end
end

---@param context vim.api.keyset.create_autocmd.callback_args
function m.on_focus_gained(context) ---@diagnostic disable-line: unused-local
    local bufs = vim.api.nvim_list_bufs()
    local missing = {}
    for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_loaded(buf) then
            m.update_state(buf)
            if m.states[buf] == "disappeared" then
                table.insert(missing, buf)
            end
        end
    end
    if #missing > 0 then
        print("Some buffer's files have disappeared: " .. table.concat(missing, ", "))
    end
end

function m.register_events()
    -- interesting events:
    --   InsertLeave, TextChanged, CursorHold
    --   TextChangedI, CursorHoldI, but TextChangedI is on every keystroke
    --   FocusGained, FocusLost (needs terminal or tmux to be configured to send those escape codes)
    --   BufEnter is used so that vim.bo.autosave is set correctly from the beginning (nice for your status line)

    local group = vim.api.nvim_create_augroup("auspicious-autosave", { clear = true })

    vim.api.nvim_create_autocmd(
        { "InsertLeave", "TextChanged", "CursorHold", "CursorHoldI", "FocusLost", "BufEnter" },
        {
            group = group,
            desc = "auspicious-autosave buffer",
            callback = m.on_buffer_event,
            nested = true, -- NOTE otherwise we dont trigger BufWrite for others
        }
    )

    vim.api.nvim_create_autocmd({ "FocusGained" }, {
        group = group,
        desc = "auspicious-autosave focus",
        callback = m.on_focus_gained,
        nested = true,
    })
end

---@param buf? integer
---@return integer buf not 0
function m.real_buf(buf)
    if buf == nil or buf == 0 then
        buf = vim.api.nvim_get_current_buf()
    end
    return buf
end

return M
