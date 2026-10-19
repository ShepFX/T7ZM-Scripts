// [Shep] Map vote for BO3 zombies (EZZ BOIII).
//
//   .map        starts a vote: "<player> wants to change map!" + a numbered list of the OTHER maps in
//               this server's rotation (sv_maprotation), e.g.  .1 The Giant   .2 Der Eisendrache
//   .1 .2 ...   vote for that map ("1" works too); typing another number changes your vote (last one counts)
//   .map kino   start a vote and vote for that map in one go (name, part of a name, or list number)
//   .restart    vote to restart the current map; others agree with .restart / yes / .y
//
// A map wins as soon as it has a majority of the players on the server (solo = instant). After 60 s
// with no winner the vote fails. Anti-spam: 5-minute cooldown after any vote (passed or failed) before
// a new one can start, and a player can only start a vote once every 10 minutes.
// A passed vote changes map in-process ("map <name>", safe with -nosnd); players reconnect.
// Every dot command this script sees, and what it did with it, is appended to
// boiii/scriptdata/cuk/<port>/mapvote.log (compare with [chat] lines in console_mp.log).

autoexec function cuk_mapvote_init()
{
    level.cuk_mv = spawnstruct();
    level.cuk_mv.vote_secs = 60;
    level.cuk_mv.cooldown_ms = 300000;          // after any vote
    level.cuk_mv.player_cooldown_ms = 600000;   // between votes started by the same player
    level.cuk_mv.active = false;
    level.cuk_mv.last_end = 0;
    level.cuk_mv.changing = false;
    level.cuk_mv.endgame_secs = 18;   // BO3 rotates by itself ~22 s after game over
    level.cuk_rv = spawnstruct();      // restart vote
    level.cuk_rv.active = false;
    level.cuk_rv.last_end = 0;
    level.cuk_rv.yes = [];
    level.cuk_mv.options = [];
    level.cuk_mv.choice_of = [];   // player entity number -> option index
    level thread cuk_mv_connect();   // chat listener first, so nothing below can stop it starting
    level thread cuk_mv_sweep();
    level thread cuk_mv_log_init();
    level thread cuk_mv_endgame();
}

// ---------------------------------------------------------------- vote log

function cuk_mv_log_init()
{
    wait 1;
    dir = "cuk/" + getdvarstring("net_port");
    if (!directoryexists("cuk"))
        mkdir("cuk");
    if (!directoryexists(dir))
        mkdir(dir);
    level.cuk_mv_log = dir + "/mapvote.log";
    cuk_mv_log("map loaded " + getdvarstring("mapname"));
}

function cuk_mv_log(msg)
{
    if (!isdefined(level.cuk_mv_log))
        return;
    appendfile(level.cuk_mv_log, gettime() + " " + msg + "\n");
}

// ---------------------------------------------------------------- map table

function cuk_mv_add(code, name)
{
    m = spawnstruct();
    m.code = code;
    m.name = name;
    level.cuk_mv_all[level.cuk_mv_all.size] = m;
}

function cuk_mv_build_maps()
{
    level.cuk_mv_all = [];
    cuk_mv_add("zm_zod",        "Shadows of Evil");
    cuk_mv_add("zm_factory",    "The Giant");
    cuk_mv_add("zm_castle",     "Der Eisendrache");
    cuk_mv_add("zm_island",     "Zetsubou No Shima");
    cuk_mv_add("zm_stalingrad", "Gorod Krovi");
    cuk_mv_add("zm_genesis",    "Revelations");
    cuk_mv_add("zm_prototype",  "Nacht der Untoten");
    cuk_mv_add("zm_asylum",     "Verruckt");
    cuk_mv_add("zm_sumpf",      "Shi No Numa");
    cuk_mv_add("zm_theater",    "Kino der Toten");
    cuk_mv_add("zm_cosmodrome", "Ascension");
    cuk_mv_add("zm_temple",     "Shangri-La");
    cuk_mv_add("zm_moon",       "Moon");
    cuk_mv_add("zm_tomb",       "Origins");

    // options = this server's rotation, in order, minus the map being played now
    level.cuk_mv.options = [];
    current = getdvarstring("mapname");
    rot = strtok(getdvarstring("sv_maprotation"), " ");
    for (i = 0; i < rot.size - 1; i++)
    {
        if (rot[i] != "map" || rot[i + 1] == current)
            continue;
        for (j = 0; j < level.cuk_mv_all.size; j++)
            if (level.cuk_mv_all[j].code == rot[i + 1])
                level.cuk_mv.options[level.cuk_mv.options.size] = level.cuk_mv_all[j];
    }
}

