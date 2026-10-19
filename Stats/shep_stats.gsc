// [Shep] BO3 zombies stats - port of T4RoundSaverNew + T4Speedrun + T4LiveRound for EZZ BOIII.
//
// All three BO3 servers share one install, so every file is kept per server port under
// boiii/scriptdata/cuk/<port>/ (writefile & co. are relative to boiii/scriptdata):
//   highrounds.txt    map|playercount|id:name;id:name|round        (same format as T4)
//   speedrun.txt      runId|map|kind|target|ms|players|id:name,...|port   (same format as T4)
//   currentround.txt  live round for the website
//   gamestats.txt     runId|map|round|reason|port|id|name|kills|headshots|downs|revives|bleedouts|points|joinRound|ms
//                     |box|perks|pap|powerups|powerupTypes
//                     (same format as T6GameStats.gsc; feeds the site's kills / revives / downs boards)
//                     box = paid box spins, perks = machine purchases, pap = Pack-a-Punch uses,
//                     powerupTypes = "nuke=2/full_ammo=1" (empty when none)
// Player id is the player's XUID (BO3 has no IW4MAdmin persistentClientId yet).
// Easter egg ("ee") timing is not wired up yet - rounds only.

autoexec function cuk_stats_init()
{
    level thread cuk_stats_main();
}

function cuk_stats_main()
{
    level.cuk_port = getdvarstring("net_port");
    level.cuk_dir = "cuk/" + level.cuk_port;
    level.cuk_map = getdvarstring("mapname");
    level.cuk_hr_file = level.cuk_dir + "/highrounds.txt";
    level.cuk_sr_file = level.cuk_dir + "/speedrun.txt";
    level.cuk_live_file = level.cuk_dir + "/currentround.txt";
    if (!directoryexists("cuk"))
        mkdir("cuk");
    if (!directoryexists(level.cuk_dir))
        mkdir(level.cuk_dir);

    cuk_hr_load();
    if (fileexists(level.cuk_hr_file))
        cuk_hr_save();   // writes back any ids converted from hex on load
    cuk_sr_init();

    level thread cuk_round_watch();
    level thread cuk_join_watch();
    cuk_ee_setup();
    level thread cuk_live_round();
    level thread cuk_live_clear("end_game");
    cuk_gs_main();
}

// ---------------------------------------------------------------- live round (same as T4LiveRound)
// currentround.txt: <round>|<players>|<port>|<hostname>|<mapname>, rewritten on every round change and
// at least once a minute (the site ignores files older than 150 s). Also mirrored to the cuk_round dvar.

function cuk_live_round()
{
    level endon("end_game");
    setdvar("cuk_round", "0");
    writefile(level.cuk_live_file, "");
    last = -1;
    since = 0;
    for (;;)
    {
        wait 1;
        since++;
        if (!isdefined(level.round_number))
            continue;
        if (level.round_number != last || since >= 60)
        {
            last = level.round_number;
            since = 0;
            writefile(level.cuk_live_file, level.round_number + "|" + getplayers().size + "|" + level.cuk_port + "|"
                + cuk_no_pipes(getdvarstring("live_steam_server_name")) + "|" + level.cuk_map + "\n");
            setdvar("cuk_round", "" + level.round_number);
        }
    }
}

// The server names contain "|" (e.g. "^3| Originals A"), which is the file's field separator.
function cuk_no_pipes(s)
{
    out = "";
    for (i = 0; i < s.size && i < 128; i++)
    {
        if (s[i] == "|")
            out += "-";
        else
            out += s[i];
    }
    return out;
}

function cuk_live_clear(note)
{
    level waittill(note);
    writefile(level.cuk_live_file, "");
    setdvar("cuk_round", "0");
}

// ---------------------------------------------------------------- shared helpers

function cuk_name(p)
{
    name = "Player";
    if (isdefined(p.name))
        name = p.name;
    out = "";
    for (i = 0; i < 64 && i < name.size; i++)
    {
        c = name[i];
        if (c != "|" && c != ":" && c != "," && c != ";")
            out += c;
    }
    if (out == "")
        out = "Player";
    return out;
}

