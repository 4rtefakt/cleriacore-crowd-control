-- Crowd Control: Twitch chat votes, the game obeys.
-- Chat is read over Twitch's IRC-over-WebSocket endpoint with an anonymous login (a "justinfan" nick):
-- read-only, no account and no token. Every vote is a chat line that is exactly 1, 2 or 3.

local S, P, G = cleria.settings, cleria.player, cleria.game

local enabled = S.get("Enabled", true)
local channel = S.get("Channel", "")
local server = S.get("Server", "wss://irc-ws.chat.twitch.tv:443")
local poll_every = S.get("PollEvery", 60)      -- seconds of play between two votes
local vote_time = S.get("VoteTime", 20)
local effect_time = S.get("EffectTime", 30)
local no_vote_random = S.get("RandomIfNoVote", false)

-- ---- the effects: timed ones are read by the filters below, instant ones run once ------------------------------
local active = nil                              -- the timed effect running: {key =, left = ticks}
local function is(key) return active ~= nil and active.key == key end

local EFFECTS = {   -- key, name, timed?, run (instant ones)
    {"surge", "Power Surge: you deal double damage", true},
    {"weak", "Weakness: you deal half damage", true},
    {"iron", "Iron Skin: you take half damage", true},
    {"glass", "Glass Skin: you take double damage", true},
    {"gold", "Gold Rush: triple SP", true},
    {"wisdom", "Wisdom: triple EXP", true},
    {"famine", "Famine: monsters drop nothing", true},
    {"heal", "Heal: half your max HP back", false, function()
        P.set_hp(math.min(P.max_hp(), P.hp() + P.max_hp() // 2))
    end},
    {"tax", "Blood Tax: lose a third of your HP", false, function()
        P.set_hp(math.max(1, P.hp() - P.hp() // 3))
    end},
    {"jackpot", "Jackpot: SP for your level", false, function()
        P.add_sp(100 * P.level())
    end},
    {"supply", "Supply Drop: healing and a Strength Drop", false, function()
        local st = P.stats()
        for i = 1, 3 do G.spawn_pickup(0x42, st.x + i - 2, st.y + 0.5, st.z) end
        G.spawn_pickup(0x48, st.x, st.y + 0.5, st.z + 1)
    end},
}
local BY = {}
for _, e in ipairs(EFFECTS) do BY[e[1]] = e end

cleria.combat.add_filter("damage", function(q)
    if q.value <= 0 then return nil end
    if q.dir == "dealt" then
        if is("surge") then return q.value * 2 end
        if is("weak") then return math.max(1, q.value // 2) end
    else
        if is("iron") then return math.max(1, q.value // 2) end
        if is("glass") then return q.value * 2 end
    end
end)
cleria.combat.add_filter("sp", function(q) if is("gold") and q.source ~= "script" then return q.value * 3 end end)
cleria.combat.add_filter("exp", function(q) if is("wisdom") then return q.value * 3 end end)
cleria.combat.add_filter("drop", function(q) if is("famine") then return "suppress" end end)

-- ---- the vote ----------------------------------------------------------------------------------------------------
local vote = nil                                -- {options = {key, key, key}, by = {user = n}, left = ticks}
local wait = poll_every * 60                    -- ticks of play until the next vote

local function tally()
    local c = {0, 0, 0}
    if vote then for _, n in pairs(vote.by) do c[n] = c[n] + 1 end end
    return c
end
local function apply(key)
    local e = BY[key]
    if not e then return end
    cleria.notice(e[2], "Chat decided")
    cleria.log("effect: " .. key)
    if e[3] then active = {key = key, left = effect_time * 60} else e[4]() end
end
local function start_vote()
    local pool = {}
    for _, e in ipairs(EFFECTS) do pool[#pool + 1] = e[1] end
    local options = {}
    for i = 1, 3 do options[i] = table.remove(pool, math.random(#pool)) end
    vote = {options = options, by = {}, left = vote_time * 60}
    cleria.log("vote: " .. table.concat(options, ", "))
end
local function end_vote()
    local c = tally()
    local best, winners = math.max(c[1], c[2], c[3]), {}
    for i = 1, 3 do if c[i] == best then winners[#winners + 1] = i end end
    local options = vote.options
    cleria.log(string.format("votes %d %d %d", c[1], c[2], c[3]))
    vote, wait = nil, poll_every * 60
    if best == 0 and not no_vote_random then cleria.log("no votes: nothing happens") return end
    apply(options[winners[math.random(#winners)]])
end

cleria.events.on("tick", function()
    if not enabled or not G.in_game() or G.frozen() or P.hp() <= 0 then return end
    if active then
        active.left = active.left - 1
        if active.left <= 0 then cleria.log("effect over: " .. active.key) active = nil end
    end
    if vote then
        vote.left = vote.left - 1
        if vote.left <= 0 then end_vote() end
    elseif not active then
        wait = wait - 1
        if wait <= 0 then start_vote() end
    end
end)

-- ---- Twitch chat ---------------------------------------------------------------------------------------------------
local ws, status, retry_at, seen = nil, "not connected", 0, 0

local function on_line(line)
    if line:find("^PING") then ws:send("PONG" .. line:sub(5)) return end
    local user, text = line:match("^:([^!]+)![^ ]+ PRIVMSG #[^ ]+ :(.*)$")
    if user then
        seen = seen + 1
        local n = tonumber(text:match("^%s*([123])%s*$"))
        if n and vote then vote.by[user] = n end
        return
    end
    if line:find(" 366 ") or line:find(" JOIN #") then
        if status ~= "connected" then cleria.log("joined #" .. channel) end
        status = "connected"
    end
end

cleria.events.on("frame", function()
    if not enabled or channel == "" then
        if ws then ws:close() ws = nil end
        status = channel == "" and "no channel set" or "off"
        return
    end
    if not ws then
        if cleria.time() < retry_at then return end
        ws = cleria.net.websocket()
        ws:open(server)
        status = "connecting"
        return
    end
    for _, e in ipairs(ws:poll()) do
        if e.kind == "open" then
            ws:send("NICK justinfan" .. math.random(10000, 99999))
            ws:send("JOIN #" .. channel:lower())
        elseif e.kind == "message" then
            for line in (e.text or ""):gmatch("[^\r\n]+") do on_line(line) end
        elseif e.kind == "close" then
            status, ws, retry_at = "not connected", nil, cleria.time() + 10
            return
        end
    end
end)

-- ---- what the streamer and the viewers see -------------------------------------------------------------------------
cleria.hud.layer("crowd", function(d)
    if not enabled or not G.in_game() then return end
    local s = d.scale
    local w = 430 * s
    local x, y = d.w - w - 14 * s, 14 * s
    if vote then
        local c = tally()
        d:rect(x, y, w, 146 * s, {color = 0x100F0B, alpha = 0.78, rounding = 6 * s})
        d:text(x + 14 * s, y + 8 * s, "CHAT VOTE: type 1, 2 or 3", {size = 18 * s, color = "gold", font = "bold"})
        d:text(x + w - 60 * s, y + 8 * s, string.format("%ds", vote.left // 60 + 1), {size = 18 * s, color = "value", font = "cond_medium"})
        for i = 1, 3 do
            local ry = y + 8 * s + i * 32 * s
            d:text(x + 14 * s, ry, i .. "  " .. BY[vote.options[i]][2], {size = 17 * s, color = "label", font = "cond"})
            d:text(x + w - 40 * s, ry, tostring(c[i]), {size = 17 * s, color = "value", font = "cond_medium"})
        end
    elseif active then
        local text = BY[active.key][2] .. string.format("  (%ds)", active.left // 60 + 1)
        local tw = d:text_size(text, {size = 18 * s, font = "cond_medium"})
        d:rect(d.w - tw - 38 * s, y, tw + 24 * s, 32 * s, {color = 0x100F0B, alpha = 0.75, rounding = 4 * s})
        d:text(d.w - tw - 26 * s, y + 6 * s, text, {size = 18 * s, color = "warn", font = "cond_medium"})
    end
end)

cleria.ui.page("Crowd Control", function(p)
    p:section("Twitch")
    p:info("Chat", status, {color = status == "connected" and "good" or "warn", desc = seen .. " chat lines read."})
    local v, ch = p:text_field("Channel", channel, {desc = "Your Twitch channel's name. Chat is read anonymously: no login.", empty = "(none)"})
    if ch then channel = v:gsub("^#", "") S.set("Channel", channel) if ws then ws:close() ws = nil end retry_at = 0 end
    v, ch = p:toggle("Enabled", enabled, "Votes run while you play. Not a retail option.")
    if ch then enabled = v S.set("Enabled", v) end
    p:section("Votes")
    v, ch = p:slider("Time between votes", poll_every, 15, 300, 15, "%.0f s", "Seconds of play between two votes. Cutscenes do not count.")
    if ch then poll_every = math.floor(v + 0.5) S.set("PollEvery", poll_every) end
    v, ch = p:slider("Voting time", vote_time, 10, 60, 5, "%.0f s", "How long chat has to vote.")
    if ch then vote_time = math.floor(v + 0.5) S.set("VoteTime", vote_time) end
    v, ch = p:slider("Effect time", effect_time, 10, 120, 5, "%.0f s", "How long a timed effect lasts.")
    if ch then effect_time = math.floor(v + 0.5) S.set("EffectTime", effect_time) end
    v, ch = p:toggle("Random if nobody votes", no_vote_random, "With no vote at all, one of the three is applied anyway.")
    if ch then no_vote_random = v S.set("RandomIfNoVote", v) end
    if p:button("Start a vote now", {enabled = G.in_game() and vote == nil}) then start_vote() end
end)

cleria.speedrun.modification("Crowd Control (chat-voted effects)")
cleria.command("cc", function(a)
    local cmd, arg = a:match("^(%S*)%s*(%S*)")
    if cmd == "vote" then start_vote() elseif cmd == "apply" then apply(arg) end
    local c = tally()
    cleria.log(string.format("status %s seen %d vote %s tally %d %d %d active %s", status, seen, vote and table.concat(vote.options, ",") or "-",
                             c[1], c[2], c[3], active and active.key or "-"))
end)
cleria.log("Crowd Control loaded" .. (channel ~= "" and (" for #" .. channel) or " (no channel set)"))
