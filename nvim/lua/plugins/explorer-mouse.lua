-- Make the built-in Snacks file explorer (<leader>e) fully mouse-drivable,
-- similar to VS Code's file tree: single click already moves the cursor
-- (mouse=a, set by LazyVim). This adds double-click to open/toggle,
-- ctrl-click to multi-select, and right-click for a context menu with
-- new file/folder, rename, copy, cut/move, paste, delete, open, refresh.
local context_menu_actions = {
  { "New File/Folder (end name with / for folder)", "explorer_add" },
  { "Rename", "explorer_rename" },
  { "Copy", "explorer_copy" },
  { "Cut / Move", "explorer_move" },
  { "Paste", "explorer_paste" },
  { "Delete", "explorer_del" },
  { "Open externally", "explorer_open" },
  { "Refresh", "explorer_update" },
}

local function explorer_context_menu(picker)
  local mouse = vim.fn.getmousepos()
  vim.api.nvim_win_set_cursor(0, { mouse.line, 0 })

  local item = picker:current()
  vim.ui.select(context_menu_actions, {
    prompt = item and item.name or "Explorer",
    format_item = function(action)
      return action[1]
    end,
  }, function(choice)
    if choice then
      picker:action(choice[2])
    end
  end)
end

return {
  {
    "folke/snacks.nvim",
    opts = {
      picker = {
        actions = {
          explorer_context_menu = explorer_context_menu,
        },
        sources = {
          explorer = {
            win = {
              list = {
                keys = {
                  ["<2-LeftMouse>"] = "confirm",
                  ["<C-LeftMouse>"] = "select_and_next",
                  ["<RightMouse>"] = "explorer_context_menu",
                },
              },
            },
          },
        },
      },
    },
  },
}