// ---------------------------------------------------------------- chat

function cuk_mv_connect()
{
    for (;;)
    {
        level waittill("connected", player);
        player cuk_mv_hook("connected");
    }
}

// safety net: any player on the server without a chat listener gets one (e.g. a missed "connected")
function cuk_mv_sweep()
{
    for (;;)
    {
        wait 2;
        players = getplayers();
        for (i = 0; i < players.size; i++)
            if (isdefined(players[i]))
                players[i] cuk_mv_hook("sweep");
    }
}

function cuk_mv_hook(how)
{
    if (isdefined(self.cuk_mv_hooked))
        return;
    self.cuk_mv_hooked = true;
    if (how != "connected")
        cuk_mv_log("listener added late (" + how + ") for " + cuk_mv_pname(self));
    self thread cuk_mv_chat();
}

function cuk_mv_chat()
{
    self endon("disconnect");
    for (;;)
    {
        self waittill("chat", text);
        t = tolower("" + text);
        while (t != "" && getsubstr(t, 0, 1) == " ")
            t = getsubstr(t, 1, t.size);
        while (t != "" && getsubstr(t, t.size - 1, t.size) == " ")
            t = getsubstr(t, 0, t.size - 1);
        if (t != "" && getsubstr(t, 0, 1) == ".")
            cuk_mv_log("chat " + cuk_mv_pname(self) + ": " + t + " (vote " + level.cuk_mv.active + ")");
        if (t == ".map" || t == ".maps" || t == ".mapvote")
            cuk_mv_start(self, "");
        else if (t.size > 5 && getsubstr(t, 0, 5) == ".map ")
            cuk_mv_start(self, getsubstr(t, 5, t.size));
        else if (t == ".restart" || t == ".rs")
            cuk_rv_start(self);
        else if (level.cuk_rv.active && (t == "yes" || t == ".yes" || t == "y" || t == ".y"))
            cuk_rv_yes(self);
        else if (level.cuk_mv.active)
        {
            // players type "2" as often as ".2", so take both
            if (t.size >= 2 && getsubstr(t, 0, 1) == ".")
                t = getsubstr(t, 1, t.size);
            if (t.size >= 1 && t.size <= 2)
            {
                n = cuk_mv_number(t);
                if (n >= 1 && n <= level.cuk_mv.options.size)
                    cuk_mv_vote(self, n - 1);
            }
        }
    }
}

// "3" -> 3, anything that isn't 1-2 digits -> -1
function cuk_mv_number(s)
{
    digits = "0123456789";
    n = 0;
    for (i = 0; i < s.size; i++)
    {
        d = -1;
        for (k = 0; k < 10; k++)
            if (digits[k] == s[i])
                d = k;
        if (d < 0)
            return -1;
        n = n * 10 + d;
    }
    if (s.size == 0)
        return -1;
    return n;
}

// ---------------------------------------------------------------- voting