// Player identity = XUID, the same id IW4MAdmin's BOIII parser uses as the client's NetworkId
// (status column "xuid"). Names can be changed freely in game, so they're only kept as a label;
// matching is always by this id. The sync to the stats site swaps it for the IW4MAdmin ClientId.
// No XUID -> "" and the caller leaves that player out rather than guess.
function cuk_id(p)
{
    id = p getxuid();
    if (!isdefined(id))
        return "";
    id = cuk_xuid_dec("" + id);
    if (id == "0")
        return "";
    return id;
}

// BO3 reports the XUID in hex (e.g. 0011000010abcdef). IW4MAdmin stores it as a 64-bit number, and
// the stats site only links numeric ids, so convert hex -> decimal with EZZ's int64 helpers.
// Already-decimal ids pass through unchanged.
function cuk_xuid_dec(x)
{
    x = tolower(x);
    // Already converted and >= 2^63: IW4MAdmin keeps NetworkIds as signed 64-bit, so these are
    // negative ("-1234567890123456789"). Keep them exactly as they are.
    if (getsubstr(x, 0, 1) == "-" && x.size > 1)
    {
        rest = getsubstr(x, 1, x.size);
        for (i = 0; i < rest.size; i++)
            if (!issubstr("0123456789", rest[i]))
                return "";
        return x;
    }
    if (getsubstr(x, 0, 2) == "0x")
        x = getsubstr(x, 2, x.size);
    hexdigits = "0123456789abcdef";
    vals = [];
    is_hex = false;
    for (i = 0; i < x.size && i < 32; i++)
    {
        v = -1;
        for (d = 0; d < 16; d++)
            if (hexdigits[d] == x[i])
                v = d;
        if (v < 0)
            return "";
        if (v > 9)
            is_hex = true;
        vals[vals.size] = v;
    }
    // BO3 XUIDs are 16 hex chars; a converted (decimal) id is longer and digits-only.
    if (!is_hex && x.size != 16)
        return x;
    acc = "0";
    for (i = 0; i < vals.size; i++)
    {
        acc = int64_op(acc, "*", "16");
        acc = int64_op(acc, "+", "" + vals[i]);
    }
    return "" + acc;
}

// Rewrites "id:name;id:name" blocks so any hex ids become decimal.
function cuk_fix_blocks(blocks, sep)
{
    if (blocks == "None")
        return blocks;
    parts = strtok(blocks, sep);
    out = "";
    for (i = 0; i < parts.size; i++)
    {
        b = strtok(parts[i], ":");
        if (b.size < 2)
            continue;
        if (out != "")
            out += sep;
        out += cuk_xuid_dec(b[0]) + ":" + b[1];
    }
    if (out == "")
        return "None";
    return out;
}

function cuk_say_all(msg)
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
        players[i] iprintln(msg);
}

function cuk_fmt_time(ms)
{
    total = int(ms / 1000);
    h = int(total / 3600);
    m = int((total % 3600) / 60);
    s = total % 60;
    if (h > 0)
        return h + ":" + cuk_pad(m) + ":" + cuk_pad(s);
    return m + ":" + cuk_pad(s);
}

function cuk_pad(n)
{
    if (n < 10)
        return "0" + n;
    return "" + n;
}

// ---------------------------------------------------------------- round watcher

function cuk_round_watch()
{
    level endon("end_game");
    last = -1;
    tick = 0;
    for (;;)
    {
        wait 0.05;
        tick++;
        if (isdefined(level.cuk_sr_start) && !isdefined(level.cuk_sr_invalid) && tick % 20 == 0)
            cuk_sr_roster();

        // An empty server sits on round 1 waiting for players. Don't take note of the round until someone
        // is on, or round 1 would be "seen" while empty and the speedrun clock would never start.
        if (!isdefined(level.round_number) || level.round_number == last || getplayers().size == 0)
            continue;
        last = level.round_number;

        if (last == 1 && !isdefined(level.cuk_sr_start) && getplayers().size > 0)
        {
            level.cuk_sr_start = gettime();
            level.cuk_sr_roster = [];
            level.cuk_sr_locked = false;
        }

        if (isdefined(level.cuk_sr_start) && !isdefined(level.cuk_sr_invalid))
        {
            cuk_sr_roster();
            // round 2 fixes the squad: whoever left during round 1 is not part of it
            if (last >= 2 && !level.cuk_sr_locked)
            {
                cuk_sr_prune();
                level.cuk_sr_locked = true;
            }
            if (cuk_sr_is_milestone(last))
                cuk_sr_log("round", "" + last);
        }

        // a new round has started: the record is the round reached (same as T4RoundSaverNew)
        if (last >= 2)
            cuk_hr_check(last);
    }
}

