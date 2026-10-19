// [Shep] Round locker for BO3 zombies (EZZ BOIII) - port of T4RoundLocker.gsc, same rules as WaW/BO1/BO2:
//
//   .lock      from round 1 starts a lock vote; a majority of the players on locks the server
//   !lock      (a solo player locks it straight away). Votes stay open 60 s, 5-minute cooldown.
//   round 20   the server locks itself regardless.
//
// Locking sets a random 4-digit join password (g_password); it clears when the game ends or the
// next map loads. Chat arrives per player:  self waittill("chat", text)  (EZZ BOIII).
//
// Feedback: vote start / pass / fail go to the middle of the screen (iprintlnbold), progress shows
// votes, votes needed and seconds left, and a red "LOCKED" tag sits next to the HUD panel while
// locked. Voters who leave are dropped, and every disconnect re-checks an open vote (the majority
// shrinks with the lobby). The tag's settext() runs once per player, so no configstring leak.

// Every HUD string, registered in one fixed order before anything else on every map. A player who
// carries over a map change (map vote, .restart) keeps the last map's text table, so if two strings
// swapped slots the old text shows: Verruckt drew "DOGS" in the LOCKED tag (10 Oct). The same list
// sits at the top of cuk_hud, cuk_lock and cuk_afk; whichever init runs first registers it.
function cuk_lock_strings()
{
    if (isdefined(level.cuk_hud_strings_done))
        return;
    level.cuk_hud_strings_done = true;
    e = newhudelem();
    e.alpha = 0;
    strings = array("RUN", "R", ":0", ":", "ZOMBIES", "DOGS", "LOCKED", "AFK");
    for (i = 0; i < strings.size; i++)
        e settext(strings[i]);
    e destroy();
}

autoexec function cuk_lock_init()
{
    cuk_lock_strings();
    level.cuk_lock = spawnstruct();
    level.cuk_lock.min_round = 1;
    level.cuk_lock.force_round = 20;
    level.cuk_lock.vote_secs = 60;
    level.cuk_lock.cooldown_ms = 300000;
    level.cuk_lock.locked = false;
    level.cuk_lock.pin = "";
    level.cuk_lock.vote_active = false;
    level.cuk_lock.vote_end = 0;
    level.cuk_lock.voters = [];
    level.cuk_lock.last_vote = 0;

    setdvar("g_password", "");

    level thread cuk_lock_force_monitor();
    level thread cuk_lock_connect();
    level thread cuk_lock_reset_on("end_game");
}

function cuk_lock_connect()
{
    level thread cuk_lock_sweep();
    for (;;)
    {
        level waittill("connected", player);
        player cuk_lock_hook();
    }
}

// EZZ BOIII can miss the "connected" notify for players who carry over a map change, so this
// safety net hooks anyone on the server who has no listener yet (once per player, via the flag).
function cuk_lock_sweep()
{
    for (;;)
    {
        wait 2;
        players = getplayers();
        for (i = 0; i < players.size; i++)
            if (isdefined(players[i]))
                players[i] cuk_lock_hook();
    }
}

function cuk_lock_hook()
{
    if (isdefined(self.cuk_lock_hooked))
        return;
    self.cuk_lock_hooked = true;
    self thread cuk_lock_chat();
    self thread cuk_lock_on_disconnect();
    self thread cuk_lock_tag_build();
}

function cuk_lock_chat()
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
        if (t == ".lock" || t == "!lock")
            cuk_lock_vote(self);
        else if (t == ".unlock" || t == "!unlock")
            self iprintln("^3Server lock clears automatically at game end.");
    }
}

function cuk_lock_force_monitor()
{
    level endon("end_game");
    for (;;)
    {
        wait 1;
        if (!level.cuk_lock.locked && isdefined(level.round_number) && level.round_number >= level.cuk_lock.force_round)
            cuk_lock_server("round");
    }
}

