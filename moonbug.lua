-- moonbug debugger - https://github.com/atomicptr/moonbug
--
-- Copyright 2026 Christopher Kaster <me@atomicptr.de>
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
-- documentation files (the “Software”), to deal in the Software without restriction, including without limitation
-- the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and
-- to permit persons to whom the Software is furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all copies or substantial portions
-- of the Software.
--
-- THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO
-- THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
-- TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.
local M = {}

local version = { 0, 1, 1 }
local default_port = 8888

-- for performance reasons we cap the amount of items a table can render
local table_max_items = 999

-- instruction budget between timeout checks during `evaluate`
local eval_count_budget = 50000

-- default seconds before `evaluate` is aborted
local eval_default_timeout = 5

-- pretty printer indent width
local pp_indent_width = 2

---@type moonbug.dap.Capabilities
local server_capabilities = {
    supportsCompletionsRequest = true,
    supportsConditionalBreakpoints = true,
    supportsConfigurationDoneRequest = true,
    supportsEvaluateForHovers = true,
    supportsExceptionInfoRequest = true,
    supportsHitConditionalBreakpoints = true,
    supportsLoadedSourcesRequest = true,
    supportsLogPoints = true,
    supportsModulesRequest = true,
    supportsSetExpression = true,
    supportsSetVariable = true,
    supportsTerminateRequest = true,
    supportsValueFormattingOptions = true,

    additionalModuleColumns = {
        { attributeName = "kind", label = "Kind" },
    },
    completionTriggerCharacters = { ".", ":" },
    exceptionBreakpointFilters = {
        { filter = "error", label = "error(...) / assert(...)", default = true },
        { filter = "pcall", label = "caught by pcall(...) / resume(...)", default = false },
        { filter = "uncaught", label = "uncaught errors", default = true },
    },
}

local hidden_keys = {
    ["_G"] = true,
    ["_ENV"] = true,
}

---Moonbug version as major/minor/patch
---@param flat? boolean
---@return { major: integer, minor: integer, patch: integer }|integer[] Returns integer array when flat is set
function M.version(flat)
    if flat then
        return { version[1], version[2], version[3] }
    end

    return {
        major = version[1],
        minor = version[2],
        patch = version[3],
    }
end

---Moonbug version as a string
---@return string
function M.version_string()
    return table.concat(version, ".")
end

-- for filtering out moonbug from stack traces
local self_src = debug.getinfo(1, "S").source

local is_luajit = rawget(_G, "jit") ~= nil
local jit_off = is_luajit and rawget(_G, "jit").off or nil

-- forward declarations
local debug_hook
local remove_debug_hook
local uninstall_wrappers

-- since we're overriding them later we should store them
local assert = assert
local coroutine_create = coroutine.create
local coroutine_resume = coroutine.resume
local coroutine_wrap = coroutine.wrap
local error = error
local pcall = pcall
local print = print
local require = require
local xpcall = xpcall

-- luajit: Turn off jit
if is_luajit and jit_off then
    jit_off()
end

----> Compatibility & Polyfills

---Sets the environment of a given function
---@type fun(f: (fun(...): any), env: table<string, any>): fun(...): any
local setfenv = rawget(_G, "setfenv")
    or function(f, env)
        assert(type(f) == "function")
        assert(type(env) == "table")

        local i = 1

        while true do
            local name, _ = debug.getupvalue(f, i)
            if not name then
                break
            end

            if name == "_ENV" then
                debug.setupvalue(f, i, env)
                break
            end

            i = i + 1
        end

        return f
    end

---Compiles a string of lua code into an executable closure
---@type fun(str: string, chunkname?: string): ((fun(...): any)?, string?)
local loadstring = rawget(_G, "loadstring")
    or function(str, chunkname)
        assert(type(str) == "string", "string expected")
        return load(function()
            local s = str
            str = nil
            return s
        end, chunkname)
    end

---Packs zero or more arguments into an array-like table with an `.n` total count field
---@generic T
---@type fun(...: T): { [integer]: T, n: integer }
local table_pack = rawget(table, "pack") or function(...)
    return { n = select("#", ...), ... }
end

---Returns the elements from the given list table as individual return values
---@generic T
---@type fun(list: table<integer, T>, i?: integer, j?: integer): T
local table_unpack = rawget(_G, "unpack") or table.unpack

---@class moonbug.Socket
---@field settimeout fun(self, value?: number, mode?: "b"|"t"): number, string
---@field close      fun(self): number
---@field bind       fun(self, address: string, port: integer): integer, string
---@field connect    fun(self, address: string, port: integer): integer, string
---@field listen     fun(self, backlog?: integer): integer, string
---@field accept     fun(self): moonbug.Socket, string
---@field send       fun(self, data: string, i?: integer, j?: integer): integer, string, integer
---@field receive    fun(self, pattern?: integer|"*l"|"*a", prefix?: string): string, string, string
---@field shutdown   fun(self, mode: "receive"|"send"|"both"): integer, string
---@field setoption  fun(self, option: "keepalive"|"reuseaddr"|"tcp-nodelay"|"linger", value?: any): integer, string

---@class moonbug.compat.SocketLib
---@field bind    fun(host: string, port: integer): moonbug.Socket
---@field gettime fun(): integer

---@class moonbug.compat.JsonLib
---@field encode fun(v: any): string|nil
---@field decode fun(s: string): any

---@class moonbug.compat.Libs
---@field socket? moonbug.compat.SocketLib
---@field json?   moonbug.compat.JsonLib

---@class moonbug.Compat
---@field libs      moonbug.compat.Libs
---@field log_print fun(message: string)

---@type moonbug.Compat
M.compat = {
    libs = {
        json = nil,
        socket = nil,
    },
    log_print = print,
}

----> Logger

---@enum moonbug.LogLevel
local log_level = {
    trace = 1,
    debug = 2,
    info = 3,
    warning = 4,
    error = 5,

    -- special levels
    off = 88,
    fatal = 99,
}

local min_log_level = log_level[os.getenv "MOONBUG_LOG" or "info"] or log_level.info

---@param level "trace"|"debug"|"info"|"warning"|"error"|"fatal"|"off"
function M.set_min_log_level(level)
    min_log_level = log_level[level or "info"] or log_level.info
end

---@param level moonbug.LogLevel
---@return string
local function log_level_to_string(level)
    if level == log_level.trace then
        return "trc"
    elseif level == log_level.debug then
        return "dbg"
    elseif level == log_level.info then
        return "inf"
    elseif level == log_level.warning then
        return "wrn"
    elseif level == log_level.error then
        return "err"
    elseif level == log_level.fatal then
        return "ftl"
    elseif level == log_level.off then
        return "off"
    end

    error("unknown log level: " .. tostring(level))
end

---@param level moonbug.LogLevel
---@param fmt   string
---@param ...   any
local function print_log(level, fmt, ...)
    if level < min_log_level then
        return
    end

    local message = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    local output = string.format("moonbug:%s: %s", log_level_to_string(level), message)

    M.compat.log_print(output)

    if level == log_level.fatal then
        os.exit(1, true)
        return
    end
end

local log = {
    trace = function(fmt, ...)
        print_log(log_level.trace, fmt, ...)
    end,
    debug = function(fmt, ...)
        print_log(log_level.debug, fmt, ...)
    end,
    info = function(fmt, ...)
        print_log(log_level.info, fmt, ...)
    end,
    warning = function(fmt, ...)
        print_log(log_level.warning, fmt, ...)
    end,
    error = function(fmt, ...)
        print_log(log_level.error, fmt, ...)
    end,
    fatal = function(fmt, ...)
        print_log(log_level.fatal, fmt, ...)
    end,
}

----> Helpers