// ---------------------------------------------------------------- high rounds

function cuk_hr_load()
{
    level.cuk_hr = [];
    for (i = 1; i <= 4; i++)
    {
        level.cuk_hr[i] = spawnstruct();
        level.cuk_hr[i].round = 0;
        level.cuk_hr[i].players = "None";
    }
    level.cuk_hr_other = [];   // lines for the other maps in the rotation, kept as-is
    if (!fileexists(level.cuk_hr_file))
        return;
    lines = strtok(readfile(level.cuk_hr_file), "\n");
    for (i = 0; i < lines.size; i++)
    {
        line = lines[i];
        parts = strtok(line, "|");
        if (parts.size != 4)
            continue;
        if (parts[0] != level.cuk_map)
        {
            level.cuk_hr_other[level.cuk_hr_other.size] = line;
            continue;
        }
        n = int(parts[1]);
        if (n < 1 || n > 4)
            continue;
        level.cuk_hr[n].players = cuk_fix_blocks(parts[2], ";");
        level.cuk_hr[n].round = int(parts[3]);
        if (level.cuk_hr[n].players == "None")
            level.cuk_hr[n].round = 0;   // a round with nobody on it isn't a record
    }
}

function cuk_hr_save()
{
    out = "";
    for (i = 0; i < level.cuk_hr_other.size; i++)
        out += level.cuk_hr_other[i] + "\n";
    for (n = 1; n <= 4; n++)
    {
        r = level.cuk_hr[n].round;
        if (level.cuk_hr[n].players == "None")
            r = 0;
        out += level.cuk_map + "|" + n + "|" + level.cuk_hr[n].players + "|" + r + "\n";
    }
    writefile(level.cuk_hr_file, out);
}

function cuk_hr_names(blocks)
{
    if (blocks == "None")
        return "None";
    out = "";
    parts = strtok(blocks, ";");
    for (i = 0; i < parts.size; i++)
    {
        b = strtok(parts[i], ":");
        if (b.size < 2)
            continue;
        if (out != "")
            out += "^7, ^5";
        out += b[1];
    }
    return out;
}

function cuk_hr_check(rnd)
{
    players = getplayers();
    n = players.size;
    if (n < 1 || n > 4)
        return;
    if (rnd <= level.cuk_hr[n].round)
        return;
    blocks = "";
    for (i = 0; i < n; i++)
    {
        // A record lists everyone it counts for: if someone has no id yet, skip this round
        // rather than save an n-player record with a name missing.
        id = cuk_id(players[i]);
        if (id == "")
            return;
        if (blocks != "")
            blocks += ";";
        blocks += id + ":" + cuk_name(players[i]);
    }
    if (blocks == "")
        return;
    level.cuk_hr[n].round = rnd;
    level.cuk_hr[n].players = blocks;
    cuk_hr_save();
    cuk_say_all("Record Broken! ^5" + n + "-Player^7: ^5" + cuk_hr_names(blocks) + "^7 just hit round ^5" + rnd + "^7!");
}

function cuk_join_watch()
{
    level thread cuk_stats_sweep();
    for (;;)
    {
        level waittill("connected", player);
        player cuk_stats_hook();
    }
}

// EZZ BOIII can miss the "connected" notify for players who carry over a map change, so this
// safety net hooks anyone on the server who has no listener yet (once per player, via the flag).
function cuk_stats_sweep()
{
    for (;;)
    {
        wait 2;
        players = getplayers();
        for (i = 0; i < players.size; i++)
            if (isdefined(players[i]))
                players[i] cuk_stats_hook();
    }
}

function cuk_stats_hook()
{
    if (isdefined(self.cuk_stats_hooked))
        return;
    self.cuk_stats_hooked = true;
    self thread cuk_show_records();
    self thread cuk_records_chat();
}

// .record / .records in chat shows this map's high rounds (EZZ BOIII: self waittill("chat", text)).
function cuk_records_chat()
{
    self endon("disconnect");
    for (;;)
    {
        self waittill("chat", text);
        t = tolower("" + text);
        while (t != "" && getsubstr(t, 0, 1) == " ")
            t = getsubstr(t, 1, t.size);
        if (t == ".record" || t == ".records")
            self thread cuk_show_records_now();
    }
}