function cuk_lock_vote(player)
{
    if (level.cuk_lock.locked)
    {
        player iprintlnbold("^1Server is already locked^7 until game end.");
        return;
    }
    if (!isdefined(level.round_number) || level.round_number < level.cuk_lock.min_round)
    {
        player iprintln("^3Lock voting is available from round ^5" + level.cuk_lock.min_round);
        return;
    }
    if (!level.cuk_lock.vote_active)
    {
        if (level.cuk_lock.last_vote > 0 && gettime() - level.cuk_lock.last_vote < level.cuk_lock.cooldown_ms)
        {
            remaining = int((level.cuk_lock.cooldown_ms - (gettime() - level.cuk_lock.last_vote) + 999) / 1000);
            player iprintlnbold("^3Lock vote cooldown: try again in ^5" + remaining + "^3 s");
            return;
        }
        level.cuk_lock.vote_active = true;
        level.cuk_lock.last_vote = gettime();
        level.cuk_lock.vote_end = gettime() + level.cuk_lock.vote_secs * 1000;
        level.cuk_lock.voters = [];
        level.cuk_lock.voters[0] = player;
        required = cuk_lock_required();
        if (1 >= required)
        {
            cuk_lock_server("vote");
            return;
        }
        cuk_lock_bold_all("^3Lock vote^7 started by ^5" + cuk_lock_name(player) + "^7 - type ^5.lock^7 to vote");
        cuk_lock_say_all("^2Lock vote: ^51^7/^5" + required + "^7 votes, ^5" + level.cuk_lock.vote_secs + "^7 s left");
        player iprintln("^2Your lock vote counted.");
        level thread cuk_lock_vote_timeout();
        level thread cuk_lock_vote_reminder();
        return;
    }
    cuk_lock_prune();
    for (i = 0; i < level.cuk_lock.voters.size; i++)
    {
        if (level.cuk_lock.voters[i] == player)
        {
            player iprintln("^3You already voted to lock (^5" + level.cuk_lock.voters.size + "^3/^5" + cuk_lock_required() + "^3, ^5" + cuk_lock_secs_left() + "^3 s left).");
            return;
        }
    }
    level.cuk_lock.voters[level.cuk_lock.voters.size] = player;
    player iprintln("^2Your lock vote counted.");
    cuk_lock_check("vote");
}

// Pass the vote if the (pruned) voters are a majority of the players on now; otherwise show progress.
function cuk_lock_check(why)
{
    if (!level.cuk_lock.vote_active || level.cuk_lock.locked)
        return;
    cuk_lock_prune();
    votes = level.cuk_lock.voters.size;
    required = cuk_lock_required();
    if (votes > 0 && votes >= required)
    {
        cuk_lock_server("vote");
        return;
    }
    if (votes == 0)
    {
        cuk_lock_fail(votes, required);
        return;
    }
    cuk_lock_say_all("^2Lock vote: ^5" + votes + "^7/^5" + required + "^7 votes, ^5" + cuk_lock_secs_left() + "^7 s left");
}

// Drop voters who have left (their entity is gone, or they are no longer in the player list).
function cuk_lock_prune()
{
    players = getplayers();
    kept = [];
    for (i = 0; i < level.cuk_lock.voters.size; i++)
    {
        v = level.cuk_lock.voters[i];
        if (!isdefined(v))
            continue;
        for (j = 0; j < players.size; j++)
        {
            if (isdefined(players[j]) && players[j] == v)
            {
                kept[kept.size] = v;
                break;
            }
        }
    }
    level.cuk_lock.voters = kept;
}

function cuk_lock_on_disconnect()
{
    self waittill("disconnect");
    level thread cuk_lock_recheck_soon();
}

function cuk_lock_recheck_soon()
{
    level endon("end_game");
    wait 0.5;   // let the leaver drop out of getplayers()
    cuk_lock_check("disconnect");
}

function cuk_lock_vote_timeout()
{
    level endon("end_game");
    level endon("cuk_lock_vote_ended");
    wait level.cuk_lock.vote_secs;
    if (!level.cuk_lock.vote_active || level.cuk_lock.locked)
        return;
    cuk_lock_prune();
    cuk_lock_fail(level.cuk_lock.voters.size, cuk_lock_required());
}

