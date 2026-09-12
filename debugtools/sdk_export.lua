-- Lovense Haptics developer tool: exports a slice of the RE Engine type
-- database as JSON.
--
-- REFramework's own "Dump SDK" writes the entire database. On Monster Hunter
-- Rise that is ~1.4 GB and takes many minutes, and essentially all of it is
-- irrelevant: what a game profile needs is the method and field names of a
-- handful of player and enemy types. This walks outwards from a few named
-- types instead and writes a file small enough to actually read.
--
-- The Lua API cannot enumerate the type database (there is no sdk.get_tdb),
-- so this needs at least one type name to start from. Find one with
-- REFramework's Object Explorer: the "Type Name", "Method Signature" and
-- "Field Signature" boxes all search live, which is faster than any dump.
--
-- Not part of the mod and never packaged. Deploy with:
--   .\_deploy.ps1 -Game rise -Dev

local config = {
    roots = "",
    namespace = "",
    depth = 1,
    max_types = 400,
    member_filter = "",
    want_methods = true,
    want_fields = true,
    out = "sdk_export.json",
}

-- "app." on Wilds, "snow." on Rise. Saves the user working out the game's
-- namespace by hand, and it is the right default for the follow filter.
do
    local ok, ns = pcall(sdk.game_namespace, "")
    if ok and type(ns) == "string" then config.namespace = ns end
end

local status = "idle"

local function type_name(td)
    if td == nil then return nil end
    local ok, name = pcall(td.get_full_name, td)
    if ok and type(name) == "string" then return name end
    return nil
end

local function matches(text, filter)
    if filter == "" then return true end
    if type(text) ~= "string" then return false end
    return text:lower():find(filter:lower(), 1, true) ~= nil
end

local function describe_field(f)
    local entry = {
        name = f:get_name(),
        type = type_name(f:get_type()) or "?",
        static = f:is_static(),
    }
    -- Throws on some static and literal fields; the offset is a nicety, not
    -- worth losing the field name over.
    local ok, offset = pcall(f.get_offset_from_base, f)
    if ok and type(offset) == "number" then
        entry.offset = string.format("0x%X", offset)
    end
    return entry
end