function cuk_show_records_now()
{
    self endon("disconnect");
    self iprintln("--- High Rounds for this Map ---");
    for (n = 1; n <= 4; n++)
    {
        wait 1;
        if (level.cuk_hr[n].round > 0)
            self iprintln("^5" + n + "-Player^7: Round ^5" + level.cuk_hr[n].round + "^7 by ^5" + cuk_hr_names(level.cuk_hr[n].players));
        else
            self iprintln("^5" + n + "-Player^7: No record set.");
    }
}

function cuk_show_records()
{
    self endon("disconnect");
    wait 10;
    self iprintln("--- High Rounds for this Map ---");
    for (n = 1; n <= 4; n++)
    {
        wait 1;
        if (level.cuk_hr[n].round > 0)
            self iprintln("^5" + n + "-Player^7: Round ^5" + level.cuk_hr[n].round + "^7 by ^5" + cuk_hr_names(level.cuk_hr[n].players));
        else
            self iprintln("^5" + n + "-Player^7: No record set.");
    }
}

// ---------------------------------------------------------------- easter eggs
// Logged as speedrun lines with kind "ee" and a token the stats site has a label for. Signals come from
// the maps' own scripts (decompiled BO3 source, see site-work\ee_research.md); all are plain flags or
// notifies, so nothing is hooked or replaced. Each egg logs once per game, only for a valid timed run.

function cuk_ee_setup()
{
    m = level.cuk_map;
    // main quests: ("flag", name) = poll level.flag[name]; ("notify", name) = level waittill(name)
    if (m == "zm_zod")        level thread cuk_ee_flag("shadows_main_quest", "ee_complete");
    if (m == "zm_castle")     level thread cuk_ee_flag("eisendrache_main_quest", "boss_fight_completed");
    if (m == "zm_island")     level thread cuk_ee_flag("zetsubou_main_quest", "flag_play_outro_cutscene");
    if (m == "zm_stalingrad") level thread cuk_ee_flag("gorod_main_quest", "nikolai_complete");
    if (m == "zm_genesis")    level thread cuk_ee_flag("revelations_main_quest", "final_boss_defeated");
    if (m == "zm_cosmodrome") level thread cuk_ee_flag("casimir_mechanism", "weapons_combined");
    if (m == "zm_tomb")       level thread cuk_ee_notify("little_lost_girl", "tomb_sidequest_complete");
    if (m == "zm_moon")       level thread cuk_ee_notify("big_bang_theory", "moon_sidequest_big_bang_achieved");
    if (m == "zm_temple")     level thread cuk_ee_notify("time_travel_will_tell", "temple_sidequest_achieved");
    if (m == "zm_factory")    level thread cuk_ee_flytrap();
    if (m == "zm_daybreak")   level thread cuk_ee_notify("daybreak_main_quest", "ee_step_6");   // flag::set notifies the flag name

    // songs: level.musicsystem.currentstate holds the song's music state while it plays
    level.cuk_songs = [];
    if (m == "zm_zod")        cuk_song("snakeskinboots", "song_snakeskin_boots");
    if (m == "zm_factory")    cuk_song("musicEasterEgg", "song_beauty_of_annihilation");
    if (m == "zm_castle")   { cuk_song("dead_again", "song_dead_again"); cuk_song("requiem", "song_requiem"); }
    if (m == "zm_island")     cuk_song("dead_flowers", "song_dead_flowers");
    if (m == "zm_stalingrad") { cuk_song("dead_ended", "song_dead_ended"); cuk_song("ace_of_spades", "song_ace_of_spades"); }
    if (m == "zm_genesis")    cuk_song("the_gift", "song_the_gift");
    if (m == "zm_tomb")     { cuk_song("archangel", "song_archangel"); cuk_song("aether", "song_aether"); cuk_song("shepherd_of_fire", "song_shepherd_of_fire"); }
    if (m == "zm_moon")       cuk_song("cominghome", "song_coming_home");
    if (m == "zm_temple")     cuk_song("pareidolia", "song_pareidolia");
    if (m == "zm_cosmodrome") { cuk_song("abracadavre", "song_abracadavre"); cuk_song("not_ready_to_die", "song_not_ready_to_die"); }
    if (m == "zm_theater")    cuk_song("115", "song_115");
    if (m == "zm_sumpf")      cuk_song("the_one", "song_the_one");
    if (m == "zm_asylum")     cuk_song("lullaby_for_a_dead_man", "song_lullaby_of_a_dead_man");
    if (m == "zm_prototype")  cuk_song("undone", "song_undone");
    if (level.cuk_songs.size > 0)
        level thread cuk_ee_songs();
}