---@param s      string
---@param prefix string
---@return boolean
local function str_starts_with(s, prefix)
    return s:sub(1, #prefix) == prefix
end

---Indent string
---@param s     string
---@param depth integer
---@return string
local function indent(s, depth)
    return string.rep(" ", pp_indent_width * depth) .. s
end

---Serializes any Lua object into a string representation
---@param value  any
---@param depth? integer
---@param seen?  table
local function readable_tostring(value, depth, seen)
    depth = depth or 0
    seen = seen or {}

    local t = type(value)

    if t == "string" then
        return string.format("%q", value)
    elseif t ~= "table" then
        if t == "function" or t == "thread" or t == "userdata" then
            return string.format("<%s>", tostring(value))
        end

        return tostring(value)
    end

    if seen[value] then
        return string.format("<%s>", tostring(value))
    end

    seen[value] = true

    local parts = { string.format("{ -- %s", tostring(value)) }

    local keys = {}

    for k in pairs(value) do
        table.insert(keys, k)
    end

    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    local has_values = false

    for _, k in ipairs(keys) do
        local v = value[k]
        local kv = string.format(
            type(k) == "number" and "[%s] = %s," or "%s = %s,",
            tostring(k),
            readable_tostring(v, depth + 1, seen)
        )

        table.insert(parts, indent(kv, depth + 1))
        has_values = true
    end

    if not has_values then
        return indent(string.format("{} -- %s", tostring(value)), depth)
    end

    table.insert(parts, indent("}", depth))

    return table.concat(parts, "\n")
end

local function resolve_json_lib()
    if M.compat.libs.json then
        return
    end

    -- cjson installed? Use that
    local cjson_ok, cjson = pcall(require, "cjson")
    if cjson_ok then
        M.compat.libs.json = cjson
        return
    end

    -- globally available json (e.g. Defold)
    if _G["json"] and _G["json"].encode and _G["json"].decode then
        M.compat.libs.json = _G["json"]
    end

    -- json.lua
    local json_ok, json = pcall(require, "json")
    if json_ok then
        M.compat.libs.json = json
        return
    end

    log.fatal "`cjson` could not be imported, nor has something else been configured"
end

local function resolve_socket_lib()
    if M.compat.libs.socket then
        return
    end

    local luasocket_ok, luasocket = pcall(require, "socket")
    if luasocket_ok then
        M.compat.libs.socket = luasocket
        return
    end

    log.fatal "`socket` (luasocket) could not be imported, nor has something else been configured"
end

local function resolve_libs()
    resolve_json_lib()
    resolve_socket_lib()
end

---@return moonbug.compat.JsonLib?
local function json()
    if not M.compat.libs.json then
        resolve_json_lib()
    end

    return M.compat.libs.json
end

---@return moonbug.compat.SocketLib?
local function socket()
    if not M.compat.libs.socket then
        resolve_socket_lib()
    end

    return M.compat.libs.socket
end

---Is this a user frame (e.g. not from the debugger or a C frame)
---@param info debuginfo
---@return boolean
local function is_user_frame(info)
    return info.what ~= "C" and info.source ~= self_src
end

---Returns true if passed a pseudo or temp variable
---@param name string
---@return boolean
local function is_pseudo_variable(name)
    return str_starts_with(name, "(")
end

---@param v any
---@return string
local function safe_tostring(v)
    local ok, res = pcall(tostring, v)
    if ok then
        return res
    end

    return string.format("<error: %s>", tostring(res))
end

---Creates a slice from a list, index is 0 based
---@generic T
---@param list         T[]
---@param start_index? integer
---@param count?       integer
---@return any
local function slice(list, start_index, count)
    -- no start and no limit: return the list as is
    if not start_index and (count == nil or count == 0) then
        return list
    end

    start_index = start_index or 0
    count = (count == nil or count == 0) and (#list - start_index) or count

    if count <= 0 then
        return {}
    end

    local out = {}

    for i = start_index + 1, math.min(start_index + count, #list) do
        table.insert(out, list[i])
    end

    return out
end

---@param tbl table
---@return integer
local function table_array_length(tbl)
    local n = 0

    while rawget(tbl, n + 1) ~= nil do
        n = n + 1
    end

    return n
end

---@param tbl    table
---@param length integer
---@return string[]
local function table_named_keys(tbl, length)
    local keys = {}

    for k in pairs(tbl) do
        if not (type(k) == "number" and k >= 1 and k <= length) then
            table.insert(keys, k)
        end
    end

    table.sort(keys, function(a, b)
        return safe_tostring(a) < safe_tostring(b)
    end)

    return keys
end

---@param name string
---@return string|number
local function table_key_from_name(name)
    local n = name:match "^%[(%d+)%]$"
    if n then
        local res = tonumber(n)
        ---@cast res number
        return res
    end

    return name
end

---@param tbl    table
---@param length integer
---@return integer
local function table_named_count(tbl, length)
    local n = 0

    -- NOTE: keep the same as `table_named_keys`
    for k in pairs(tbl) do
        if not (type(k) == "number" and k >= 1 and k <= length) then
            n = n + 1
        end
    end

    return n
end

---@param base string?
---@param key  any
---@return string?
local function table_evaluate_name(base, key)
    if not base then
        return nil
    end

    local key_type = type(key)
    if key_type == "string" then
        key = string.format("%q", key)
    elseif key_type == "number" then
        key = tostring(key)
    elseif key_type == "boolean" then
        key = tostring(key)
    else
        return nil
    end

    return string.format("%s[%s]", base, key)
end

---@param name any
---@return string?
local function global_evaluate_name(name)
    if type(name) ~= "string" then
        return nil
    end

    return string.format("_G[%q]", name)
end

---Converts camel case name to snake case
---@param str string
---@return string
local function camel2snake(str)
    local result = str:gsub("%u", "_%1"):lower()

    if result:byte(1) == 95 then -- 95 is ASCII '_'
        return result:sub(2)
    end

    return result
end

----> Debug Adapter Protocol

---@enum moonbug.DapEvent
local dap_events = {
    continued = "continued",
    initialized = "initialized",
    loaded_source = "loadedSource",
    module = "module",
    output = "output",
    stopped = "stopped",
    terminated = "terminated",
}

---@class moonbug.dap.ProtocolMessage
---@field seq  integer
---@field type "request"|"response"|"event"|string

---@class moonbug.dap.Request : moonbug.dap.ProtocolMessage
---@field type       "request"
---@field command    string
---@field arguments? table

---@class moonbug.dap.AttachRequest : moonbug.dap.Request
---@field command   "attach"
---@field arguments moonbug.dap.AttachArguments

---@class moonbug.dap.AttachArguments
---@field project_root_dir? string
---@field cwd?              string
---@field workspaceFolder?  string

---@class moonbug.dap.CompletionsRequest : moonbug.dap.Request
---@field command   "completions"
---@field arguments moonbug.dap.CompletionsArguments

---@class moonbug.dap.CompletionsArguments
---@field text     string
---@field column   integer
---@field frameId? integer

---@class moonbug.dap.ConfigurationDoneRequest : moonbug.dap.Request
---@field command   "configurationDone"
---@field arguments table

---@class moonbug.dap.ContinueRequest : moonbug.dap.Request
---@field command   "continue"
---@field arguments moonbug.dap.ContinueArguments

---@class moonbug.dap.ContinueArguments
---@field threadId integer

---@class moonbug.dap.DisconnectRequest : moonbug.dap.Request
---@field command   "disconnect"
---@field arguments { restart?: boolean }

---@class moonbug.dap.EvaluateRequest : moonbug.dap.Request
---@field command   "evaluate"
---@field arguments moonbug.dap.EvaluateArguments

---@class moonbug.dap.EvaluateArguments
---@field expression string
---@field frameId?   integer
---@field context?   "watch"|"repl"|"hover"|"clipboard"|"variables"
---@field format?    moonbug.dap.ValueFormat

---@class moonbug.dap.ExceptionInfoRequest : moonbug.dap.Request
---@field command   "exceptionInfo"
---@field arguments moonbug.dap.ExceptionInfoArguments

---@class moonbug.dap.ExceptionInfoArguments
---@field threadId integer

---@class moonbug.dap.InitializeRequest : moonbug.dap.Request
---@field command   "initialize"
---@field arguments moonbug.dap.InitializeRequestArguments

---@class moonbug.dap.InitializeRequestArguments
---@field clientID?                            string ID of client using adapter.
---@field clientName?                          string Human-readable name of client.
---@field adapterID                            string ID of debug adapter.
---@field locale?                              string ISO-639 locale (e.g. `en-US`, `de-CH`).
---@field linesStartAt1?                       boolean If true, line numbers are 1-based (default).
---@field columnsStartAt1?                     boolean If true, column numbers are 1-based (default).
---@field pathFormat?                          "path"|"uri"|string Format for paths (default `"path"`).
---@field supportsVariableType?                boolean Supports `type` attribute for variables.
---@field supportsVariablePaging?              boolean Supports variable paging.
---@field supportsRunInTerminalRequest?        boolean Supports `runInTerminal` request.
---@field supportsMemoryReferences?            boolean Supports memory references.
---@field supportsProgressReporting?           boolean Supports progress reporting.
---@field supportsInvalidatedEvent?            boolean Supports `invalidated` event.
---@field supportsMemoryEvent?                 boolean Supports `memory` event.
---@field supportsArgsCanBeInterpretedByShell? boolean Supports `argsCanBeInterpretedByShell` on `runInTerminal`.
---@field supportsStartDebuggingRequest?       boolean Supports `startDebugging` request.
---@field supportsANSIStyling?                 boolean Interprets ANSI escape sequences in output/variable fields.

---@class moonbug.dap.LaunchRequest : moonbug.dap.Request
---@field command   "launch"
---@field arguments moonbug.dap.LaunchArguments

---@class moonbug.dap.LaunchArguments
---@field project_root_dir? string
---@field cwd?              string
---@field workspaceFolder?  string

---@class moonbug.dap.LoadedSourcesRequest : moonbug.dap.Request
---@field command "loadedSources"

---@class moonbug.dap.ModulesRequest : moonbug.dap.Request
---@field command   "modules"
---@field arguments? moonbug.dap.ModulesArguments

---@class moonbug.dap.ModulesArguments
---@field startModule? integer
---@field moduleCount? integer

---@class moonbug.dap.NextRequest : moonbug.dap.Request
---@field command   "next"
---@field arguments moonbug.dap.NextArguments

---@class moonbug.dap.NextArguments
---@field threadId integer

---@class moonbug.dap.PauseRequest : moonbug.dap.Request
---@field command   "pause"
---@field arguments moonbug.dap.PauseArguments

---@class moonbug.dap.PauseArguments
---@field threadId integer

---@class moonbug.dap.ScopesRequest : moonbug.dap.Request
---@field command   "scopes"
---@field arguments moonbug.dap.ScopesArguments

---@class moonbug.dap.ScopesArguments
---@field frameId integer

---@class moonbug.dap.SetBreakpointsRequest : moonbug.dap.Request
---@field command   "setBreakpoints"
---@field arguments moonbug.dap.SetBreakpointsArguments

---@class moonbug.dap.SetBreakpointsArguments
---@field source          moonbug.dap.Source
---@field breakpoints?    moonbug.dap.SourceBreakpoint[]
---@field lines?          integer[]
---@field sourceModified? boolean

---@class moonbug.dap.SetExceptionBreakpointsRequest : moonbug.dap.Request
---@field command   "setExceptionBreakpoints"
---@field arguments moonbug.dap.SetExceptionBreakpointsArguments

---@class moonbug.dap.SetExceptionBreakpointsArguments
---@field filters string[]

---@class moonbug.dap.SetExpressionRequest : moonbug.dap.Request
---@field command   "setExpression"
---@field arguments moonbug.dap.SetExpressionArguments

---@class moonbug.dap.SetExpressionArguments
---@field expression string
---@field value      string
---@field frameId?   integer
---@field format?    moonbug.dap.ValueFormat

---@class moonbug.dap.SetVariableRequest : moonbug.dap.Request
---@field command   "setVariable"
---@field arguments moonbug.dap.SetVariableArguments

---@class moonbug.dap.SetVariableArguments
---@field variablesReference integer
---@field name               string
---@field value              string

---@class moonbug.dap.StackTraceRequest : moonbug.dap.Request
---@field command   "stackTrace"
---@field arguments moonbug.dap.StackTraceArguments

---@class moonbug.dap.StackTraceArguments
---@field threadId integer
---@field format?  moonbug.dap.StackFrameFormat

---@class moonbug.dap.StepInRequest : moonbug.dap.Request
---@field command   "stepIn"
---@field arguments moonbug.dap.StepInArguments

---@class moonbug.dap.StepInArguments
---@field threadId integer

---@class moonbug.dap.StepOutRequest : moonbug.dap.Request
---@field command   "stepOut"
---@field arguments moonbug.dap.StepOutArguments

---@class moonbug.dap.StepOutArguments
---@field threadId integer

---@class moonbug.dap.TerminateRequest : moonbug.dap.Request
---@field command "terminate"

---@class moonbug.dap.ThreadsRequest : moonbug.dap.Request
---@field command "threads"

---@class moonbug.dap.VariablesRequest : moonbug.dap.Request
---@field command   "variables"
---@field arguments moonbug.dap.VariablesArguments

---@class moonbug.dap.VariablesArguments
---@field variablesReference integer
---@field filter?            "indexed"|"named"
---@field start?             integer
---@field count?             integer
---@field format?            moonbug.dap.ValueFormat

---@class moonbug.dap.Response : moonbug.dap.ProtocolMessage
---@field type        "response"
---@field request_seq integer
---@field success     boolean
---@field command     string
---@field message?    "cancelled"|"notStopped"|string
---@field body?       any

---@class moonbug.dap.ErrorResponse : moonbug.dap.Response
---@field body { error?: moonbug.dap.Message }

---@class moonbug.dap.CompletionsResponseBody
---@field targets moonbug.dap.CompletionItem[]

---@class moonbug.dap.ContinueResponseBody
---@field allThreadsContinued? boolean

---@class moonbug.dap.ErrorResponseBody
---@field error moonbug.dap.Message

---@class moonbug.dap.EvaluateResponseBody
---@field result             string
---@field type?              string
---@field presentationHint?  moonbug.dap.VariablePresentationHint
---@field variablesReference integer
---@field namedVariables?    integer
---@field indexedVariables?  integer

---@class moonbug.dap.ExceptionInfoDetails
---@field message?        string
---@field typeName?       string
---@field fullTypeName?   string
---@field evaluateName?   string
---@field stackTrace?     string
---@field innerException? moonbug.dap.ExceptionInfoDetails[]

---@class moonbug.dap.ExceptionInfoResponseBody
---@field exceptionId  string
---@field description? string
---@field breakMode    "never"|"always"|"unhandled"|"userUnhandled"
---@field details?     moonbug.dap.ExceptionInfoDetails

---@class moonbug.dap.LoadedSourcesResponseBody
---@field sources moonbug.dap.Source[]

---@class moonbug.dap.ModulesResponseBody
---@field modules      moonbug.dap.Module[]
---@field totalModules integer

---@alias moonbug.dap.ResponseBody
---| moonbug.dap.Capabilities
---| moonbug.dap.CompletionsResponseBody
---| moonbug.dap.ContinueResponseBody
---| moonbug.dap.ErrorResponseBody
---| moonbug.dap.EvaluateResponseBody
---| moonbug.dap.ExceptionInfoResponseBody
---| moonbug.dap.LoadedSourcesResponseBody
---| moonbug.dap.ModulesResponseBody
---| moonbug.dap.ScopesResponseBody
---| moonbug.dap.SetBreakpointsResponseBody
---| moonbug.dap.SetExpressionResponseBody
---| moonbug.dap.SetVariableResponseBody
---| moonbug.dap.StackTraceResponseBody
---| moonbug.dap.ThreadsResponseBody
---| moonbug.dap.VariablesResponseBody

---@class moonbug.dap.ScopesResponseBody
---@field scopes moonbug.dap.Scope[]

---@class moonbug.dap.SetBreakpointsResponseBody
---@field breakpoints moonbug.dap.Breakpoint[]

---@class moonbug.dap.SetExpressionResponseBody
---@field value               string
---@field type?               string
---@field presentationHint?   moonbug.dap.VariablePresentationHint
---@field variablesReference  integer
---@field namedVariables?     integer
---@field indexedVariables?   integer

---@alias moonbug.dap.SetVariableResponseBody moonbug.dap.Variable

---@class moonbug.dap.StackTraceResponseBody
---@field stackFrames moonbug.dap.StackFrame[]
---@field totalFrames? integer

---@class moonbug.dap.ThreadsResponseBody
---@field threads moonbug.dap.Thread[]

---@class moonbug.dap.VariablesResponseBody
---@field variables moonbug.dap.Variable[]

---@class moonbug.dap.Breakpoint
---@field id?                    integer
---@field verified               boolean
---@field message?               string
---@field source?                moonbug.dap.Source
---@field line?                  integer
---@field column?                integer
---@field instructionReference?  string
---@field offset?                integer

---@class moonbug.dap.BreakpointMode
---@field mode         string
---@field label        string
---@field description? string
---@field appliesTo    "source"|"exception"|"instruction"|"string"

---@class moonbug.dap.Capabilities
---@field supportsConfigurationDoneRequest?      boolean Supports `configurationDone` request.
---@field supportsFunctionBreakpoints?           boolean Supports function breakpoints.
---@field supportsConditionalBreakpoints?        boolean Supports conditional breakpoints.
---@field supportsHitConditionalBreakpoints?     boolean Supports hit-conditional breakpoints.
---@field supportsEvaluateForHovers?             boolean Supports side-effect free `evaluate` for hovers.
---@field exceptionBreakpointFilters?            moonbug.dap.ExceptionBreakpointsFilter[]
---@field supportsStepBack?                      boolean Supports `stepBack` and `reverseContinue`.
---@field supportsSetVariable?                   boolean Supports setting variable values.
---@field supportsRestartFrame?                  boolean Supports restarting a frame.
---@field supportsGotoTargetsRequest?            boolean Supports `gotoTargets` request.
---@field supportsStepInTargetsRequest?          boolean Supports `stepInTargets` request.
---@field supportsCompletionsRequest?            boolean Supports `completions` request.
---@field completionTriggerCharacters?           string[] REPL completion trigger characters (default `.`).
---@field supportsModulesRequest?                boolean Supports `modules` request.
---@field additionalModuleColumns?               moonbug.dap.ColumnDescriptor[] Additional module information columns.
---@field supportedChecksumAlgorithms?           moonbug.dap.ChecksumAlgorithm[] Supported checksum algorithms.
---@field supportsRestartRequest?                boolean Supports `restart` request.
---@field supportsExceptionOptions?              boolean Supports `exceptionOptions` on `setExceptionBreakpoints`.
---@field supportsValueFormattingOptions?        boolean Supports `format` attribute on evaluation/variables/stackTrace.
---@field supportsExceptionInfoRequest?          boolean Supports `exceptionInfo` request.
---@field supportTerminateDebuggee?              boolean Supports `terminateDebuggee` on `disconnect`.
---@field supportSuspendDebuggee?                boolean Supports `suspendDebuggee` on `disconnect`.
---@field supportsDelayedStackTraceLoading?      boolean Supports delayed loading of stack frames.
---@field supportsLoadedSourcesRequest?          boolean Supports `loadedSources` request.
---@field supportsLogPoints?                     boolean Supports log points via `logMessage`.
---@field supportsTerminateThreadsRequest?       boolean Supports `terminateThreads` request.
---@field supportsSetExpression?                 boolean Supports `setExpression` request.
---@field supportsTerminateRequest?              boolean Supports `terminate` request.
---@field supportsDataBreakpoints?               boolean Supports data breakpoints.
---@field supportsReadMemoryRequest?             boolean Supports `readMemory` request.
---@field supportsWriteMemoryRequest?            boolean Supports `writeMemory` request.
---@field supportsDisassembleRequest?            boolean Supports `disassemble` request.
---@field supportsCancelRequest?                 boolean Supports `cancel` request.
---@field supportsBreakpointLocationsRequest?    boolean Supports `breakpointLocations` request.
---@field supportsClipboardContext?              boolean Supports `clipboard` context in `evaluate`.
---@field supportsSteppingGranularity?           boolean Supports stepping granularity argument.
---@field supportsInstructionBreakpoints?        boolean Supports instruction-based breakpoints.
---@field supportsExceptionFilterOptions?        boolean Supports `filterOptions` on `setExceptionBreakpoints`.
---@field supportsSingleThreadExecutionRequests? boolean Supports `singleThread` execution requests.
---@field supportsDataBreakpointBytes?           boolean Supports `asAddress` and `bytes` in `dataBreakpointInfo`.
---@field breakpointModes?                       moonbug.dap.BreakpointMode[] Supported breakpoint modes.
---@field supportsANSIStyling?                   boolean Supports ANSI escape sequences in output/variable fields.

---@alias moonbug.dap.ChecksumAlgorithm "MD5"|"SHA1"|"SHA256"|"timestamp"

---@class moonbug.dap.ColumnDescriptor
---@field attributeName string
---@field label         string
---@field format?       string
---@field type?         "string"|"number"|"boolean"|"unixTimestampUTC"
---@field width?        integer

---@class moonbug.dap.CompletionItem
---@field label   string
---@field text?   string
---@field type?   "method"|"function"|"constructor"|"field"|"variable"|"class"|"interface"|"module"|"property"|"unit"|"value"|"enum"|"keyword"|"snippet"|"text"|"color"|"file"|"reference"|"customcolor"
---@field start?  integer
---@field length? integer

---@class moonbug.dap.Event : moonbug.dap.ProtocolMessage
---@field type  "event"
---@field event string
---@field body? any

---@class moonbug.dap.ExceptionBreakpointsFilter
---@field filter       string
---@field label        string
---@field description? string
---@field default?     boolean

---@class moonbug.dap.Message
---@field id         integer
---@field format     string
---@field variables? table<string, string>

---@class moonbug.dap.Module
---@field id              integer
---@field name            string
---@field path?           string
---@field isOptimized?    boolean
---@field isUserCode?     boolean
---@field version?        string
---@field symbolStatus?   string
---@field symbolFilePath? string
---@field dateTimeStamp?  string
---@field addressRange?   string
---@field kind?           string

---@class moonbug.dap.Scope
---@field name                string
---@field variablesReference? integer
---@field presentationHint?   "arguments"|"locals"|"registers"|"returnValue"|string
---@field expensive           boolean

---@class moonbug.dap.Source
---@field name? string Short name of the source
---@field path? string Path of the source shown in UI

---@class moonbug.dap.SourceBreakpoint
---@field line          integer
---@field column?       integer
---@field condition?    string
---@field hitCondition? string
---@field logMessage?   string
---@field mode?         string

---@class moonbug.dap.StackFrame
---@field id      integer
---@field name    string
---@field source? moonbug.dap.Source
---@field line    integer
---@field column  integer

---@class moonbug.dap.StackFrameFormat : moonbug.dap.ValueFormat
---@field parameters?      boolean Display stack frame parameters.
---@field parameterTypes?  boolean Display stack frame parameter types.
---@field parameterNames?  boolean Display stack frame parameter names.
---@field parameterValues? boolean Display stack frame parameter values.
---@field line?            boolean Display line numbers in frame names.
---@field module?          boolean Display module names in frame names.
---@field includeAll?      boolean Include hidden and non-user frames.

---@class moonbug.dap.Thread
---@field id   integer
---@field name string

---@class moonbug.dap.ValueFormat
---@field hex? boolean Display the value in hexadecimal.

---@class moonbug.dap.Variable
---@field name                string
---@field value               string
---@field type?               string
---@field evaluateName?       string
---@field variablesReference  integer
---@field indexedVariables?   integer
---@field namedVariables?     integer
---@field presentationHint?   moonbug.dap.VariablePresentationHint

---@class moonbug.dap.VariablePresentationHint
---@field kind?       "property"|"method"|"class"|"data"|"event"|"baseClass"|"innerClass"|"interface"|"mostDerivedClass"|"virtual"|"dataBreakpoint"
---@field attributes? ("static"|"constant"|"readOnly"|"rawString"|"hasObjectId"|"canHaveObjectId"|"hasSideEffects"|"hasDataBreakpoint")[]
---@field visibility? "public"|"private"|"protected"|"internal"|"final"
---@field lazy?       boolean

---@class moonbug.DapReadState
---@field header_partial  string
---@field headers_done    boolean
---@field content_length  integer?
---@field payload_partial string

---@type table<moonbug.Socket, moonbug.DapReadState>
local dap_read_states = setmetatable({}, { __mode = "k" })

---@param client moonbug.Socket
---@return moonbug.DapReadState
local function dap_read_state(client)
    local state = dap_read_states[client]

    if not state then
        state = {
            header_partial = "",
            headers_done = false,
            payload_partial = "",
        }
        dap_read_states[client] = state
    end

    return state
end

---@param client moonbug.Socket
---@return integer?
---@return string?
local function parse_content_length(client)
    assert(client, "socket client can't be nil")
    local state = dap_read_state(client)

    while not state.headers_done do
        local line, err, partial = client:receive("*l", state.header_partial)
        if not line then
            state.header_partial = partial or state.header_partial

            if err == "closed" then
                dap_read_states[client] = nil
                return nil, "closed"
            elseif err == "timeout" then
                return nil, "timeout"
            end

            log.error("socket read error: %s", tostring(err))

            return nil, err
        end

        state.header_partial = ""

        -- dap headers end with an empty line
        if line == "" then
            state.headers_done = true

            if not state.content_length then
                dap_read_states[client] = nil
                return nil, "missing Content-Length"
            end

            return state.content_length, nil
        end

        local length_str = line:match "^content%-length%s*:%s*(%d+)%s*$"
        if not length_str then
            -- fallback matching for case insensitive
            length_str = line:lower():match "^content%-length%s*:%s*(%d+)%s*$"
        end

        if length_str then
            state.content_length = tonumber(length_str)
        end
    end

    return state.content_length, nil
end

---@param client moonbug.Socket
---@return moonbug.dap.ProtocolMessage?
---@return string?
local function read_message(client)
    assert(client, "socket client can't be nil")

    local length, length_err = parse_content_length(client)
    if length_err ~= nil then
        return nil, length_err
    end

    local state = dap_read_state(client)
    local payload, payload_err, partial = client:receive(length, state.payload_partial)

    if not payload then
        state.payload_partial = partial or state.payload_partial

        if payload_err == "closed" then
            dap_read_states[client] = nil
        end

        log.error("failed to read payload of length %d: %s", length, tostring(payload_err))
        return nil, payload_err
    end

    dap_read_states[client] = nil

    log.trace("read_message(%d): %s", length, payload)

    local ok, decoded = pcall(json().decode, payload)
    if not ok then
        return nil, "malformed payload"
    end

    return decoded, nil
end

---@param client moonbug.Socket
---@param message moonbug.dap.ProtocolMessage
local function send_message(client, message)
    assert(client, "socket client can't be nil")

    local json_str = json().encode(message)
    local length = #json_str
    local frame = string.format("Content-Length: %d\r\n\r\n%s", length, json_str)

    log.trace("send_message(%d): %s", length, json_str)

    local total_sent = 0
    while total_sent < #frame do
        local sent, err, partial_sent = client:send(frame, total_sent + 1)
        if not sent then
            if err == "timeout" then
                total_sent = partial_sent
            else
                log.error("socket send error: %s", tostring(err))
                return
            end
        else
            total_sent = sent
        end
    end
end

----> pathlib

---@param p string
---@return boolean
local function path_is_absolute(p)
    return str_starts_with(p, "/") or p:match "^%a+:" ~= nil
end

---@param ... string
---@return string
local function path_join(...)
    local args = { ... }
    local result = {}

    for i = 1, select("#", ...) do
        local part = args[i]
        if part and part ~= "" then
            table.insert(result, part)
        end
    end

    local res = table.concat(result, "/"):gsub("//+", "/")
    return res
end

---@param p string
---@return string
local function path_normalize(p)
    if not p or p == "" then
        return ""
    end

    p = p:gsub("^@", ""):gsub("\\", "/")

    local is_posix = str_starts_with(p, "/")
    local parts = {}

    for part in p:gmatch "[^/]+" do
        if part == ".." then
            table.remove(parts)
        elseif part ~= "." and part ~= ":" then
            table.insert(parts, part)
        end
    end

    local result = table.concat(parts, "/")
    if path_is_absolute(p) then
        return is_posix and ("/" .. result) or result
    end

    return result
end

local function path_resolve(target, root_dir)
    local cleaned = target:gsub("^@", "")

    if path_is_absolute(cleaned) or not root_dir or root_dir == "" then
        return path_normalize(cleaned)
    end

    return path_normalize(path_join(root_dir, cleaned))
end

----> Debugger

---@class moonbug.Config
---@field wait?           boolean Block until debugger attaches
---@field max_wait_time?  integer Maximum amount of time to wait for things to happen
---@field stop_on_entry?  boolean Stop the process when debugger configuration is done
---@field stop_on_attach? boolean Stop the process when debugger attaches
---@field eval_timeout?   number  Seconds before `evaluate` is aborted (default: 5)
---@field forward_output? boolean Forward print() to the debug console while attached (default: true)

---@alias moonbug.VariableKind "locals"|"globals"|"upvalues"|"table"

---@class moonbug.Breakpoint
---@field condition?     string  The breakpoint condition
---@field hit_condition? string  Hit breakpoint condition
---@field hit_count?     integer Hit counter for hit_condition
---@field log_message?   string  A log message that will be printed instead of stopping

---@class moonbug.ThreadContext
---@field id          integer
---@field name        string
---@field base_depth? integer
---@field stack_level integer
---@field frames      table<integer, integer>
---@field locations   table<integer, moonbug.SourceLocation>
---@field exception?  { message: string, caught: boolean }

---@class moonbug.MainThread

---@alias moonbug.ThreadHandle moonbug.MainThread|thread

---@class moonbug.SourceLocation
---@field source string
---@field line   integer

---@class moonbug.ResumeLocation : moonbug.SourceLocation
---@field handle moonbug.ThreadHandle
---@field level  integer
---@field left   boolean

---@class moonbug.Session
---@field client?           moonbug.Socket
---@field server?           moonbug.Socket
---@field seq               integer
---@field ready             boolean True after `configurationDone`
---@field paused            boolean
---@field context           table<moonbug.ThreadHandle, moonbug.ThreadContext>
---@field step?             "in"|"over"|"out"|"pause"|"entry"
---@field step_level        integer
---@field step_thread?      moonbug.ThreadHandle
---@field resume_location?  moonbug.ResumeLocation
---@field breakpoints       table<string, table<integer, moonbug.Breakpoint>>
---@field filters           { error: boolean, pcall: boolean, uncaught: boolean }
---@field client_args?      moonbug.dap.InitializeRequestArguments
---@field config?           moonbug.Config
---@field project_root_dir? string
---@field variables         { next_id: integer, refs: table<integer, { kind: moonbug.VariableKind, data: table }> }
---@field next_frame_id     integer
---@field restart_requested boolean
---@field sources           table<string, true>
---@field module_ids        table<string, integer>
---@field next_module_id    integer
local session = {
    seq = 0,
    ready = false,
    paused = false,
    step_level = 0,
    breakpoints = {},
    filters = {
        error = true,
        pcall = false,
        uncaught = true,
    },
    variables = {
        next_id = 1,
        refs = {},
    },
    restart_requested = false,
    sources = {},
    module_ids = {},
    next_module_id = 1,
}

---@type moonbug.MainThread
local main_thread = {}
local main_thread_id = 1
local next_thread_id = 2

local started_once = false

---@type string?
local start_host = nil

---@type integer?
local start_port = nil

---@type moonbug.Config?
local start_opts = nil

---@param with_restart? boolean
local function session_reset(with_restart)
    log.debug "resetting session..."

    session.seq = 0
    session.ready = false
    session.paused = false
    session.step = nil
    session.step_level = 0
    session.step_thread = nil
    session.resume_location = nil
    session.breakpoints = {}
    session.filters = { error = true, pcall = false, uncaught = true }
    session.variables = { next_id = 1, refs = {} }
    session.client_args = nil
    session.config = nil
    session.project_root_dir = nil
    session.next_frame_id = 1
    session.restart_requested = false
    session.sources = {}
    session.module_ids = {}
    session.next_module_id = 1

    next_thread_id = 2

    session.context = setmetatable({
        [main_thread] = {
            id = main_thread_id,
            name = "main",
            base_depth = 0,
            stack_level = 0,
            frames = {},
            locations = {},
        },
    }, { __mode = "k" })

    if session.client and session.client.close then
        pcall(session.client.close, session.client)
    end

    session.client = nil

    if session.server and session.server.close then
        pcall(session.server.close, session.server)
    end

    session.server = nil

    if with_restart then
        log.debug "restarting session..."

        local opts = start_opts or {}
        opts.wait = false -- dont wait on reconnect

        M.listen(start_host, start_port, opts)
    end
end

---@return moonbug.ThreadHandle
local function current_handle()
    local co, is_main = coroutine.running()
    if is_main or co == nil then
        return main_thread
    end

    return co
end

---@param handle? moonbug.ThreadHandle
---@return moonbug.ThreadContext
local function get_context(handle)
    handle = handle or current_handle()

    local ctx = session.context[handle]

    if not ctx then
        ctx = {
            id = next_thread_id,
            name = string.format("coroutine #%d", next_thread_id - 1),
            base_depth = nil,
            stack_level = 0,
            frames = {},
            locations = {},
        }

        next_thread_id = next_thread_id + 1
        session.context[handle] = ctx
    end

    return ctx
end

---Remember the source location a command resumes from
---@param handle moonbug.ThreadHandle
---@param level  integer
---@param left   boolean
local function set_resume_location(handle, level, left)
    session.resume_location = nil

    -- NOTE(luajit): this is only needed for luajit duplicate return site line events
    if not is_luajit then
        return
    end

    local location = get_context(handle).locations[level]
    if not location then
        return
    end

    session.resume_location = {
        handle = handle,
        level = level,
        source = location.source,
        line = location.line,
        left = left,
    }
end

local function purge_dead_threads()
    local dead = {}

    for handle in pairs(session.context) do
        if
            handle ~= main_thread
            ---@cast handle thread
            and coroutine.status(handle) == "dead"
        then
            table.insert(dead, handle)
        end
    end

    for _, handle in ipairs(dead) do
        session.context[handle] = nil
    end
end

---@param thread_id number
---@return moonbug.ThreadHandle?
local function get_thread_handle_from_id(thread_id)
    if thread_id == main_thread_id then
        return main_thread
    end

    for handle, ctx in pairs(session.context) do
        if ctx.id == thread_id then
            return handle
        end
    end

    return nil
end

---@param frame_id integer
---@return moonbug.ThreadHandle? handle
---@return integer?              depth
local function find_frame(frame_id)
    for handle, ctx in pairs(session.context) do
        local depth = ctx.frames[frame_id]

        if depth then
            return handle, depth
        end
    end

    return nil, nil
end

---Resolves the `ordinal`-th user frame of handle
---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param kind    "info"|"local"
---@param format? string  for kind == "info"
---@param index?  integer for kind == "local"
---@return boolean ok
---@return ...     debuginfo? or name?, value?
local function frame_access(handle, ordinal, kind, format, index)
    local is_foreign_handle = handle ~= current_handle()
    local level = is_foreign_handle and 1 or 2
    local seen = 0

    while true do
        local info
        if is_foreign_handle then
            ---@cast handle thread
            info = debug.getinfo(handle, level, "S")
        else
            info = debug.getinfo(level, "S")
        end

        if not info then
            return false
        end

        if is_user_frame(info) then
            seen = seen + 1

            if seen == ordinal then
                if kind == "local" then
                    assert(index ~= nil, "index must be set for kind == 'local'")

                    if is_foreign_handle then
                        ---@cast handle thread
                        return true, debug.getlocal(handle, level, index)
                    end

                    return true, debug.getlocal(level, index)
                end

                assert(format ~= nil, "format must be set for kind == 'info'")

                if is_foreign_handle then
                    ---@cast handle thread
                    return true, debug.getinfo(handle, level, format)
                end

                return true, debug.getinfo(level, format)
            end
        end

        level = level + 1
    end
end

---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param format  string
---@return debuginfo?
local function frame_getinfo(handle, ordinal, format)
    local ok, info = frame_access(handle, ordinal, "info", format)
    return ok and info or nil
end

---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param index   integer
---@return string?
---@return any?
local function frame_getlocal(handle, ordinal, index)
    local ok, name, value = frame_access(handle, ordinal, "local", nil, index)
    if not ok then
        return nil
    end
    return name, value
end

---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param index   integer
---@param value   string
---@return boolean ok
local function frame_setlocal(handle, ordinal, index, value)
    local is_foreign_handle = handle ~= current_handle()
    local level = is_foreign_handle and 1 or 2
    local seen = 0

    while true do
        local info = is_foreign_handle
                ---@cast handle thread
                and debug.getinfo(handle, level, "S")
            or debug.getinfo(level, "S")

        if not info then
            return false
        end

        if is_user_frame(info) then
            seen = seen + 1
            if seen == ordinal then
                if is_foreign_handle then
                    ---@cast handle thread
                    return debug.setlocal(handle, level, index, value) ~= nil
                end

                return debug.setlocal(level, index, value) ~= nil
            end
        end

        level = level + 1
    end
end

---@param value integer?
---@param field "line"|"column"
---@return integer?
local function position_from_client(value, field)
    if not value then
        return nil
    end

    assert(field == "column" or field == "line")

    if not session.client_args then
        return value
    end

    local startsAt1 = field == "line" and session.client_args.linesStartAt1 or session.client_args.columnsStartAt1

    if startsAt1 == false then
        return value + 1
    end

    return value
end

---@param value integer?
---@param field "line"|"column"
---@return integer?
local function position_to_client(value, field)
    if not value then
        return nil
    end

    assert(field == "column" or field == "line")

    if not session.client_args then
        return value
    end

    local startsAt1 = field == "line" and session.client_args.linesStartAt1 or session.client_args.columnsStartAt1

    if startsAt1 == false then
        return value - 1
    end

    return value
end

---@param object moonbug.dap.ProtocolMessage
local function session_send_seq(object)
    session.seq = session.seq + 1
    object.seq = session.seq
    send_message(session.client, object)
end

---@param event moonbug.DapEvent
---@param body? any
local function session_send_event(event, body)
    session_send_seq {
        seq = -1, -- will be filled out by send_seq
        type = "event",
        event = event,
        body = body or {},
    }
end

---Send a dap output event
---@param category "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@param output   string
---@param source?  moonbug.dap.Source
---@param line?    integer
---@param column?  integer
---@return boolean
local function session_send_output(category, output, source, line, column)
    if not session.ready or not session.client then
        return false
    end

    session_send_event("output", {
        category = category,
        output = output,
        source = source,
        line = position_to_client(line, "line"),
        column = position_to_client(column, "column"),
    })
    return true
end

---@param req      moonbug.dap.Request
---@param ok       boolean
---@param body?    moonbug.dap.ResponseBody
---@param message? "cancelled"|"notStopped"|string
local function session_send_response(req, ok, body, message)
    session_send_seq {
        seq = -1, -- will be filled out by send_seq
        type = "response",
        request_seq = req.seq,
        success = ok,
        command = req.command,
        body = body,
        message = message,
    }
end

---Sends an error message back to the client
---@param req     moonbug.dap.Request
---@param message string
local function session_send_error(req, message)
    log.error(message)

    ---@type moonbug.dap.ErrorResponseBody
    local body = { error = { id = 1, format = message } }

    session_send_response(req, false, body, message)
end

---@param req moonbug.dap.Request
---@return boolean
local function session_requires_pause(req)
    if session.paused and session.ready then
        return true
    end

    session_send_response(req, false, nil, "notStopped")

    return false
end

---@param handle moonbug.ThreadHandle
---@param depth  integer
---@return integer
local function count_locals(handle, depth)
    local n = 0
    local i = 1

    while true do
        local name = frame_getlocal(handle, depth, i)
        if not name then
            break
        end

        if not is_pseudo_variable(name) then
            n = n + 1
        end

        i = i + 1
    end

    return n
end

---@param fn function
---@return integer
local function count_upvalues(fn)
    local n = 0
    local i = 1

    while true do
        local name = debug.getupvalue(fn, i)
        if not name then
            break
        end

        if not hidden_keys[name] then
            n = n + 1
        end

        i = i + 1
    end

    return n
end

---Format values for the client
---@param v any
---@param format? moonbug.dap.ValueFormat
---@return string
local function format_client_value(v, format)
    local t = type(v)

    if format and format.hex and t == "number" then
        local specifier = v % 1 == 0 and "0x%x" or "%a"
        local ok, formatted = pcall(string.format, specifier, v)
        if ok then
            return formatted
        end
        if specifier ~= "%a" then
            ok, formatted = pcall(string.format, "%a", v)
            if ok then
                return formatted
            end
        end
    end

    if t == "string" then
        return string.format("%q", v)
    end

    return safe_tostring(v)
end

---@return string[]
local function global_keys()
    local keys = {}

    for k in pairs(_G) do
        if not hidden_keys[k] then
            table.insert(keys, k)
        end
    end

    table.sort(keys, function(a, b)
        return safe_tostring(a) < safe_tostring(b)
    end)

    return keys
end

---@param kind moonbug.VariableKind
---@param data table
---@return integer
local function variable_ref(kind, data)
    local id = session.variables.next_id
    session.variables.next_id = id + 1
    session.variables.refs[id] = { kind = kind, data = data }
    return id
end

---@class moonbug.VariableConfig
---@field context?       "table"|"locals"|"upvalues"|"globals"|"eval"
---@field evaluate_name? string
---@field format?        moonbug.dap.ValueFormat

---@param v     any
---@param name  string
---@param opts? moonbug.VariableConfig
---@return moonbug.dap.VariablePresentationHint?
local function variable_presentation_hint(v, name, opts)
    opts = opts or {}

    local t = type(v)

    ---@type moonbug.dap.VariablePresentationHint
    local res = { attributes = {} }

    if str_starts_with(name, "_") and name ~= "_G" and name ~= "_ENV" and opts.context ~= "eval" then
        res.visibility = "private"
    end

    local is_virtual = opts.context == "upvalues" or (name:match "^%[" and not name:match "^%[%d+%]$")

    if is_virtual then
        res.kind = "virtual"
        table.insert(res.attributes, "readOnly")
    elseif t == "function" then
        res.kind = "method"
        table.insert(res.attributes, "readOnly")
    elseif t == "thread" then
        table.insert(res.attributes, "readOnly")
    elseif t == "userdata" then
        table.insert(res.attributes, "readOnly")
    elseif opts.context == "table" and not name:match "^%[%d+%]$" then
        res.kind = "property"
    else
        res.kind = "data"
    end

    if name == "_VERSION" then
        table.insert(res.attributes, "readOnly")
    end

    if #res.attributes == 0 then
        res.attributes = nil
    end

    return res
end

---Serializes a Lua value into a DAP value
---@param v     any
---@param name  string
---@param opts? moonbug.VariableConfig
---@return moonbug.dap.Variable
local function serialize_value(v, name, opts)
    local variable = {
        name = name,
        type = type(v),
        value = format_client_value(v, opts and opts.format),
        variablesReference = 0,
        presentationHint = variable_presentation_hint(v, name, opts),
        evaluateName = opts and opts.evaluate_name,
    }

    if type(v) == "table" then
        local length = table_array_length(v)

        variable.variablesReference = variable_ref("table", { tbl = v, evaluate_name = opts and opts.evaluate_name })
        variable.indexedVariables = length
        variable.namedVariables = table_named_count(v, length)
    end

    return variable
end

---@return moonbug.dap.Variable[]
local function global_variables(format)
    local keys = global_keys()
    local vars = {}

    for _, k in ipairs(keys) do
        table.insert(
            vars,
            serialize_value(_G[k], tostring(k), {
                context = "globals",
                evaluate_name = global_evaluate_name(k),
                format = format,
            })
        )
    end

    return vars
end

---@param tbl            table
---@param filter?        "indexed"|"named"
---@param start_index?   integer
---@param count?         integer
---@param evaluate_name? string
---@param format?        moonbug.dap.ValueFormat
---@return moonbug.dap.Variable[]
local function table_variables(tbl, filter, start_index, count, evaluate_name, format)
    local length = table_array_length(tbl)
    start_index = start_index or 0

    local vars = {}

    if filter == "indexed" then
        local total = length
        local hi = (count and count ~= 0) and math.min(start_index + count, total) or math.min(total, table_max_items)

        for i = start_index + 1, hi do
            local v = rawget(tbl, i)
            table.insert(
                vars,
                serialize_value(v, string.format("[%d]", i), {
                    context = "table",
                    evaluate_name = table_evaluate_name(evaluate_name, i),
                    format = format,
                })
            )
        end

        return vars
    end

    local keys = table_named_keys(tbl, length)

    if filter == "named" then
        local total = #keys
        local hi = (count and count ~= 0) and math.min(start_index + count, total) or math.min(total, table_max_items)

        for i = start_index + 1, hi do
            local key = keys[i]
            local v = rawget(tbl, key)
            table.insert(
                vars,
                serialize_value(v, tostring(key), {
                    context = "table",
                    evaluate_name = table_evaluate_name(evaluate_name, key),
                    format = format,
                })
            )
        end

        return vars
    end

    -- no filter means both partitions
    local total = length + #keys
    local hi = (count and count ~= 0) and math.min(start_index + count, total) or math.min(total, table_max_items)
    for i = start_index + 1, hi do
        if i <= length then
            local v = rawget(tbl, i)
            table.insert(
                vars,
                serialize_value(v, string.format("[%d]", i), {
                    context = "table",
                    evaluate_name = table_evaluate_name(evaluate_name, i),
                    format = format,
                })
            )
        else
            local k = keys[i - length]
            local v = rawget(tbl, k)
            table.insert(
                vars,
                serialize_value(v, tostring(k), {
                    context = "table",
                    evaluate_name = table_evaluate_name(evaluate_name, k),
                    format = format,
                })
            )
        end
    end

    return vars
end

---Get the currently set eval timeout
---@return number
local function eval_timeout()
    return (session.config and session.config.eval_timeout) or eval_default_timeout
end

---@param body    function
---@param timeout number
---@return table?  result
---@return string? error
local function run_with_timeout(body, timeout)
    local deadline = socket().gettime() + timeout
    local timeout_marker = {}

    local check_timeout = function()
        if socket().gettime() > deadline then
            log.error("evaluation timed out after %ss", timeout)
            error(timeout_marker, 0)
        end
    end

    local hook, mask, count = debug.gethook()
    debug.sethook(check_timeout, "", eval_count_budget)

    local results = table_pack(pcall(body))

    if hook then
        if count and count > 0 then
            debug.sethook(hook, mask, count)
        else
            debug.sethook(hook, mask)
        end
    else
        debug.sethook()
    end

    if not results[1] and results[2] == timeout_marker then
        return nil, "timeout"
    end

    return results, nil
end

---@param ordinal? integer nil evaluates in the global scope
---@param src      string
---@param timeout? number
---@param context? "repl"|"watch"|"hover"|"clipboard"|"variables"
---@return boolean                    ok
---@return table<integer, any>|string error message when ok = false
---@return integer                    count
local function evaluate_expr(ordinal, src, timeout, context)
    context = context or "repl"

    ---@type integer?
    local level = nil
    ---@type function?
    local func = nil

    if ordinal then
        level = 2 -- 1 = this function
        local seen = 0

        while true do
            local info = debug.getinfo(level, "S")
            if not info then
                return false, "stack frame is no longer valid", 0
            end

            if is_user_frame(info) then
                seen = seen + 1

                if seen == ordinal then
                    break
                end
            end

            level = level + 1
        end

        func = debug.getinfo(level, "f").func
    end

    -- only repl context allows mutations
    local is_mutable = context == "repl"

    ---@type function|nil
    local fn

    ---@type string|nil
    local err

    fn, err = loadstring(string.format("return %s", src), "=(moonbug eval)")

    if not fn and is_mutable then
        fn, err = loadstring(src, "=(moonbug eval)")
    end

    if not fn then
        return false, err or "syntax error", 0
    end

    -- Create a snapshot of the frames locals/upvalues, or an empty global scope.
    local env = {}
    local varargs = {}

    if level and func then
        local i = 1

        while true do
            local name, value = debug.getupvalue(func, i)
            if not name then
                break
            end

            if not is_pseudo_variable(name) then
                env[name] = value
            end

            i = i + 1
        end

        i = 1

        while true do
            local name, value = debug.getlocal(level, i)
            if not name then
                break
            end

            if not is_pseudo_variable(name) then
                env[name] = value
            end

            i = i + 1
        end

        i = 1

        while true do
            local name, value = debug.getlocal(level, -i)
            if not name then
                break
            end

            varargs[i] = value

            i = i + 1
        end
    end

    if is_mutable then
        setmetatable(env, { __index = _G, __newindex = _G })
    else
        setmetatable(env, {
            __index = _G,
            __newindex = function(_, key)
                local err_message = string.format("cannot assign to '%s' in a read-only context", tostring(key))
                log.error(err_message)
                error(err_message, 2)
            end,
        })
    end

    setfenv(fn, env)

    timeout = timeout or eval_timeout()

    local results, timeout_err = run_with_timeout(function()
        return fn(table_unpack(varargs))
    end, timeout)

    if not results then
        return false, timeout_err or "timeout", 0
    end

    -- write back results if mutable
    if is_mutable and level and func then
        local n = 0
        while debug.getlocal(level, n + 1) do
            n = n + 1
        end

        local done = {}

        for j = n, 1, -1 do
            local nm = debug.getlocal(level, j)
            if nm and not is_pseudo_variable(nm) and not done[nm] then
                done[nm] = true
                debug.setlocal(level, j, env[nm])
            end
        end

        local j = 1

        while true do
            local nm = debug.getupvalue(func, j)
            if not nm then
                break
            end

            if not is_pseudo_variable(nm) and not done[nm] then
                done[nm] = true
                debug.setupvalue(func, j, env[nm])
            end

            j = j + 1
        end
    end

    if not results[1] then
        return false, tostring(results[2]), 0
    end

    local count = results.n - 1
    local values = {}

    for k = 2, results.n do
        values[k - 1] = results[k]
    end

    if count == 0 then
        values = { nil }
        count = 1
    end

    return true, values, count
end

---@param v       table<integer, any>
---@param count   integer
---@param format? moonbug.dap.ValueFormat
---@return moonbug.dap.EvaluateResponseBody
local function serialize_eval_result(v, count, format)
    if count ~= 1 then
        local parts = {}

        for i = 1, count do
            parts[i] = format_client_value(v[i], format)
        end

        return {
            result = table.concat(parts, "\t"),
            variablesReference = 0,
        }
    end

    local s = serialize_value(v[1], "result", {
        context = "eval",
        format = format,
    })

    return {
        result = s.value,
        type = s.type,
        variablesReference = s.variablesReference,
        indexedVariables = s.indexedVariables,
        namedVariables = s.namedVariables,
    }
end

---Split repl input into base (lhs of '.'/':'), prefix, separator
---@param text   string
---@param column integer
---@return string? base
---@return string  prefix
---@return string  separator
---@return integer prefix_start
local function split_completion_input(text, column)
    local before = text:sub(1, column)

    local word_start = #before
    while word_start > 0 do
        if before:sub(word_start, word_start):match "[%w_]" then
            word_start = word_start - 1
        else
            break
        end
    end

    local prefix = before:sub(word_start + 1)
    local separator = before:sub(word_start, word_start)

    local base = nil
    if separator == "." or separator == ":" then
        base = before:sub(1, word_start - 1)
    end

    return base, prefix, separator, word_start
end

---Completion candidates for an identifier prefix
---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param prefix  string
---@return moonbug.dap.CompletionItem[]
local function complete_identifiers(handle, ordinal, prefix)
    local targets = {}
    local seen = {}

    ---@param name string
    local add = function(name)
        if
            name
            and not seen[name]
            and not is_pseudo_variable(name)
            and not hidden_keys[name]
            and str_starts_with(name, prefix)
        then
            seen[name] = true
            table.insert(targets, {
                label = name,
                text = name,
                type = "variable",
            })
        end
    end

    local i = 1
    while true do
        local name = frame_getlocal(handle, ordinal, i)
        if not name then
            break
        end

        add(name)

        i = i + 1
    end

    local info = frame_getinfo(handle, ordinal, "f")
    if info and info.func then
        local j = 1

        while true do
            local name = debug.getupvalue(info.func, j)
            if not name then
                break
            end

            add(name)

            j = j + 1
        end
    end

    for _, k in ipairs(global_keys()) do
        add(k)
    end

    table.sort(targets, function(a, b)
        return a.label < b.label
    end)

    return targets
end

---Completion candidates for table members (after '.' / ':')
---@param tbl       table
---@param prefix    string
---@param separator "."|":"
---@return moonbug.dap.CompletionItem[]
local function complete_fields(tbl, prefix, separator)
    ---@type moonbug.dap.CompletionItem[]
    local items = {}

    local seen = {}
    local seen_tables = {}
    local only_callables = separator == ":"

    -- gather own keys plus keys reachable via the __index metatable
    local current = tbl
    while current ~= nil and not seen_tables[current] do
        seen_tables[current] = true

        local k = next(current)
        while k ~= nil do
            if type(k) == "string" and not seen[k] then
                seen[k] = true
            end

            k = next(current, k)
        end

        local mt = getmetatable(current)
        if type(mt) ~= "table" then
            break
        end

        current = mt.__index

        if type(current) ~= "table" then
            break
        end
    end

    for name in pairs(seen) do
        if
            -- hide internals
            not str_starts_with(name, "__")
            -- name starts with prefix
            and str_starts_with(name, prefix)
        then
            local value = tbl[name]

            if not only_callables or type(value) == "function" then
                local item_type = "field"

                if type(value) == "function" then
                    item_type = "function"
                elseif type(value) == "table" then
                    item_type = "module"
                end

                table.insert(items, {
                    label = name,
                    text = name,
                    type = item_type,
                })
            end
        end
    end

    table.sort(items, function(a, b)
        return a.label < b.label
    end)

    return items
end

---Attempt to determine the module path of a module value
---@param module_value any
---@return string?
local function determine_module_path(module_value)
    ---@param fn function
    ---@return string?
    local function from_function(fn)
        local info = debug.getinfo(fn, "S")
        if info and info.source and str_starts_with(info.source, "@") then
            local path = path_resolve(info.source, session.project_root_dir)
            if path ~= "" then
                return path
            end
        end

        return nil
    end

    if type(module_value) == "function" then
        return from_function(module_value)
    elseif type(module_value) == "table" then
        for _, sub in pairs(module_value) do
            if type(sub) == "function" then
                local path = from_function(sub)
                if path then
                    return path
                end
            end
        end
    end

    return nil
end

---Registers a loaded Lua module and returns its DAP representation.
---@param name string
---@return moonbug.dap.Module
local function register_module(name)
    local existing = session.module_ids[name]
    local value = package.loaded[name]

    ---@type moonbug.dap.Module
    local row = {
        id = existing or session.next_module_id,
        name = name,
        kind = type(value),
        path = determine_module_path(value),
    }

    if not existing then
        session.module_ids[name] = row.id
        session.next_module_id = session.next_module_id + 1

        if session.ready and session.client then
            session_send_event(dap_events.module, {
                reason = "new",
                module = row,
            })
        end
    end

    return row
end

---Formats the current call stack as text
---@return string
local function capture_stacktrace()
    local parts = { "stack traceback:" }
    local depth = 1

    while true do
        local info = debug.getinfo(depth, "Snl")
        if not info then
            break
        end

        if is_user_frame(info) then
            local label = info.what == "main" and "main chunk"
                or string.format("function '%s'", info.name or "(anonymous)")
            table.insert(parts, string.format("\t%s:%d: in %s", info.short_src, info.currentline, label))
        end

        depth = depth + 1
    end

    return table.concat(parts, "\n")
end

local RequestHandler = {}

---@param req moonbug.dap.InitializeRequest
function RequestHandler.handle_initialize(req)
    local args = req.arguments or {}
    session.client_args = args

    log.info("client initialized request: %s", readable_tostring(args))

    session_send_response(req, true, server_capabilities)
    session_send_event(dap_events.initialized)
end

---@param req moonbug.dap.ConfigurationDoneRequest
function RequestHandler.handle_configuration_done(req)
    session_send_response(req, true)

    for name in pairs(package.loaded) do
        if type(name) == "string" then
            register_module(name)
        end
    end

    if session.config and session.config.stop_on_entry then
        session.step = "entry"
    end
end

---@param req moonbug.dap.SetBreakpointsRequest
function RequestHandler.handle_set_breakpoints(req)
    local args = req.arguments or {}
    local path = path_resolve(args.source and args.source.path, session.project_root_dir)

    if path ~= "" then
        session.sources[path] = true
    end

    ---@type moonbug.dap.Breakpoint[]
    local list = {}

    session.breakpoints[path] = {}

    for _, bp in ipairs(args.breakpoints or {}) do
        local line = position_from_client(bp.line, "line")
        local ok = path ~= "" and line ~= nil

        if ok then
            local condition = ""

            if bp.condition then
                condition = condition .. " cond: " .. bp.condition
            end

            if bp.hitCondition then
                condition = condition .. " hit_cond: " .. bp.hitCondition
            end

            log.debug("    set breakpoint: %s:%d%s", path, line, condition)

            ---@cast line integer
            session.breakpoints[path][line] = {
                condition = bp.condition,
                hit_condition = bp.hitCondition,
                log_message = bp.logMessage,
                hit_count = 0,
            }
        end

        table.insert(list, { line = position_to_client(line, "line"), verified = ok })
    end

    ---@type moonbug.dap.SetBreakpointsResponseBody
    local body = { breakpoints = list }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.SetExceptionBreakpointsRequest
function RequestHandler.handle_set_exception_breakpoints(req)
    local on = {}
    for _, f in ipairs(req.arguments.filters or {}) do
        on[f] = true
    end

    session.filters.error = on.error or false
    session.filters.pcall = on.pcall or false
    session.filters.uncaught = on.uncaught or false

    session_send_response(req, true)
end

---@param req moonbug.dap.ThreadsRequest
function RequestHandler.handle_threads(req)
    purge_dead_threads()

    ---@type moonbug.dap.Thread[]
    local threads = {}

    for h, c in pairs(session.context) do
        if
            h == main_thread
            ---@cast h thread if its not main_thread its guaranteed to be thread
            or coroutine.status(h) ~= "dead"
        then
            table.insert(threads, {
                id = c.id,
                name = c.name,
            })
        end
    end

    table.sort(threads, function(a, b)
        return a.id < b.id
    end)

    ---@type moonbug.dap.ThreadsResponseBody
    local body = { threads = threads }

    session_send_response(req, true, body)
end

---@param name     string?
---@param value    any
---@param index    integer
---@param format   moonbug.dap.StackFrameFormat
---@param defaults boolean
---@return string?
local function format_stack_parameter(name, value, index, format, defaults)
    local rendered = nil

    if format.parameterNames == true or defaults then
        rendered = name or string.format("arg%d", index)
    end

    if format.parameterTypes then
        local kind = type(value)

        rendered = rendered and (rendered .. ": " .. kind) or kind
    end

    if format.parameterValues == true or defaults then
        local formatted = format_client_value(value, format)

        rendered = rendered and (rendered .. " = " .. formatted) or formatted
    end

    return rendered
end

---@param handle  moonbug.ThreadHandle
---@param ordinal integer
---@param info    debuginfo
---@param format  moonbug.dap.StackFrameFormat
---@return string[]?
local function stack_frame_parameters(handle, ordinal, info, format)
    if ordinal == 0 or format.parameters == false then
        return nil
    end

    local has_details = format.parameterNames ~= nil or format.parameterTypes ~= nil or format.parameterValues ~= nil
    local defaults = format.parameters == true and not has_details

    if not (format.parameters or format.parameterNames or format.parameterTypes or format.parameterValues) then
        return nil
    end

    local parameters = {}
    local count = info.nparams or 0

    for index = 1, count do
        local name, value = frame_getlocal(handle, ordinal, index)
        if name then
            local formatted = format_stack_parameter(name, value, index, format, defaults)
            if formatted then
                parameters[#parameters + 1] = formatted
            end
        end
    end

    return parameters
end

---@param req moonbug.dap.StackTraceRequest
function RequestHandler.handle_stack_trace(req)
    local args = req.arguments or {}
    local target = get_thread_handle_from_id(args.threadId or main_thread_id)
    local format = args.format or {}

    if not target then
        session_send_error(req, "invalid threadId")
        return
    end

    ---@type moonbug.dap.StackFrame[]
    local frames = {}
    local target_ctx = get_context(target)

    ---@param info debuginfo
    ---@param frame_depth integer
    local function push_frame(info, frame_depth)
        local parameters = stack_frame_parameters(target, frame_depth, info, format)
        local name = info.name or (info.what == "C" and "[C]" or "(anonymous)")

        if parameters then
            name = name .. "(" .. table.concat(parameters, ", ") .. ")"
        end

        if format.module then
            name = string.format("%s.%s", info.short_src:match "[^/\\]+$" or info.short_src, name)
        end

        if format.line and info.currentline and info.currentline > 0 then
            name = string.format("%s:%d", name, info.currentline)
        end

        local line = info.currentline or 0
        local path = info.source
                and info.source:sub(1, 1) == "@"
                and path_resolve(info.source, session.project_root_dir)
            or ""

        if path ~= "" then
            session.sources[path] = true
        end

        local frame = {
            id = session.next_frame_id,
            name = name,
            line = position_to_client(line, "line"),
            column = position_to_client(1, "column"),
        }

        if path ~= "" then
            frame.source = {
                path = path,
                name = (info.short_src or ""):match "[^/\\]+$" or info.short_src,
            }
        end

        table.insert(frames, frame)

        target_ctx.frames[session.next_frame_id] = frame_depth
        session.next_frame_id = session.next_frame_id + 1
    end

    if target == main_thread and target ~= current_handle() then
        -- main requested while stopped inside coroutine: impossible!
        table.insert(frames, {
            id = session.next_frame_id,
            name = "unable to access main thread while in a coroutine",
            line = position_to_client(1, "line"),
            column = position_to_client(1, "column"),
        })

        session.next_frame_id = session.next_frame_id + 1
    else
        -- walk user frames of the thread (current or suspended)
        local is_foreign_handle = target ~= current_handle()
        local depth = is_foreign_handle and 1 or 2
        local ordinal = 0
        local include_all = format.includeAll == true

        while true do
            local info = nil

            if is_foreign_handle then
                ---@cast target thread
                info = debug.getinfo(target, depth, "Snlu")
            else
                info = debug.getinfo(depth, "Snlu")
            end

            if not info then
                break
            end

            local frame_depth = 0

            if is_user_frame(info) then
                ordinal = ordinal + 1
                frame_depth = ordinal
            end

            if frame_depth > 0 or include_all then
                push_frame(info, frame_depth)
            end

            depth = depth + 1
        end
    end

    ---@type moonbug.dap.StackTraceResponseBody
    local body = {
        stackFrames = frames,
        totalFrames = #frames,
    }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.ContinueRequest
function RequestHandler.handle_continue(req)
    if not session_requires_pause(req) then
        return
    end

    local curr_handle = current_handle()
    local curr_ctx = get_context(curr_handle)

    curr_ctx.frames = {}
    session.variables.refs = {}
    session.paused = false
    session.step = nil
    curr_ctx.exception = nil

    set_resume_location(curr_handle, curr_ctx.stack_level, false)

    ---@type moonbug.dap.ContinueResponseBody
    local body = { allThreadsContinued = true }

    session_send_response(req, true, body)
    session_send_event(dap_events.continued, { threadId = curr_ctx.id, allThreadsContinued = true })
end

---@param req moonbug.dap.PauseRequest
function RequestHandler.handle_pause(req)
    session.step = "pause"

    session_send_response(req, true)
end

---@param req moonbug.dap.NextRequest
function RequestHandler.handle_next(req)
    if not session_requires_pause(req) then
        return
    end

    local curr_handle = current_handle()
    local curr_ctx = get_context(curr_handle)

    session.step = "over"
    session.step_level = curr_ctx.stack_level
    session.step_thread = curr_handle
    session.paused = false
    curr_ctx.exception = nil

    set_resume_location(curr_handle, session.step_level, false)

    session_send_response(req, true)
end

---@param req moonbug.dap.StepInRequest
function RequestHandler.handle_step_in(req)
    if not session_requires_pause(req) then
        return
    end

    local curr_handle = current_handle()
    local curr_ctx = get_context(curr_handle)
    session.step = "in"
    session.paused = false
    curr_ctx.exception = nil

    set_resume_location(curr_handle, curr_ctx.stack_level, false)

    session_send_response(req, true)
end

---@param req moonbug.dap.StepOutRequest
function RequestHandler.handle_step_out(req)
    if not session_requires_pause(req) then
        return
    end

    local curr_handle = current_handle()
    local curr_ctx = get_context(curr_handle)

    session.step = "out"
    session.step_level = curr_ctx.stack_level - 1
    session.step_thread = curr_handle
    session.paused = false
    curr_ctx.exception = nil

    set_resume_location(curr_handle, session.step_level, true)

    session_send_response(req, true)
end

---@param req moonbug.dap.ScopesRequest
function RequestHandler.handle_scopes(req)
    if not session_requires_pause(req) then
        return
    end

    local frame_handle, depth = find_frame(req.arguments.frameId)

    if not frame_handle or not depth then
        session_send_error(req, "invalid frameId")
        return
    end

    ---@type moonbug.dap.Scope[]
    local scopes = {
        {
            name = "Local",
            variablesReference = variable_ref("locals", { handle = frame_handle, depth = depth }),
            presentationHint = "locals",
            namedVariables = count_locals(frame_handle, depth),
            expensive = false,
        },
    }

    local info = frame_getinfo(frame_handle, depth, "Sf")

    if info and info.what == "Lua" then
        table.insert(scopes, {
            name = "Upvalue",
            variablesReference = variable_ref("upvalues", { func = info.func }),
            namedVariables = count_upvalues(info.func),
            expensive = false,
        })
    end

    table.insert(scopes, {
        name = "Global",
        variablesReference = variable_ref("globals", {}),
        namedVariables = #global_keys(),
        expensive = false,
    })

    ---@type moonbug.dap.ScopesResponseBody
    local body = { scopes = scopes }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.VariablesRequest
function RequestHandler.handle_variables(req)
    if not session_requires_pause(req) then
        return
    end

    local args = req.arguments or {}
    local supports_paging = session.client_args and session.client_args.supportsVariablePaging == true
    local ref = session.variables.refs[args.variablesReference]

    if not ref then
        session_send_error(req, "invalid variablesReference")
        return
    end

    local variables = {}

    if ref.kind == "locals" then
        assert(ref.data.handle, "locals must have `handle` value")
        assert(ref.data.depth, "locals must have `depth` value")

        if not frame_getinfo(ref.data.handle, ref.data.depth, "S") then
            session_send_error(req, "stack frame is no longer valid")
            return
        end

        local i = 1
        local name, value = frame_getlocal(ref.data.handle, ref.data.depth, 1)

        while name do
            if not is_pseudo_variable(name) then
                table.insert(
                    variables,
                    serialize_value(value, name, {
                        context = "locals",
                        evaluate_name = name,
                        format = args.format,
                    })
                )
            end

            i = i + 1

            name, value = frame_getlocal(ref.data.handle, ref.data.depth, i)
        end
    elseif ref.kind == "upvalues" then
        assert(ref.data.func, "upvalues must have `func` value")

        local i = 1
        local name, value = debug.getupvalue(ref.data.func, i)

        while name do
            if not hidden_keys[name] then
                table.insert(
                    variables,
                    serialize_value(value, name, {
                        context = "upvalues",
                        evaluate_name = name,
                        format = args.format,
                    })
                )
            end

            i = i + 1

            name, value = debug.getupvalue(ref.data.func, i)
        end
    elseif ref.kind == "globals" then
        variables = global_variables(args.format)
    elseif ref.kind == "table" then
        assert(ref.data.tbl, "tables must have `tbl` value")

        if supports_paging then
            variables =
                table_variables(ref.data.tbl, args.filter, args.start, args.count, ref.data.evaluate_name, args.format)
        else
            variables = table_variables(ref.data.tbl, args.filter, nil, nil, ref.data.evaluate_name, args.format)
        end
    end

    if
        -- if the client supports paging just show how much they ask for
        supports_paging
        -- tables are already paged
        and ref.kind ~= "table"
    then
        variables = slice(variables, args.start, args.count)
    end

    ---@type moonbug.dap.VariablesResponseBody
    local body = { variables = variables }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.EvaluateRequest
function RequestHandler.handle_evaluate(req)
    if not session_requires_pause(req) then
        return
    end

    local args = req.arguments or {}
    local frame_handle, depth = find_frame(args.frameId)
    if not frame_handle or not depth then
        session_send_error(req, "invalid frameId")
        return
    end

    if frame_handle ~= current_handle() then
        session_send_error(req, "cannot evaluate in a suspended thread")
        return
    end

    local ok, res, count = evaluate_expr(depth, args.expression, nil, args.context)
    if not ok then
        ---@cast res string
        session_send_error(req, res or "unknown error")
        return
    end

    local timeout = eval_timeout()

    ---@cast res table<integer, any>
    local result, timeout_err = run_with_timeout(function()
        -- run inside timeout to guard from busy loading metamethods
        return serialize_eval_result(res, count, args.format)
    end, timeout)

    if not result then
        session_send_error(req, timeout_err or "timeout")
        return
    end

    if not result[1] then
        session_send_error(req, tostring(result[2]) or "failed to serialize evaluation result")
        return
    end

    ---@type moonbug.dap.EvaluateResponseBody
    local body = result[2]

    session_send_response(req, true, body)
end

---@param req moonbug.dap.SetExpressionRequest
function RequestHandler.handle_set_expression(req)
    if not session_requires_pause(req) then
        return
    end

    local args = req.arguments or {}

    if type(args.expression) ~= "string" or args.expression == "" then
        session_send_error(req, "invalid expression")
        return
    end

    if type(args.value) ~= "string" then
        session_send_error(req, "invalid value")
        return
    end

    local ordinal = nil

    if args.frameId ~= nil then
        local frame_handle, depth = find_frame(args.frameId)

        if not frame_handle or not depth then
            session_send_error(req, "invalid frameId")
            return
        end

        if frame_handle ~= current_handle() then
            session_send_error(req, "cannot evaluate in a suspended thread")
            return
        end

        ordinal = depth
    end

    -- vararg carries the assigned value w/o introducing a temp name that could shadow a var in the selected frame
    local assignment =
        string.format("return (function(...) %s = ...; return ... end)((%s))", args.expression, args.value)

    local ok, values = evaluate_expr(ordinal, assignment, nil, "repl")
    if not ok then
        ---@cast values string
        session_send_error(req, values or "failed to set expression")
        return
    end

    ---@cast values table<integer, any>
    local serialized, serialization_err = run_with_timeout(function()
        return serialize_value(values[1], args.expression, {
            context = "eval",
            format = args.format,
        })
    end, eval_timeout())

    if not serialized then
        session_send_error(req, serialization_err or "timeout")
        return
    end

    if not serialized[1] then
        session_send_error(req, tostring(serialized[2]) or "failed to serialize set expression result")
        return
    end

    local variable = serialized[2]

    ---@type moonbug.dap.SetExpressionResponseBody
    local body = {
        value = variable.value,
        presentationHint = variable.presentationHint,
        variablesReference = variable.variablesReference,
        indexedVariables = variable.indexedVariables,
        namedVariables = variable.namedVariables,
    }

    if session.client_args and session.client_args.supportsVariableType then
        body.type = variable.type
    end

    session_send_response(req, true, body)
end

---@param req moonbug.dap.CompletionsRequest
function RequestHandler.handle_completions(req)
    local args = req.arguments or {}
    local text = args.text or ""
    local column = position_from_client(args.column or 1, "column")

    ---@cast column integer
    local base, prefix, separator, prefix_start = split_completion_input(text, column)

    ---@type moonbug.dap.CompletionItem[]
    local targets = {}

    if session.paused then
        local frame_handle = nil
        local depth = nil

        if args.frameId then
            frame_handle, depth = find_frame(args.frameId)
        end

        if base then
            -- member completion, resolve the base expr and then enumerate keys
            local base_value = nil

            if depth then
                if frame_handle == current_handle() then
                    local ok, res = evaluate_expr(depth, base, nil, "watch")
                    if ok then
                        base_value = res[1]
                    end
                end
            elseif _G[base] ~= nil then
                base_value = _G[base]
            end

            if type(base_value) == "table" then
                targets = complete_fields(base_value, prefix, separator)
            end
        elseif frame_handle and depth then
            -- bare identifier: locals + upvalues + globals of the frame
            targets = complete_identifiers(frame_handle, depth, prefix)
        else
            -- no usable frame: globals only
            for _, k in ipairs(global_keys()) do
                if str_starts_with(k, prefix) then
                    table.insert(targets, {
                        label = k,
                        text = k,
                        type = "variable",
                    })
                end
            end
        end
    end

    for _, t in ipairs(targets) do
        t.start = position_to_client(prefix_start, "column")
        t.length = #prefix
    end

    ---@type moonbug.dap.CompletionsResponseBody
    local body = { targets = targets }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.LoadedSourcesRequest
function RequestHandler.handle_loaded_sources(req)
    ---@type moonbug.dap.Source[]
    local sources = {}

    for path in pairs(session.sources) do
        table.insert(sources, {
            name = path:match "[^/\\]+$" or path,
            path = path,
        })
    end

    table.sort(sources, function(a, b)
        return a.path < b.path
    end)

    ---@type moonbug.dap.LoadedSourcesResponseBody
    local body = {
        sources = sources,
    }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.ModulesRequest
function RequestHandler.handle_modules(req)
    ---@type moonbug.dap.Module[]
    local list = {}

    for name in pairs(package.loaded) do
        if type(name) == "string" then
            table.insert(list, register_module(name))
        end
    end

    table.sort(list, function(a, b)
        return a.name < b.name
    end)

    local args = req.arguments or {}
    local start_module = args.startModule or 0
    local count = args.moduleCount

    ---@type moonbug.dap.ModulesResponseBody
    local body = {
        totalModules = #list,
        modules = slice(list, start_module, count),
    }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.ExceptionInfoRequest
function RequestHandler.handle_exception_info(req)
    if not session_requires_pause(req) then
        return
    end

    if not req.arguments.threadId then
        session_send_error(req, "invalid threadId")
        return
    end

    local requested_handle = get_thread_handle_from_id(req.arguments.threadId)
    if not requested_handle then
        session_send_error(req, "invalid threadId")
        return
    end

    local exception = session.context[requested_handle].exception
    if not exception then
        session_send_error(req, "no exception information available or invalid threadId")
        return
    end

    ---@type moonbug.dap.ExceptionInfoResponseBody
    local body = {
        exceptionId = "error",
        description = exception.message,
        breakMode = exception.caught and "always" or "unhandled",
        details = {
            message = exception.message,
            stackTrace = capture_stacktrace(),
        },
    }

    session_send_response(req, true, body)
end

---@param req moonbug.dap.LaunchRequest
function RequestHandler.handle_launch(req)
    local args = req.arguments or {}

    if not session.project_root_dir then
        session.project_root_dir = args.project_root_dir or args.cwd or args["workspaceFolder"]
    end

    if not session.project_root_dir then
        session_send_error(req, "missing project root (`project_root_dir` or `cwd`)")
        return
    end

    session_send_response(req, true)
end

---@param req moonbug.dap.AttachRequest
function RequestHandler.handle_attach(req)
    local args = req.arguments or {}

    if not session.project_root_dir then
        session.project_root_dir = args.project_root_dir or args.cwd or args["workspaceFolder"]
    end

    if not session.project_root_dir then
        session_send_error(req, "missing project root (`project_root_dir` or `cwd`)")
        return
    end

    session_send_response(req, true)
end

---@param req moonbug.dap.DisconnectRequest
function RequestHandler.handle_disconnect(req)
    local args = req.arguments or {}

    local curr_handle = current_handle()
    local curr_ctx = get_context(curr_handle)

    curr_ctx.frames = {}
    session.variables.refs = {}
    session.ready = false
    session.paused = false
    session.step = nil

    session_send_response(req, true)

    if args.restart then
        session.restart_requested = true
    else
        remove_debug_hook()
        uninstall_wrappers()
    end

    if session.client then
        pcall(function()
            session.client:close()
        end)
    end
end

---@param req moonbug.dap.TerminateRequest
function RequestHandler.handle_terminate(req)
    session_send_response(req, true)
    session_send_event(dap_events.terminated)

    os.exit(0) -- quit the process
end

---@param req moonbug.dap.SetVariableRequest
function RequestHandler.handle_set_variable(req)
    if not session_requires_pause(req) then
        return
    end

    local args = req.arguments or {}
    local ref = session.variables.refs[args.variablesReference]

    if not ref then
        session_send_error(req, "invalid variablesReference")
        return
    end

    local name = args.name
    if type(name) ~= "string" or name == "" or is_pseudo_variable(name) then
        session_send_error(req, "invalid variable name")
        return
    end

    local ordinal = 1
    if ref.kind == "locals" then
        ordinal = ref.data.depth

        if ref.data.handle ~= current_handle() then
            session_send_error(req, "cannot set local in another thread")
            return
        end

        if not frame_getinfo(ref.data.handle, ordinal, "S") then
            session_send_error(req, "stack frame i no longer valid")
            return
        end
    end

    local ok, res, _ = evaluate_expr(ordinal, args.value, nil, "watch")
    if not ok then
        ---@cast res string
        session_send_error(req, res)
        return
    end

    local new_value = res[1]

    if ref.kind == "locals" then
        local i = 1

        while true do
            local n = frame_getlocal(ref.data.handle, ref.data.depth, i)
            if not n then
                session_send_error(req, "no such local")
                return
            end

            if n == name then
                if not frame_setlocal(ref.data.handle, ref.data.depth, i, new_value) then
                    session_send_error(req, "failed to set local")
                    return
                end
                break
            end

            i = i + 1
        end
    elseif ref.kind == "upvalues" then
        local fn = ref.data.func
        local i = 1

        while true do
            local n = debug.getupvalue(fn, i)
            if not n then
                session_send_error(req, "no such upvalue")
                return
            end

            if n == name then
                debug.setupvalue(fn, i, new_value)
                break
            end

            i = i + 1
        end
    elseif ref.kind == "globals" then
        rawset(_G, name, new_value)
    elseif ref.kind == "table" then
        local tbl = ref.data.tbl
        rawset(tbl, table_key_from_name(name), new_value)
    else
        session_send_error(req, "not writable")
        return
    end

    local evaluate_name = nil

    if ref.kind == "locals" or ref.kind == "upvalues" then
        evaluate_name = name
    elseif ref.kind == "globals" then
        evaluate_name = global_evaluate_name(name)
    elseif ref.kind == "table" then
        evaluate_name = table_evaluate_name(ref.data.evaluate_name, table_key_from_name(name))
    end

    local serialized = serialize_value(new_value, name, {
        context = ref.kind,
        evaluate_name = evaluate_name,
    })

    ---@type moonbug.dap.SetVariableResponseBody
    local body = serialized
    session_send_response(req, true, body)
end

---@param req moonbug.dap.Request
local function dispatch(req)
    log.debug("request command: %s", req.command)

    local handler_name = string.format("handle_%s", camel2snake(req.command))

    if RequestHandler[handler_name] then
        local args_str = ""

        if req.arguments then
            args_str = string.format(" - args: %s", readable_tostring(req.arguments))
        end

        log.debug("dispatch command (seq: %d): %s%s", req.seq, req.command, args_str)
        RequestHandler[handler_name](req)
        return
    end

    session_send_error(req, string.format("unsupported command found: %s", tostring(req.command)))
end

local dap_cmd_configuration_done = "configurationDone"
local dap_cmd_disconnect = "disconnect"
local dap_cmd_terminate = "terminate"

---@param sock moonbug.Socket
---@param timeout number?
---@return boolean
---@return string?
local function handshake(sock, timeout)
    session.client = sock
    sock:settimeout(timeout or 5)

    while true do
        local req, req_err = read_message(sock)
        if req_err ~= nil then
            return false, req_err
        end

        if type(req) ~= "table" or req.type ~= "request" then
            return false, "bad dap request"
        end

        ---@cast req moonbug.dap.Request
        local dispatch_ok, dispatch_err = pcall(dispatch, req)
        if not dispatch_ok then
            log.error("dispatch(%s) failed: %s", tostring(req.command), tostring(dispatch_err))
        end

        if req.command == dap_cmd_configuration_done then
            session.ready = true
            return true, nil
        end

        if req.command == dap_cmd_disconnect or req.command == dap_cmd_terminate then
            session.ready = false
            return false, "disconnected during handshake"
        end
    end
end

local function debug_loop()
    if not session.client then
        session.paused = false
        return
    end

    session.client:settimeout(0.5)

    while session.paused and session.ready and session.client ~= nil do
        local req, err = read_message(session.client)
        if not req then
            if err == "timeout" then
                -- still paused, wait longer
            elseif err == "closed" then
                session.ready = false
                session.paused = false
                session.client = nil
            else
                log.error("debug loop: %s", err)
            end
        elseif req.type == "request" then
            ---@cast req moonbug.dap.Request
            local dispatch_ok, dispatch_err = pcall(dispatch, req)
            if not dispatch_ok then
                log.error("debug_loop dispatch(%s) failed: %s", tostring(req.command), tostring(dispatch_err))
                session_send_error(req, tostring(dispatch_err))
            end
        end
    end
end

---@param reason       string
---@param description? string
local function stop(reason, description)
    local ctx = get_context()

    purge_dead_threads()

    session.paused = true
    session.step = nil
    session.step_thread = nil

    for _, c in pairs(session.context) do
        c.frames = {}
    end

    session.next_frame_id = 1

    if reason ~= "exception" then
        ctx.exception = nil
    end

    log.debug("stop: %s%s", reason, (description and string.format(" (%s)", description)) or "")

    session_send_event(dap_events.stopped, {
        reason = reason,
        description = description,
        threadId = ctx.id,
        allThreadsStopped = true,
    })
    debug_loop()
end

---@return boolean
local function error_is_caught()
    local i = 2

    while true do
        local info = debug.getinfo(i, "Sf")
        if not info then
            return false
        end

        if info.func == pcall or info.func == xpcall then
            return true
        end

        i = i + 1
    end
end

---@param message string
local function maybe_pause_on_error(message)
    if not session.ready or not session.client or session.paused or not session.filters.error then
        return
    end

    local caught = error_is_caught()

    local co, is_main = coroutine.running()
    if co ~= nil and not is_main and not caught then
        -- let error escape this coroutine, let coroutine.resume handle it
        return
    end

    if (caught and session.filters.pcall) or (not caught and session.filters.uncaught) then
        local ok, text = pcall(tostring, message)

        local ctx = get_context()
        ctx.exception = {
            message = ok and text or "unknown error",
            caught = caught,
        }

        stop("exception", ok and text or nil)
    end
end

---@param message any
---@param level?  integer
local function wrapped_error(message, level)
    maybe_pause_on_error(message)

    if level == 0 then
        log.error(message)
        error(message, 0)
        return
    end

    log.error(message)
    error(message, (level or 1) + 1)
end

---@param value any
---@param ...   any
---@return any
---@return any
local function wrapped_assert(value, ...)
    if value then
        return value, ...
    end

    local message = select(1, ...) or "assertion failed!"
    maybe_pause_on_error(message)
    log.error(message)
    error(message, 2)
end

local function install_wrappers()
    rawset(_G, "error", wrapped_error)
    rawset(_G, "assert", wrapped_assert)
    rawset(_G, "print", function(...)
        if session.config and session.config.forward_output == false then
            print(...)
            return
        end

        local args = table_pack(...)
        local parts = {}

        for i = 1, args.n do
            table.insert(parts, tostring(args[i]))
        end

        local line = table.concat(parts, "\t") .. "\n"

        -- still print normally
        print(...)

        -- but also send the print command to the client
        session_send_output("stdout", line)
    end)
    rawset(_G, "require", function(name)
        local results = table_pack(require(name))

        if type(name) == "string" then
            register_module(name)
        end

        return table_unpack(results, 1, results.n)
    end)
    rawset(_G.coroutine, "create", function(f)
        local thread = coroutine_create(f)
        local ctx = get_context(thread)

        if not is_luajit then
            debug.sethook(thread, debug_hook, "l")
        end

        log.debug("coroutine #%d created", ctx.id)

        return thread
    end)
    rawset(_G.coroutine, "wrap", function(f)
        return coroutine_wrap(function(...)
            local thread = coroutine.running()
            local ctx = get_context(thread)

            if not is_luajit then
                debug.sethook(thread, debug_hook, "l")
            end

            log.debug("coroutine #%d wrapped", ctx.id)

            return f(...)
        end)
    end)
    rawset(_G.coroutine, "resume", function(thread, ...)
        local results = table_pack(coroutine_resume(thread, ...))

        if not results[1] and session.ready and not session.paused and session.filters.error then
            local caught = error_is_caught()

            if (caught and session.filters.pcall) or (not caught and session.filters.uncaught) then
                local ctx = get_context()

                ctx.exception = {
                    message = tostring(results[2]),
                    caught = caught,
                }

                stop "exception"
            end
        end

        return table_unpack(results, 1, results.n)
    end)
end

uninstall_wrappers = function()
    rawset(_G, "error", error)
    rawset(_G, "assert", assert)
    rawset(_G, "print", print)
    rawset(_G, "require", require)
    rawset(_G.coroutine, "create", coroutine_create)
    rawset(_G.coroutine, "wrap", coroutine_wrap)
    rawset(_G.coroutine, "resume", coroutine_resume)
end

---@param hit_condition string
---@param hit_count     integer
---@return boolean
local function hit_condition_met(hit_condition, hit_count)
    local op, num = hit_condition:match "^%s*([<>=~!%%]?=?)%s*(%d+)%s*$"
    num = num and tonumber(num)

    if not num then
        log.error("invalid hit condition: %s", tostring(hit_condition))
        return false
    end

    if op == ">" then
        return hit_count > num
    elseif op == ">=" then
        return hit_count >= num
    elseif op == "<" then
        return hit_count < num
    elseif op == "<=" then
        return hit_count <= num
    elseif op == "=" or op == "==" then
        return hit_count == num
    elseif op == "~=" or op == "!=" then
        return hit_count ~= num
    elseif op == "%" and num > 0 then
        return hit_count % num == 0
    end

    return hit_count == num
end

---Has breakpoint been hit?
---@param source string
---@param line   integer
---@return boolean
local function hit_breakpoint(source, line)
    local canonical_path = path_resolve(source, session.project_root_dir)
    local bp = session.breakpoints[canonical_path] and session.breakpoints[canonical_path][line]
    if not bp then
        return false
    end

    if bp.condition then
        local timeout = eval_timeout()

        --- read only context so conditions cant mutate locals/upvalues
        --- ordinal 1 = the function executing the breakpoint; debugger internal
        --- frames (debug_hook, hit_breakpoint) are skipped automatically
        local ok, res = evaluate_expr(1, bp.condition, timeout, "watch")

        if ok and not res[1] then
            -- condition evaluated to nil/false
            return false
        end

        if not ok then
            -- treat eval errors as a hit
            log.error("breakpoint condition error: %s", tostring(res))
        end
    end

    bp.hit_count = bp.hit_count + 1

    if bp.hit_condition and not hit_condition_met(bp.hit_condition, bp.hit_count) then
        return false
    end

    if bp.log_message then
        local timeout = eval_timeout()
        local values = {}

        for expr in bp.log_message:gmatch "{([^{}]*)}" do
            if values[expr] == nil then
                local ok, res = evaluate_expr(1, expr, timeout, "watch")
                if not ok then
                    log.error("log point expression error: %s", tostring(res))
                    values[expr] = string.format("<error: %s>", tostring(res))
                else
                    values[expr] = safe_tostring(res[1])
                end
            end
        end

        session_send_output("console", bp.log_message:gsub("{([^{}]*)}", values) .. "\n")
        return false
    end

    -- normal breakpoint hit
    return true
end

local function poll_accept()
    if session.ready or not session.server then
        return
    end

    local client = session.server:accept()
    if not client then
        return
    end

    client:setoption("tcp-nodelay", true)

    local ok, handshake_err = handshake(client, 5)
    if not ok then
        log.debug("handshake failed: %s", tostring(handshake_err))
        pcall(client.close, client)
        session.client = nil
        return
    end

    if session.config.stop_on_attach then
        session.step = "pause"
    end
end

local function poll_running()
    if not session.ready or session.paused or session.client == nil then
        return
    end

    session.client:settimeout(0)

    local req, err = read_message(session.client)
    if req == nil and err == "closed" then
        session.ready = false
        session.paused = false
        session.client = nil
        return
    end

    if type(req) == "table" and req.type == "request" then
        ---@cast req moonbug.dap.Request
        local dispatch_ok, dispatch_err = pcall(dispatch, req)
        if not dispatch_ok then
            log.error("dispatch error: %s", dispatch_err)
        end
    end
end

local function absolute_depth()
    local n = 0
    local level = 2

    while true do
        local info = debug.getinfo(level, "S")

        if not info then
            break
        end

        if info.what == "Lua" then
            n = n + 1
        end

        level = level + 1
    end

    return n
end

debug_hook = function(event, line)
    if session.restart_requested then
        log.warning("moonbug: restart requested", 0)
        session_reset(true)
        return
    end

    if event ~= "line" then
        return
    end

    local info = debug.getinfo(2, "S")
    if not info then
        return
    end

    if info.source == self_src then
        local resume = session.resume_location

        if resume and current_handle() == resume.handle then
            resume.left = true
        end

        return
    end

    if session.paused then
        return
    end

    if not session.ready then
        poll_accept()
        return
    end

    poll_running()

    -- add sources we encoutner to the sources list
    local source_path = path_resolve(info.source, session.project_root_dir)
    if source_path ~= "" and not session.sources[source_path] then
        session.sources[source_path] = true

        if session.client then
            session_send_event(dap_events.loaded_source, {
                reason = "new",
                source = {
                    name = (info.short_src or ""):match "[^/\\]+$" or info.short_src,
                    path = source_path,
                },
            })
        end
    end

    local handle = current_handle()
    local ctx = get_context(handle)

    if not ctx.base_depth then
        ctx.base_depth = absolute_depth()
    end

    ctx.stack_level = absolute_depth() - ctx.base_depth

    local resume = session.resume_location
    local duplicate_return = false

    if resume and resume.handle == handle then
        if ctx.stack_level > resume.level then
            -- lua call entered a deeper frame
            resume.left = true
        elseif ctx.stack_level < resume.level or info.source ~= resume.source or line ~= resume.line then
            -- execution reached a different source location
            session.resume_location = nil
        elseif resume.left then
            -- luajit reported original call site again after returning
            duplicate_return = true
            session.resume_location = nil
        end
    end

    ctx.locations[ctx.stack_level] = {
        source = info.source,
        line = line,
    }

    if duplicate_return then
        return
    end

    local reason = nil

    if session.step == "pause" then
        reason = "pause"
    elseif session.step == "entry" then
        reason = "entry"
    elseif session.step == "in" then
        reason = "step"
    elseif session.step == "over" and handle == session.step_thread and ctx.stack_level <= session.step_level then
        reason = "step"
    elseif session.step == "out" and handle == session.step_thread and ctx.stack_level <= session.step_level then
        reason = "step"
    elseif hit_breakpoint(info.source, line) then
        reason = "breakpoint"
    end

    if reason then
        stop(reason)
    end
end

local function setup_debug_hook()
    local handle = current_handle()
    local ctx = get_context(handle)

    ctx.base_depth = absolute_depth()
    ctx.stack_level = 0

    debug.sethook(debug_hook, "l")
end

remove_debug_hook = function()
    if debug.gethook() == debug_hook then
        debug.sethook()
    end

    -- NOTE(luajit): luajit installs hooks on all threads, for others we have to do it one by one
    if not is_luajit then
        for handle in pairs(session.context) do
            if handle ~= main_thread then
                debug.sethook(handle)
            end
        end
    end
end

---@param host string?
---@param port integer?
---@return moonbug.Socket?
---@return string?
local function bind(host, port)
    resolve_libs()

    local h = host or "127.0.0.1"
    local p = port or tonumber(os.getenv "MOONBUG_PORT") or default_port

    log.debug("attempt to listen on '%s:%d'", h, p)

    local server, err = socket().bind(h, p)
    if not server then
        log.error("could not bind '%s:%d': %s", h, p, err)
        return nil, err
    end

    log.debug("successfully bound socket to '%s:%d'", h, p)

    server:settimeout(0)
    return server, nil
end

---@param host? string
---@param port? integer
---@param opts? moonbug.Config
function M.listen(host, port, opts)
    -- save the initial session config for later
    if not started_once then
        log.info(
            "Hello Moonbug %s",
            readable_tostring {
                lua_version = _VERSION,
                luajit = is_luajit,
                moonbug_version = M.version_string(),
                start_options = opts,
            }
        )

        start_host = host
        start_port = port
        start_opts = opts

        started_once = true
    end

    -- reset session back to zero state
    session_reset()

    session.config = opts or {}

    install_wrappers()

    local server, err = bind(host, port)
    if err ~= nil then
        log.fatal("could not create server: %s", err)
        return
    end

    assert(server)

    session.server = server

    if session.config.wait == true then
        local deadline = session.config.max_wait_time and (socket().gettime() + session.config.max_wait_time)
        session.server:settimeout(0.1)

        if session.config.max_wait_time then
            log.debug("max wait time set at: %ds", session.config.max_wait_time)
        end

        while true do
            local client = session.server:accept()
            if client then
                log.debug "accepted client"
                client:setoption("tcp-nodelay", true)
                session.server:settimeout(0)

                local ok, handshake_err = handshake(client, 30)
                if ok then
                    setup_debug_hook()
                    return true, nil
                end

                log.debug("handshake failed: %s. Waiting for another client...", handshake_err)
                pcall(client.close, client)
                session.server:settimeout(0.1)
            end

            if deadline and socket().gettime() > deadline then
                log.error "wait timeout exceeded"

                session.server:settimeout(0)
                setup_debug_hook()
                return
            end
        end
    end

    setup_debug_hook()
    session.server:settimeout(0)
end

-- if test flag is set expose some functionality for testing purposes
if os.getenv "MOONBUG_TEST" then
    M._test = {
        dap = {
            parse_content_length = parse_content_length,
            read_message = read_message,
            send_message = send_message,
        },
        path = {
            is_absolute = path_is_absolute,
            join = path_join,
            normalize = path_normalize,
            resolve = path_resolve,
        },
        collections = {
            slice = slice,
            table_array_length = table_array_length,
            table_named_keys = table_named_keys,
            table_named_count = table_named_count,
        },
        breakpoints = {
            hit_condition_met = hit_condition_met,
        },
        completions = {
            split_input = split_completion_input,
            complete_fields = complete_fields,
        },
        helpers = {
            camel2snake = camel2snake,
            str_starts_with = str_starts_with,
        },
    }
end

return M