// want = what came after ".map " ("" for a plain .map): a list number or (part of) a map name
function cuk_mv_start(player, want)
{
    // built on first use, not in the autoexec (too early in the map load)
    if (!isdefined(level.cuk_mv_all))
        cuk_mv_build_maps();
    if (level.cuk_mv.changing)
    {
        cuk_mv_log("  -> ignored, map already changing");
        return;
    }
    if (level.cuk_rv.active)
    {
        player iprintln("^3A restart vote is running - type ^5yes^3 to agree, or wait for it to finish.");
        cuk_mv_log("  -> restart vote running");
        return;
    }
    if (level.cuk_mv.options.size == 0)
    {
        player iprintln("^3This server only has one map.");
        cuk_mv_log("  -> one map only");
        return;
    }
    idx = -1;
    if (want != "")
    {
        idx = cuk_mv_find(want);
        if (idx < 0)
        {
            player iprintln("^3No map in this rotation matches '^5" + want + "^3' - pick a number from the list.");
            cuk_mv_log("  -> no map matches '" + want + "'");
        }
    }
    if (level.cuk_mv.active)
    {
        if (idx >= 0)
        {
            cuk_mv_vote(player, idx);
            return;
        }
        // two people typing .map together: the vote that just started already sent this player the list
        if (isdefined(player.cuk_mv_shown_at) && gettime() - player.cuk_mv_shown_at < 15000)
        {
            cuk_mv_log("  -> already running, list was just sent");
            return;
        }
        player iprintln("^3A map vote is already running - type the number of the map you want.");
        player thread cuk_mv_show_options();
        cuk_mv_log("  -> already running, options re-sent");
        return;
    }
    if (level.cuk_mv.last_end > 0 && gettime() - level.cuk_mv.last_end < level.cuk_mv.cooldown_ms)
    {
        player iprintln("^3Map vote cooldown. Try again in ^5" + cuk_mv_secs_left(level.cuk_mv.last_end, level.cuk_mv.cooldown_ms) + "^3 seconds.");
        cuk_mv_log("  -> server cooldown");
        return;
    }
    if (isdefined(player.cuk_mv_started) && gettime() - player.cuk_mv_started < level.cuk_mv.player_cooldown_ms)
    {
        player iprintln("^3You started a map vote recently. Try again in ^5" + cuk_mv_secs_left(player.cuk_mv_started, level.cuk_mv.player_cooldown_ms) + "^3 seconds.");
        cuk_mv_log("  -> player cooldown");
        return;
    }
    player.cuk_mv_started = gettime();
    level.cuk_mv.active = true;
    level.cuk_mv.choice_of = [];
    cuk_mv_bold_all("^3" + cuk_mv_pname(player) + "^7 wants to change map! Type ^5.1^7, ^5.2^7 ... to vote");
    cuk_mv_say_all("^3Map vote:^7 need ^5" + cuk_mv_required() + "^7 votes, ^5" + level.cuk_mv.vote_secs + "^7 s - options:");
    cuk_mv_log("  -> vote started, " + level.cuk_mv.options.size + " options, " + getplayers().size + " players");
    players = getplayers();
    for (i = 0; i < players.size; i++)
        players[i] thread cuk_mv_show_options();
    level thread cuk_mv_timeout();
    if (idx >= 0)
        cuk_mv_vote(player, idx);
}

function cuk_mv_show_options()
{
    self endon("disconnect");
    self.cuk_mv_shown_at = gettime();
    for (i = 0; i < level.cuk_mv.options.size; i++)
    {
        wait 0.4;
        self iprintln("^5." + (i + 1) + "^7  " + level.cuk_mv.options[i].name);
    }
}

// "2" -> option 2, "kino" / "zm_theater" / "der eisen" -> first option whose name or code contains it, else -1
function cuk_mv_find(want)
{
    while (want.size > 0 && getsubstr(want, want.size - 1, want.size) == " ")
        want = getsubstr(want, 0, want.size - 1);
    if (want == "")
        return -1;
    n = cuk_mv_number(want);
    if (n >= 1 && n <= level.cuk_mv.options.size)
        return n - 1;
    for (i = 0; i < level.cuk_mv.options.size; i++)
        if (issubstr(tolower(level.cuk_mv.options[i].name), want) || issubstr(level.cuk_mv.options[i].code, want))
            return i;
    return -1;
}

function cuk_mv_vote(player, idx)
{
    key = "" + player getentitynumber();
    changed = isdefined(level.cuk_mv.choice_of[key]);
    level.cuk_mv.choice_of[key] = idx;
    votes = cuk_mv_count(idx);
    required = cuk_mv_required();
    word = "voted for";
    if (changed)
        word = "changed vote to";
    cuk_mv_say_all("^5" + cuk_mv_pname(player) + "^7 " + word + " ^5" + level.cuk_mv.options[idx].name + "^7 (^5" + votes + "^7/^5" + required + "^7)");
    cuk_mv_log("  -> vote " + (idx + 1) + " " + level.cuk_mv.options[idx].name + " " + votes + "/" + required);
    if (votes >= required)
        level thread cuk_mv_pass(idx);
}