function cuk_song(state, token)
{
    s = spawnstruct();
    s.state = state;
    s.token = token;
    s.done = false;
    level.cuk_songs[level.cuk_songs.size] = s;
}

function cuk_flag_set(name)
{
    return isdefined(level.flag) && isdefined(level.flag[name]) && level.flag[name];
}

function cuk_ee_flag(token, flagname)
{
    level endon("end_game");
    while (!cuk_flag_set(flagname))
        wait 0.25;
    cuk_ee_done(token);
}

function cuk_ee_notify(token, note)
{
    level endon("end_game");
    level waittill(note);
    cuk_ee_done(token);
}

// The Giant's Fly Trap: all three targets shot -> the prize spawns.
function cuk_ee_flytrap()
{
    level endon("end_game");
    while (!(cuk_flag_set("ee_exp_monkey") && cuk_flag_set("ee_bowie_bear") && cuk_flag_set("ee_perk_bear")))
        wait 0.25;
    cuk_ee_done("fly_trap");
}

function cuk_ee_songs()
{
    level endon("end_game");
    for (;;)
    {
        wait 0.25;
        if (!isdefined(level.musicsystem) || !isdefined(level.musicsystem.currentstate))
            continue;
        cur = level.musicsystem.currentstate;
        for (i = 0; i < level.cuk_songs.size; i++)
        {
            s = level.cuk_songs[i];
            if (!s.done && cur == s.state)
            {
                s.done = true;
                cuk_ee_done(s.token);
            }
        }
    }
}

function cuk_ee_done(token)
{
    if (!isdefined(level.cuk_ee_logged))
        level.cuk_ee_logged = [];
    if (isdefined(level.cuk_ee_logged[token]))
        return;
    level.cuk_ee_logged[token] = true;
    if (isdefined(level.cuk_sr_start) && !isdefined(level.cuk_sr_invalid))
    {
        cuk_sr_roster();
        cuk_sr_log("ee", token);
    }
}

// ---------------------------------------------------------------- speedruns

function cuk_sr_init()
{
    level.cuk_sr_run = randomint(1000000) + "-" + gettime();
    level.cuk_sr_milestones = array(10, 20, 30, 40, 50, 70, 100);
    if (!fileexists(level.cuk_sr_file))
        appendfile(level.cuk_sr_file, level.cuk_sr_run + "|" + level.cuk_map + "|boot|0|0|0||" + level.cuk_port + "\n");
}

function cuk_sr_is_milestone(rnd)
{
    for (i = 0; i < level.cuk_sr_milestones.size; i++)
        if (level.cuk_sr_milestones[i] == rnd)
            return true;
    return false;
}

function cuk_sr_prune()
{
    players = getplayers();
    kept = [];
    for (r = 0; r < level.cuk_sr_roster.size; r++)
    {
        for (i = 0; i < players.size; i++)
        {
            if (isdefined(players[i]) && cuk_id(players[i]) == level.cuk_sr_roster[r].id)
            {
                kept[kept.size] = level.cuk_sr_roster[r];
                break;
            }
        }
    }
    level.cuk_sr_roster = kept;
}

function cuk_sr_roster()
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
    {
        p = players[i];
        if (!isdefined(p) || !isdefined(p.name))
            continue;
        id = cuk_id(p);
        if (id == "")
            continue;
        slot = -1;
        for (r = 0; r < level.cuk_sr_roster.size; r++)
            if (level.cuk_sr_roster[r].id == id)
                slot = r;
        if (slot < 0)
        {
            if (level.cuk_sr_locked)
            {
                level.cuk_sr_invalid = true;
                cuk_say_all("^3Speedrun timing ended - a new player joined after round 1");
                return;
            }
            slot = level.cuk_sr_roster.size;
            level.cuk_sr_roster[slot] = spawnstruct();
            level.cuk_sr_roster[slot].id = id;
        }
        level.cuk_sr_roster[slot].name = cuk_name(p);
    }
}