local function describe_method(m)
    local params = {}
    local ok_types, types = pcall(m.get_param_types, m)
    local ok_names, names = pcall(m.get_param_names, m)
    if ok_types and types ~= nil then
        for i = 1, #types do
            local pname = (ok_names and names ~= nil and names[i]) or ("arg" .. i)
            params[#params + 1] = (type_name(types[i]) or "?") .. " " .. tostring(pname)
        end
    end
    return {
        name = m:get_name(),
        static = m:is_static(),
        returns = type_name(m:get_return_type()) or "?",
        params = params,
    }
end

-- Describes one type. Anything it references is appended to `refs` so the
-- caller can decide whether to follow it; that is kept separate from the
-- member filter, because a filtered-out member can still point at a type
-- worth visiting.
local function describe_type(td, refs)
    local entry = {
        name = type_name(td),
        parent = type_name(td:get_parent_type()),
    }
    if refs ~= nil then refs[#refs + 1] = td:get_parent_type() end

    local filter = config.member_filter
    local kept = 0

    if config.want_fields then
        local out = {}
        local ok, fields = pcall(td.get_fields, td)
        if ok and fields ~= nil then
            for i = 1, #fields do
                local okf, d = pcall(describe_field, fields[i])
                if okf then
                    if refs ~= nil then refs[#refs + 1] = fields[i]:get_type() end
                    if matches(d.name, filter) or matches(d.type, filter) then
                        out[#out + 1] = d
                        kept = kept + 1
                    end
                end
            end
        end
        entry.fields = out
    end

    if config.want_methods then
        local out = {}
        local ok, methods = pcall(td.get_methods, td)
        if ok and methods ~= nil then
            for i = 1, #methods do
                local okm, d = pcall(describe_method, methods[i])
                if okm then
                    if refs ~= nil then
                        refs[#refs + 1] = methods[i]:get_return_type()
                        local okt, types = pcall(methods[i].get_param_types, methods[i])
                        if okt and types ~= nil then
                            for j = 1, #types do refs[#refs + 1] = types[j] end
                        end
                    end
                    if matches(d.name, filter) or matches(d.returns, filter) then
                        out[#out + 1] = d
                        kept = kept + 1
                    end
                end
            end
        end
        entry.methods = out
    end

    -- With a filter on, a type that matched nothing is noise.
    if filter ~= "" and kept == 0 then return nil end
    return entry
end

local function run_export()
    local roots, missing = {}, {}
    for name in config.roots:gmatch("[^,%s]+") do roots[#roots + 1] = name end
    if #roots == 0 then
        status = "no root types given"
        return
    end

    local queue = {}
    for i = 1, #roots do
        local td = sdk.find_type_definition(roots[i])
        if td == nil then
            missing[#missing + 1] = roots[i]
        else
            queue[#queue + 1] = { td = td, depth = 0 }
        end
    end

    local prefix = config.namespace
    local seen, entries = {}, {}
    local head, truncated = 1, false

    while head <= #queue do
        if #entries >= config.max_types then
            truncated = true
            break
        end

        local item = queue[head]
        head = head + 1

        local name = type_name(item.td)
        if name ~= nil and not seen[name] then
            seen[name] = true

            -- Only collect references while there is still depth to spend.
            local refs = (item.depth < config.depth) and {} or nil
            local ok, entry = pcall(describe_type, item.td, refs)
            if ok and entry ~= nil then entries[#entries + 1] = entry end

            if refs ~= nil then
                for i = 1, #refs do
                    local rname = type_name(refs[i])
                    if rname ~= nil and not seen[rname] then
                        if prefix == "" or rname:sub(1, #prefix) == prefix then
                            queue[#queue + 1] = { td = refs[i], depth = item.depth + 1 }
                        end
                    end
                end
            end
        end
    end

    local result = {
        namespace = prefix,
        tdb_version = sdk.get_tdb_version(),
        roots = roots,
        missing_roots = missing,
        depth = config.depth,
        member_filter = config.member_filter,
        truncated = truncated,
        type_count = #entries,
        types = entries,
    }

    local ok, err = pcall(json.dump_file, config.out, result)
    if not ok then
        status = "write failed: " .. tostring(err)
        log.info("[sdk_export] write failed: " .. tostring(err))
        return
    end

    status = string.format("wrote %d type(s) to reframework/data/%s%s",
        #entries, config.out, truncated and " (TRUNCATED)" or "")
    if #missing > 0 then
        status = status .. "  |  not found: " .. table.concat(missing, ", ")
    end
    log.info("[sdk_export] " .. status)
end

re.on_draw_ui(function()
    if not imgui.tree_node("Lovense SDK export (dev)") then return end

    imgui.text_colored("Exports named types and what they reference, as JSON.", 0xFFAAAAAA)
    imgui.text_colored("Find type names with Object Explorer's search boxes.", 0xFFAAAAAA)
    imgui.separator()

    local changed
    changed, config.roots = imgui.input_text("Root types (comma separated)", config.roots)
    changed, config.namespace = imgui.input_text("Only follow namespace", config.namespace)
    changed, config.member_filter = imgui.input_text("Member name contains", config.member_filter)
    changed, config.depth = imgui.slider_int("Follow depth", config.depth, 0, 3)
    changed, config.max_types = imgui.slider_int("Max types", config.max_types, 1, 5000)
    changed, config.want_methods = imgui.checkbox("Methods", config.want_methods)
    imgui.same_line()
    changed, config.want_fields = imgui.checkbox("Fields", config.want_fields)
    changed, config.out = imgui.input_text("Output file", config.out)

    imgui.separator()
    if imgui.button("Export") then
        status = "working..."
        local ok, err = pcall(run_export)
        if not ok then
            status = "failed: " .. tostring(err)
            log.info("[sdk_export] failed: " .. tostring(err))
        end
    end

    imgui.text("Status: " .. status)
    imgui.tree_pop()
end)

log.info("[sdk_export] loaded")