// votes for an option from players still on the server
function cuk_mv_count(idx)
{
    n = 0;
    players = getplayers();
    for (i = 0; i < players.size; i++)
    {
        key = "" + players[i] getentitynumber();
        if (isdefined(level.cuk_mv.choice_of[key]) && level.cuk_mv.choice_of[key] == idx)
            n++;
    }
    return n;
}

function cuk_mv_timeout()
{
    level endon("cuk_mv_ended");
    wait level.cuk_mv.vote_secs;
    if (!level.cuk_mv.active)
        return;
    level.cuk_mv.active = false;
    level.cuk_mv.last_end = gettime();
    level.cuk_mv.choice_of = [];
    cuk_mv_bold_all("^3Map vote failed^7 - no map got a majority");
    cuk_mv_log("vote failed (timeout)");
}

function cuk_mv_pass(idx)
{
    if (level.cuk_mv.changing)
        return;
    level.cuk_mv.changing = true;
    level.cuk_mv.active = false;
    level.cuk_mv.last_end = gettime();
    level notify("cuk_mv_ended");
    m = level.cuk_mv.options[idx];
    cuk_mv_bold_all("^2Vote passed!^7 Changing to ^5" + m.name + "^7 in 5 seconds");
    cuk_mv_log("vote passed -> " + m.code);
    wait 5;
    // carry the rotation on from the voted map, so the next game over doesn't
    // load whatever was queued before (it reloaded Moon right after a Moon vote)
    rest = cuk_mv_rotation_after(m.code);
    setdvar("sv_maprotationcurrent", rest);
    cuk_mv_log("rotation now: " + rest);
    setdvar("g_gametype", "zclassic");
    executecommand("map " + m.code);
}

// ---------------------------------------------------------------- game over -> next map
//
// When a game ends, BO3 shows the end screen and ~22 s later rotates to the next map itself.
// Players who stay connected through that rotation often crash on the load (the "GPU driver"
// error: 27 of 109 game-over rotations, 10 Oct), while the same carry-over through our own
// "map X" (a vote) almost never does (1 of 12). So at 18 s this does the change our way:
// the next map in the queue, the queue moved on, exactly what the engine would have loaded.

function cuk_mv_endgame()
{
    level waittill("end_game");
    wait level.cuk_mv.endgame_secs;
    if (level.cuk_mv.changing)
        return;
    level.cuk_mv.changing = true;
    code = cuk_mv_next_in_rotation();
    if (code == "")
    {
        cuk_mv_log("game over: no next map found, leaving it to the engine");
        return;
    }
    rest = cuk_mv_rotation_after(code);
    setdvar("sv_maprotationcurrent", rest);
    cuk_mv_log("game over -> " + code + " (rotation now: " + rest + ")");
    setdvar("g_gametype", "zclassic");
    executecommand("map " + code);
}

// the first "map X" still queued in sv_maprotationcurrent; when the queue is empty the rotation starts over
function cuk_mv_next_in_rotation()
{
    sources = array(getdvarstring("sv_maprotationcurrent"), getdvarstring("sv_maprotation"));
    for (s = 0; s < sources.size; s++)
    {
        tok = strtok(sources[s], " ");
        for (i = 0; i + 1 < tok.size; i++)
            if (tok[i] == "map")
                return tok[i + 1];
    }
    return "";
}

// the part of sv_maprotation after "map <code>" ("" when it is the last map: the rotation starts over)
function cuk_mv_rotation_after(code)
{
    rot = strtok(getdvarstring("sv_maprotation"), " ");
    rest = "";
    found = false;
    for (i = 0; i < rot.size; i++)
    {
        if (!found)
        {
            if (rot[i] == "map" && i + 1 < rot.size && rot[i + 1] == code)
            {
                found = true;
                i++;
            }
            continue;
        }
        if (rest != "")
            rest = rest + " ";
        rest = rest + rot[i];
    }
    return rest;
}

function cuk_mv_required()
{
    n = getplayers().size;
    if (n < 1)
        n = 1;
    return int(n / 2) + 1;
}