function cuk_lock_vote_reminder()
{
    level endon("end_game");
    level endon("cuk_lock_vote_ended");
    wait level.cuk_lock.vote_secs - 30;
    if (!level.cuk_lock.vote_active || level.cuk_lock.locked)
        return;
    cuk_lock_prune();
    cuk_lock_say_all("^3Lock vote: ^5" + level.cuk_lock.voters.size + "^7/^5" + cuk_lock_required() + "^7 votes, ^530^7 s left - type ^5.lock");
}

function cuk_lock_fail(votes, required)
{
    level.cuk_lock.vote_active = false;
    level.cuk_lock.voters = [];
    level notify("cuk_lock_vote_ended");
    cuk_lock_bold_all("^1Lock vote failed^7 (^5" + votes + "^7/^5" + required + "^7 votes)");
}

function cuk_lock_server(reason)
{
    if (level.cuk_lock.locked)
        return;
    level.cuk_lock.locked = true;
    pin = "";
    for (i = 0; i < 4; i++)
        pin += randomint(10);
    level.cuk_lock.pin = pin;
    level.cuk_lock.vote_active = false;
    level.cuk_lock.voters = [];
    level notify("cuk_lock_vote_ended");
    setdvar("g_password", pin);
    if (reason == "round")
        cuk_lock_bold_all("^1Server Locked^7 - round ^5" + level.cuk_lock.force_round + "^7 reached, clears at game end");
    else
        cuk_lock_bold_all("^1Server Locked^7 - vote passed, clears at game end");
    level notify("cuk_lock_changed");
}

function cuk_lock_reset_on(note)
{
    level waittill(note);
    setdvar("g_password", "");
    level.cuk_lock.locked = false;
    level.cuk_lock.pin = "";
    level.cuk_lock.vote_active = false;
    level.cuk_lock.voters = [];
    level notify("cuk_lock_vote_ended");
    level notify("cuk_lock_changed");
}

function cuk_lock_required()
{
    n = getplayers().size;
    if (n < 1)
        n = 1;
    return int(n / 2) + 1;
}

function cuk_lock_secs_left()
{
    s = int((level.cuk_lock.vote_end - gettime() + 999) / 1000);
    if (s < 0)
        s = 0;
    return s;
}

function cuk_lock_name(player)
{
    if (isdefined(player) && isdefined(player.name))
        return player.name;
    return "Someone";
}

function cuk_lock_say_all(msg)
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
        if (isdefined(players[i]))
            players[i] iprintln(msg);
}

function cuk_lock_bold_all(msg)
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
        if (isdefined(players[i]))
            players[i] iprintlnbold(msg);
}

// ---------------------------------------------------------------- LOCKED tag (right of the cuk_hud panel)

function cuk_lock_tag_build()
{
    self endon("disconnect");
    if (!isdefined(self.sessionstate) || self.sessionstate != "playing")
        self waittill("spawned_player");   // a player hooked late by the sweep may already be in
    if (isdefined(self.cuk_lock_tag))
        return;
    e = newclienthudelem(self);
    e.foreground = 1;
    e.hidewhendead = 0;
    e.hidewheninmenu = 1;
    e.horzalign = "left";
    e.vertalign = "top";
    e.alignx = "left";
    e.aligny = "top";
    e.x = 112;      // cuk_hud panel: x 20, width 84 + 4 px accent
    e.y = 26;
    e.fontscale = 1.0;
    e.color = (1, 0.15, 0.15);
    e.sort = 7;
    e settext("LOCKED");
    e.alpha = 0;
    self.cuk_lock_tag = e;
    self thread cuk_lock_tag_cleanup(e);
    for (;;)
    {
        a = 0;
        if (level.cuk_lock.locked)
            a = 1;
        if (e.alpha != a)
        {
            e fadeovertime(0.3);
            e.alpha = a;
        }
        level waittill("cuk_lock_changed");
    }
}

function cuk_lock_tag_cleanup(e)
{
    self waittill("disconnect");
    if (isdefined(e))
        e destroy();
}
