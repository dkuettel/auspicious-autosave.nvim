local M = {}

-- these are the values for vim.b.autosave, they can be used for the status line
-- nil          state has not yet been computed
-- readonly     read-only file, no autosaving
-- locked       locked file (the file might still be writeable), no autosaving
-- autosave     normal autosave operation
-- modified     no autosaving, but the file has been modified
-- saved        no autosaving, the file has been saved and not changed since
-- disappeared  used to autosave, but then the file disappeared
--              wont autosave anymore, as that would recreate a file that was potentially removed on purpose
--              a manual :w or :bd can resolve the situation
---@alias State nil | "readonly" | "locked" | "autosave" |  "modified" | "saved" | "disappeared"

---@param buf integer
local function update_state(buf)
    assert(buf > 0)

    local state = vim.b[buf].autosave ---@type State
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
                -- in this case it is a new file
                vim.api.nvim_buf_call(buf, function()
                    vim.cmd([[:silent w]])
                end)
                state = "autosave"
            else
                state = "disappeared"
            end
        end
    end

    vim.b[buf].autosave = state
end

---@param context vim.api.keyset.create_autocmd.callback_args
local function on_buffer_event(context)
    -- NOTE we reevaluate the situation every time again
    -- we dont use vim.b.autosave from last time, because things could change
    -- vim.b.autosave is mainly set so that it can be used for the status line
    update_state(context.buf)

    if vim.b.autosave == "autosave" then
        -- :update only saves if the file has been modified, no-op otherwise
        -- :silent prevents "xyz bytes write" from popping up everytime, but also hides error messages
        -- :lockmarks prevents marks like [ and ] from changing
        vim.cmd("lockmarks silent update")
    end
end

---@param context vim.api.keyset.create_autocmd.callback_args
local function on_focus_gained(context) ---@diagnostic disable-line: unused-local
    local bufs = vim.api.nvim_list_bufs()
    local missing = {}
    for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_loaded(buf) then
            update_state(buf)
            if vim.b[buf].autosave == "disappeared" then
                table.insert(missing, buf)
            end
        end
    end
    if #missing > 0 then
        print("Some buffer's files have disappeared: " .. table.concat(missing, ", "))
    end
end

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
            callback = on_buffer_event,
            nested = true, -- NOTE otherwise we dont trigger BufWrite for others
        }
    )

    vim.api.nvim_create_autocmd({ "FocusGained" }, {
        group = group,
        desc = "auspicious-autosave focus",
        callback = on_focus_gained,
        nested = true,
    })
end

return M