function cuk_sr_log(kind, target)
{
    elapsed = gettime() - level.cuk_sr_start;
    if (isdefined(level.cuk_sr_invalid) || level.cuk_sr_roster.size == 0)
        return;
    blocks = "";
    for (i = 0; i < level.cuk_sr_roster.size; i++)
    {
        if (blocks != "")
            blocks += ",";
        blocks += level.cuk_sr_roster[i].id + ":" + level.cuk_sr_roster[i].name;
    }
    appendfile(level.cuk_sr_file, level.cuk_sr_run + "|" + level.cuk_map + "|" + kind + "|" + target + "|" + elapsed + "|" + level.cuk_sr_roster.size + "|" + blocks + "|" + level.cuk_port + "\n");
    if (kind == "ee")
        cuk_say_all("^7Easter egg in ^2" + cuk_fmt_time(elapsed));
    else
        cuk_say_all("^7Round " + target + " in ^2" + cuk_fmt_time(elapsed));
}

// ---------------------------------------------------------------- game stats (port of T5GameStats.gsc)
// One gamestats.txt line per player session: written when they leave ("left"), and for everyone still
// in when the game ends ("end"), so each session counts once. A bled-out player turns spectator until
// the next round, which is how bleed-outs are counted. Sessions under 30 s with no kills are skipped.

function cuk_gs_main()
{
    level.cuk_gs_file = level.cuk_dir + "/gamestats.txt";
    level.cuk_gs_sessions = [];
    level thread cuk_gs_watch_players();
    level thread cuk_gs_watch_end();
    level thread cuk_gs_watch_drops();
}

function cuk_gs_round()
{
    if (isdefined(level.round_number))
        return level.round_number;
    return 0;
}

function cuk_gs_over()
{
    if (isdefined(level.cuk_gs_ended))
        return true;
    return isdefined(level.intermission) && level.intermission;
}

function cuk_gs_watch_players()
{
    level endon("end_game");
    for (;;)
    {
        players = getplayers();
        for (i = 0; i < players.size; i++)
        {
            if (isdefined(players[i]) && !isdefined(players[i].cuk_gs))
                players[i] thread cuk_gs_track();
        }
        wait 1;
    }
}

function cuk_gs_track()
{
    s = spawnstruct();
    s.join_round = cuk_gs_round();
    s.join_time = gettime();
    s.bleedouts = 0;
    s.box = 0;
    s.perks = 0;
    s.pap = 0;
    s.powerups = 0;
    s.powerup_types = [];
    s.written = false;
    s.left = false;
    self.cuk_gs = s;
    level.cuk_gs_sessions[level.cuk_gs_sessions.size] = s;

    self thread cuk_gs_watch_bleedouts(s);
    self thread cuk_gs_watch_leave(s);
    self thread cuk_gs_watch_perks(s);

    // keep a copy of the numbers: the entity is gone by the time "disconnect" arrives
    self endon("disconnect");
    for (;;)
    {
        cuk_gs_snapshot(self, s);
        wait 1;
    }
}

function cuk_gs_watch_bleedouts(s)
{
    self endon("disconnect");
    last = "";
    for (;;)
    {
        state = "";
        if (isdefined(self.sessionstate))
            state = self.sessionstate;
        // only "playing" -> "spectator": a mid-round joiner starts as a spectator
        if (state == "spectator" && last == "playing" && !cuk_gs_over())
            s.bleedouts++;
        last = state;
        wait 0.25;
    }
}

// "perk_purchased" is sent to the buyer when they pay at a machine, so free perks (power-up, gums,
// perks given back after last stand) aren't counted.
function cuk_gs_watch_perks(s)
{
    self endon("disconnect");
    for (;;)
    {
        self waittill("perk_purchased", perk);
        s.perks++;
    }
}

// Every dropped power-up is watched until someone grabs it or it goes. The game names the grabber
// (power_up_grab_player) 0.1 s before hiding it, so a 0.05 s check sees it.
function cuk_gs_watch_drops()
{
    level endon("end_game");
    for (;;)
    {
        level waittill("powerup_dropped", powerup);
        if (isdefined(powerup))
            powerup thread cuk_gs_watch_drop();
    }
}

