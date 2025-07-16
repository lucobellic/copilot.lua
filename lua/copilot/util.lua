local config = require("copilot.config")
local logger = require("copilot.logger")

local M = {}

---@return { editorInfo: copilot_editor_info, editorPluginInfo: copilot_editor_plugin_info }
function M.get_editor_info()
  local info = {
    editorInfo = {
      name = "Neovim",
      version = string.match(vim.fn.execute("version"), "NVIM v(%S+)"),
    },
    editorPluginInfo = {
      name = "copilot.lua",
      -- reflects version of github/copilot-language-server-release
      version = "1.344.0",
    },
  }
  return info
end

local copilot_lua_version = nil

function M.get_copilot_lua_version()
  if not copilot_lua_version then
    local plugin_version_ok, plugin_version = pcall(function()
      local plugin_dir = M.get_plugin_path()
      return vim.fn.systemlist(string.format("cd %s && git rev-parse HEAD", plugin_dir))[1]
    end)
    copilot_lua_version = plugin_version_ok and plugin_version or "dev"
  end
  return copilot_lua_version
end

---@return boolean should_attach
---@return string? no_attach_reason
function M.should_attach()
  local ft = config.filetypes
  local ft_disabled, ft_disabled_reason = require("copilot.client.filetypes").is_ft_disabled(vim.bo.filetype, ft)

  if ft_disabled then
    return not ft_disabled, ft_disabled_reason
  end

  local bufnr = vim.api.nvim_get_current_buf()
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local conf_attach = config.should_attach(bufnr, bufname)

  if not conf_attach then
    return false, "copilot is disabled"
  end

  return true
end

local function relative_path(absolute)
  local relative = vim.fn.fnamemodify(absolute, ":.")
  if string.sub(relative, 0, 1) == "/" then
    return vim.fn.fnamemodify(absolute, ":t")
  end
  return relative
end

-- Helper function to ensure document content is sent to language server
local function sync_document_content(uri, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  local client = require("copilot.client").get()
  if not client then
    logger.error("No Copilot client available for document sync")
    return false
  end

  -- Get buffer content
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Get document info
  local filetype = vim.bo[bufnr].filetype
  local language_id = filetype ~= "" and filetype or "plaintext"
  local version = vim.api.nvim_buf_get_var(bufnr, "changedtick")

  -- Create textDocument/didOpen notification
  local did_open_params = {
    textDocument = {
      uri = uri,
      languageId = language_id,
      version = version,
      text = content,
    }
  }

  -- Send the notification to ensure the server has the document content
  logger.debug("Sending textDocument/didOpen for: " .. uri)
  local success = client.notify("textDocument/didOpen", did_open_params)

  if not success then
    logger.error("Failed to send textDocument/didOpen notification")
    return false
  end

  return true
end

-- Helper function to create a valid URI for Copilot language server
local function create_copilot_uri(absolute_path)
  -- If buffer has no name (new unsaved buffer), create a meaningful URI
  if absolute_path == "" then
    local bufnr = vim.api.nvim_get_current_buf()
    local filetype = vim.bo[bufnr].filetype
    local extension = filetype ~= "" and ("." .. filetype) or ".txt"

    -- Create a URI based on current working directory + buffer number
    local cwd = vim.fn.getcwd()
    local buffer_name = string.format("untitled-%d%s", bufnr, extension)
    absolute_path = vim.fs.joinpath(cwd, buffer_name)
  end

  return vim.uri_from_fname(absolute_path)
end

function M.get_doc()
  local absolute = vim.api.nvim_buf_get_name(0)
  local bufnr = vim.api.nvim_get_current_buf()

  -- Create a valid URI for Copilot
  local copilot_uri = create_copilot_uri(absolute)
  if not copilot_uri then
    logger.error("Failed to create valid URI from " .. absolute)
    return nil
  end

  -- For unsaved files, ensure document content is sent to language server
  local file_exists = vim.fn.filereadable(vim.uri_to_fname(copilot_uri)) == 1
  if not file_exists then
    if not sync_document_content(copilot_uri, bufnr) then
      logger.error("Failed to sync document content with language server")
      return nil
    end
  end

  -- Create LSP position params with our custom URI
  local params = vim.lsp.util.make_position_params(0, "utf-16")
  params.textDocument.uri = copilot_uri

  local doc = {
    uri = params.textDocument.uri,
    version = vim.api.nvim_buf_get_var(0, "changedtick"),
    relativePath = relative_path(absolute),
    insertSpaces = vim.o.expandtab,
    tabSize = vim.fn.shiftwidth(),
    indentSize = vim.fn.shiftwidth(),
    position = params.position,
  }

  return doc
end

-- Used by copilot.cmp so watch out if moving it
function M.get_doc_params(overrides)
  overrides = overrides or {}

  local params = vim.tbl_extend("keep", {
    doc = vim.tbl_extend("force", M.get_doc(), overrides.doc or {}),
  }, overrides)
  params.textDocument = {
    uri = params.doc.uri,
    version = params.doc.version,
    relativePath = params.doc.relativePath,
  }
  params.position = params.doc.position

  return params
end

M.get_plugin_path = function()
  local copilot_path = vim.api.nvim_get_runtime_file("lua/copilot/init.lua", false)[1]
  if vim.fn.filereadable(copilot_path) ~= 0 then
    return vim.fn.fnamemodify(copilot_path, ":h:h:h")
  else
    logger.error("could not read" .. copilot_path)
  end
end

---@param str string
---@return integer
function M.strutf16len(str)
  if vim.fn.exists("*strutf16len") == 1 then
    return vim.fn.strutf16len(str)
  else
    return vim.fn.strchars(vim.fn.substitute(str, [==[\\%#=2[^\u0001-\uffff]]==], "  ", "g"))
  end
end

return M