function cuk_mv_secs_left(since, length)
{
    left = int((length - (gettime() - since) + 999) / 1000);
    if (left < 1)
        left = 1;
    return left;
}

function cuk_mv_pname(player)
{
    if (isdefined(player) && isdefined(player.name))
        return player.name;
    return "Someone";
}

function cuk_mv_say_all(msg)
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
        if (isdefined(players[i]))
            players[i] iprintln(msg);
}

function cuk_mv_bold_all(msg)
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
        if (isdefined(players[i]))
            players[i] iprintlnbold(msg);
}

// ---------------------------------------------------------------- restart vote

function cuk_rv_start(player)
{
    if (level.cuk_mv.changing)
        return;
    if (level.cuk_rv.active)
    {
        cuk_rv_yes(player);
        return;
    }
    if (level.cuk_mv.active)
    {
        player iprintln("^3A map vote is running - finish that one first.");
        cuk_mv_log("  -> restart refused, map vote running");
        return;
    }
    if (level.cuk_rv.last_end > 0 && gettime() - level.cuk_rv.last_end < level.cuk_mv.cooldown_ms)
    {
        player iprintln("^3Restart vote cooldown. Try again in ^5" + cuk_mv_secs_left(level.cuk_rv.last_end, level.cuk_mv.cooldown_ms) + "^3 seconds.");
        cuk_mv_log("  -> restart cooldown");
        return;
    }
    if (isdefined(player.cuk_rv_started) && gettime() - player.cuk_rv_started < level.cuk_mv.player_cooldown_ms)
    {
        player iprintln("^3You started a restart vote recently. Try again in ^5" + cuk_mv_secs_left(player.cuk_rv_started, level.cuk_mv.player_cooldown_ms) + "^3 seconds.");
        cuk_mv_log("  -> restart player cooldown");
        return;
    }
    player.cuk_rv_started = gettime();
    level.cuk_rv.active = true;
    level.cuk_rv.yes = [];
    cuk_mv_bold_all("^3" + cuk_mv_pname(player) + "^7 wants to restart the map! Type ^5yes^7 to agree");
    cuk_mv_say_all("^3Restart vote:^7 need ^5" + cuk_mv_required() + "^7 votes, ^5" + level.cuk_mv.vote_secs + "^7 s");
    cuk_mv_log("  -> restart vote started, " + getplayers().size + " players");
    level thread cuk_rv_timeout();
    cuk_rv_yes(player);
}

function cuk_rv_yes(player)
{
    key = "" + player getentitynumber();
    if (isdefined(level.cuk_rv.yes[key]))
    {
        player iprintln("^3You already voted to restart.");
        return;
    }
    level.cuk_rv.yes[key] = true;
    votes = 0;
    players = getplayers();
    for (i = 0; i < players.size; i++)
        if (isdefined(level.cuk_rv.yes["" + players[i] getentitynumber()]))
            votes++;
    required = cuk_mv_required();
    cuk_mv_say_all("^5" + cuk_mv_pname(player) + "^7 voted to restart (^5" + votes + "^7/^5" + required + "^7)");
    cuk_mv_log("  -> restart yes " + votes + "/" + required);
    if (votes >= required)
        level thread cuk_rv_pass();
}

function cuk_rv_timeout()
{
    level endon("cuk_rv_ended");
    wait level.cuk_mv.vote_secs;
    if (!level.cuk_rv.active)
        return;
    level.cuk_rv.active = false;
    level.cuk_rv.last_end = gettime();
    level.cuk_rv.yes = [];
    cuk_mv_say_all("^3Restart vote failed^7 - not enough votes.");
    cuk_mv_log("restart vote failed");
}

function cuk_rv_pass()
{
    if (level.cuk_mv.changing)
        return;
    level.cuk_mv.changing = true;
    level.cuk_rv.active = false;
    level.cuk_rv.last_end = gettime();
    level notify("cuk_rv_ended");
    current = getdvarstring("mapname");
    cuk_mv_say_all("^2Vote passed!^7 Restarting the map in 5 seconds...");
    cuk_mv_log("restart vote passed -> " + current);
    wait 5;
    setdvar("g_gametype", "zclassic");
    executecommand("map " + current);
}