function cuk_gs_watch_drop()
{
    while (isdefined(self) && !isdefined(self.power_up_grab_player))
        wait 0.05;
    if (!isdefined(self))
        return;
    p = self.power_up_grab_player;
    if (!isdefined(p) || !isdefined(p.cuk_gs))
        return;
    name = "other";
    if (isdefined(self.powerup_name))
        name = cuk_gs_token(self.powerup_name);
    if (cuk_gs_map_item(name))
        return;
    s = p.cuk_gs;
    s.powerups++;
    if (!isdefined(s.powerup_types[name]))
        s.powerup_types[name] = 0;
    s.powerup_types[name] = s.powerup_types[name] + 1;
}

// A power-up name as a safe token for the line format.
function cuk_gs_token(name)
{
    name = "" + name;
    out = "";
    for (i = 0; i < 32 && i < name.size; i++)
    {
        c = name[i];
        if (c != "|" && c != ":" && c != "," && c != ";" && c != "=" && c != "/")
            out += c;
    }
    if (out == "")
        return "other";
    return out;
}

// Quest items some maps drop through the power-up system (Der Eisendrache's
// tram fuse, Zetsubou's seeds, Revelations' code cylinders, the rune
// pieces, Shadows' beast mana) are not power-ups, so they are not counted.
function cuk_gs_map_item(name)
{
    if (name == "castle_tram_token" || name == "island_seed" || name == "beast_mana")
        return true;
    if (issubstr(name, "code_cylinder") || issubstr(name, "demonic_rune"))
        return true;
    return false;
}

function cuk_gs_powerup_types(s)
{
    out = "";
    names = getarraykeys(s.powerup_types);
    for (i = 0; i < names.size; i++)
    {
        if (out != "")
            out += "/";
        out += names[i] + "=" + s.powerup_types[names[i]];
    }
    return out;
}

function cuk_gs_watch_leave(s)
{
    self waittill("disconnect");
    if (!s.written && !cuk_gs_over())
        cuk_gs_write(s, "left");
}

function cuk_gs_watch_end()
{
    level waittill("end_game");
    level.cuk_gs_ended = true;
    players = getplayers();
    for (i = 0; i < players.size; i++)
    {
        if (isdefined(players[i]) && isdefined(players[i].cuk_gs))
            cuk_gs_snapshot(players[i], players[i].cuk_gs);
    }
    for (i = 0; i < level.cuk_gs_sessions.size; i++)
    {
        s = level.cuk_gs_sessions[i];
        if (!s.written && !s.left)
            cuk_gs_write(s, "end");
    }
}

// BO3 keeps the scoreboard numbers in self.pers; the entity fields are the fallback.
function cuk_gs_stat(p, key, field)
{
    if (isdefined(p.pers) && isdefined(p.pers[key]))
        return int(p.pers[key]);
    if (isdefined(field))
        return int(field);
    return 0;
}

function cuk_gs_snapshot(p, s)
{
    if (isdefined(p.name))
        s.name = cuk_name(p);
    if (!isdefined(s.id))
    {
        id = cuk_id(p);
        if (id != "")
            s.id = id;
    }
    s.kills = cuk_gs_stat(p, "kills", p.kills);
    s.headshots = cuk_gs_stat(p, "headshots", p.headshots);
    s.downs = cuk_gs_stat(p, "downs", p.downs);
    s.revives = cuk_gs_stat(p, "revives", p.revives);
    s.box = cuk_gs_stat(p, "use_magicbox", undefined);
    s.pap = cuk_gs_stat(p, "use_pap", undefined);
    if (isdefined(p.score_total))
        s.points = int(p.score_total);
    else if (isdefined(p.score))
        s.points = int(p.score);
    else
        s.points = 0;
    s.last_seen = gettime();
}

function cuk_gs_write(s, reason)
{
    s.written = true;
    if (reason == "left")
        s.left = true;
    if (!isdefined(s.last_seen) || !isdefined(s.name) || !isdefined(s.id))
        return;
    ms = s.last_seen - s.join_time;
    if (ms < 30000 && s.kills == 0)
        return;
    appendfile(level.cuk_gs_file, level.cuk_sr_run + "|" + level.cuk_map + "|" + cuk_gs_round() + "|" + reason + "|"
        + level.cuk_port + "|" + s.id + "|" + s.name + "|" + s.kills + "|" + s.headshots + "|" + s.downs + "|"
        + s.revives + "|" + s.bleedouts + "|" + s.points + "|" + s.join_round + "|" + ms + "|" + s.box + "|"
        + s.perks + "|" + s.pap + "|" + s.powerups + "|" + cuk_gs_powerup_types(s) + "\n");
}
