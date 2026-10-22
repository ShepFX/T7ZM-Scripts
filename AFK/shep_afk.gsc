// [Shep] AFK system for BO3 zombies (EZZ BOIII) - port of t4_zm_afk.gsc.
//
// Type .afk in chat to toggle AFK. Rules (same as WaW):
//   - round 20+, 45-minute cooldown between uses
//   - 1-minute countdown first; cancelled by taking damage, going down, dying or being teleported
//   - while AFK (max 15 min): held at spawn, weapons off, can't move, godmode, zombies ignore you,
//     points frozen; 30 s of invulnerability after coming back
//   - if every player is AFK the round pauses (the idle-zombie failsafe is switched off so the
//     zombies alive stay alive and the round can't end)
// EZZ BOIII sends every chat line to the player as  self waittill("chat", text).
// HUD: only fixed strings ("AFK") + a client-side settimer countdown, so nothing accumulates.

// Every HUD string, registered in one fixed order before anything else on every map. A player who
// carries over a map change (map vote, .restart) keeps the last map's text table, so if two strings
// swapped slots the old text shows: Verruckt drew "DOGS" in the LOCKED tag (10 Oct). The same list
// sits at the top of cuk_hud, cuk_lock and cuk_afk; whichever init runs first registers it.
function cuk_afk_strings()
{
    if (isdefined(level.cuk_hud_strings_done))
        return;
    level.cuk_hud_strings_done = true;
    e = newhudelem();
    e.alpha = 0;
    strings = array("RUN", "R", ":0", ":", "ZOMBIES", "DOGS", "LOCKED", "AFK", "ROUND", "ALIVE");
    for (i = 0; i < strings.size; i++)
        e settext(strings[i]);
    e destroy();
}

autoexec function cuk_afk_init()
{
    cuk_afk_strings();
    level.afk_system = spawnstruct();
    level.afk_system.min_round = 20;
    level.afk_system.cooldown_ms = 2700000;   // 45 minutes
    level.afk_system.duration_s = 900;        // 15 minutes
    level.afk_system.activation_delay_s = 60; // anti-panic delay
    level.afk_system.round_frozen = false;
    level.afk_system.saved_use_failsafe = undefined;
    level.afk_system.verified_spawn = undefined;

    level thread cuk_afk_connect();
    level thread cuk_afk_freeze_monitor();
}

// ---------------------------------------------------------------- players & chat

function cuk_afk_connect()
{
    level thread cuk_afk_sweep();
    for (;;)
    {
        level waittill("connected", player);
        player cuk_afk_hook();
    }
}

// EZZ BOIII can miss the "connected" notify for players who carry over a map change, so this
// safety net hooks anyone on the server who has no listener yet (once per player, via the flag).
function cuk_afk_sweep()
{
    for (;;)
    {
        wait 2;
        players = getplayers();
        for (i = 0; i < players.size; i++)
            if (isdefined(players[i]))
                players[i] cuk_afk_hook();
    }
}

function cuk_afk_hook()
{
    if (isdefined(self.cuk_afk_hooked))
        return;
    self.cuk_afk_hooked = true;
    self.is_afk = false;
    self.afk_activating = false;
    if (!isdefined(self.pers["afk_last_used"]))
        self.pers["afk_last_used"] = 0;
    self thread cuk_afk_capture_spawn();
    self thread cuk_afk_chat();
}

function cuk_afk_chat()
{
    self endon("disconnect");
    for (;;)
    {
        self waittill("chat", text);
        if (cuk_afk_clean(text) == ".afk")
            self thread cuk_afk_toggle();
    }
}

// trims leading spaces/tabs and lower-cases, so " .AFK" works too
function cuk_afk_clean(text)
{
    if (!isdefined(text))
        return "";
    text = "" + text;
    for (i = 0; i < 64 && text != ""; i++)
    {
        c = getsubstr(text, 0, 1);
        if (c != " " && c != "\t")
            break;
        text = getsubstr(text, 1, text.size);
    }
    return tolower(text);
}

function cuk_afk_capture_spawn()
{
    self endon("disconnect");
    level endon("end_game");
    if (!isdefined(self.sessionstate) || self.sessionstate != "playing")
        self waittill("spawned_player");   // a player hooked late by the sweep may already be in
    if (!isdefined(level.afk_system.verified_spawn))
    {
        level.afk_system.verified_spawn = self.origin;
        level.afk_system.verified_angles = self getplayerangles();
    }
}

function cuk_afk_name()
{
    if (isdefined(self.name))
        return self.name;
    return "Player";
}

function cuk_afk_downed()
{
    // same test BO3's laststand::player_is_in_laststand() makes, without depending on its namespace
    return isdefined(self.laststand) && self.laststand;
}

// ---------------------------------------------------------------- toggle & checks

function cuk_afk_toggle()
{
    if (self.afk_activating)
    {
        self.afk_activating = false;
        self notify("afk_cancel");
        self iprintln("AFK activation ^1cancelled^7.");
        return;
    }
    if (self.is_afk)
    {
        self thread cuk_afk_deactivate();
        return;
    }
    if (self.sessionstate == "spectator")
    {
        self iprintln("Cannot use AFK while ^1spectating^7.");
        return;
    }
    if (!isdefined(level.round_number) || level.round_number < level.afk_system.min_round)
    {
        self iprintln("AFK available from round ^3" + level.afk_system.min_round + "^7.");
        return;
    }
    if (self.pers["afk_last_used"] > 0)
    {
        elapsed = gettime() - self.pers["afk_last_used"];
        if (elapsed < level.afk_system.cooldown_ms)
        {
            self iprintln("AFK on cooldown. ^3" + int((level.afk_system.cooldown_ms - elapsed) / 60000) + "^7 min remaining.");
            return;
        }
    }
    if (!isalive(self))
    {
        self iprintln("Cannot use AFK while ^1dead^7.");
        return;
    }
    if (self cuk_afk_downed())
    {
        self iprintln("Cannot use AFK while ^1downed^7.");
        return;
    }
    self thread cuk_afk_countdown();
}

function cuk_afk_countdown()
{
    self endon("disconnect");
    self endon("afk_cancel");
    level endon("end_game");

    self.afk_activating = true;
    start_health = self.health;
    delay = level.afk_system.activation_delay_s;
    self iprintln("AFK activating in ^3" + delay + "^7s. Type ^3.afk^7 to cancel.");

    for (i = delay; i > 0; i--)
    {
        if (!isalive(self) || self cuk_afk_downed())
        {
            self.afk_activating = false;
            self iprintln("AFK activation ^1cancelled^7.");
            return;
        }
        if (self.health < start_health)
        {
            self.afk_activating = false;
            self iprintln("AFK activation ^1cancelled^7 - you took damage!");
            return;
        }
        if (i == 30 || i == 10 || i <= 5)
            self iprintln("AFK in ^3" + i + "^7...");
        // a teleport cancels it, or un-AFK would return them somewhere the map has since moved them out of
        for (t = 0; t < 4; t++)
        {
            last = self.origin;
            wait 0.25;
            if (distancesquared(self.origin, last) > 250 * 250)
            {
                self.afk_activating = false;
                self iprintln("AFK activation ^1cancelled^7 - you were teleported.");
                return;
            }
        }
    }
    if (!isalive(self) || self cuk_afk_downed())
    {
        self.afk_activating = false;
        self iprintln("AFK activation ^1cancelled^7.");
        return;
    }
    self thread cuk_afk_activate();
}

// ---------------------------------------------------------------- activate / deactivate

function cuk_afk_activate()
{
    self.afk_activating = false;
    self.is_afk = true;
    self.afk_saved_score = self.score;
    self.afk_saved_origin = self.origin;
    self.afk_saved_angles = self getplayerangles();
    self.afk_map_moved = false;

    lock_origin = self.origin;
    lock_angles = self.afk_saved_angles;
    if (isdefined(level.afk_system.verified_spawn))
    {
        lock_origin = level.afk_system.verified_spawn;
        lock_angles = level.afk_system.verified_angles;
        self setorigin(lock_origin);
        self setplayerangles(lock_angles);
    }

    self disableweapons();
    self setmovespeedscale(0);
    self allowjump(false);
    self enableinvulnerability();
    self.ignoreme = true;

    self.afk_hud_label = newclienthudelem(self);
    self.afk_hud_label.alignx = "center";
    self.afk_hud_label.aligny = "middle";
    self.afk_hud_label.horzalign = "center";
    self.afk_hud_label.vertalign = "middle";
    self.afk_hud_label.y = -60;
    self.afk_hud_label.fontscale = 2.5;
    self.afk_hud_label.color = (1, 0.8, 0);
    self.afk_hud_label.sort = 100;
    self.afk_hud_label.hidewheninmenu = 0;
    self.afk_hud_label settext("AFK");

    self.afk_hud_timer = newclienthudelem(self);
    self.afk_hud_timer.alignx = "center";
    self.afk_hud_timer.aligny = "middle";
    self.afk_hud_timer.horzalign = "center";
    self.afk_hud_timer.vertalign = "middle";
    self.afk_hud_timer.y = -35;
    self.afk_hud_timer.fontscale = 2;
    self.afk_hud_timer.color = (1, 0.8, 0);
    self.afk_hud_timer.sort = 100;
    self.afk_hud_timer.hidewheninmenu = 0;

    cuk_afk_say_all(self cuk_afk_name() + " is now ^3AFK^7.");
    self thread cuk_afk_timer();
    self thread cuk_afk_score_lock();
    self thread cuk_afk_position_lock(lock_origin, lock_angles);
    self thread cuk_afk_disconnect_cleanup();
}

function cuk_afk_deactivate()
{
    if (!self.is_afk)
        return;
    self.is_afk = false;
    self.pers["afk_last_used"] = gettime();
    self notify("afk_ended");   // stops the locks and timer before moving the player back

    self enableweapons();
    self setmovespeedscale(1);
    self allowjump(true);
    self.ignoreme = false;

    if (isdefined(self.afk_saved_origin) && self.afk_map_moved)
        self iprintln("The map moved you while AFK - you stay at spawn.");
    else if (isdefined(self.afk_saved_origin))
    {
        self setorigin(self.afk_saved_origin);
        self setplayerangles(self.afk_saved_angles);
    }
    self.afk_saved_origin = undefined;
    self.afk_saved_angles = undefined;

    self thread cuk_afk_grace();
    self.score = self.afk_saved_score;
    self.afk_saved_score = undefined;
    cuk_afk_destroy_hud();
    cuk_afk_say_all(self cuk_afk_name() + " is no longer ^3AFK^7.");
}

function cuk_afk_destroy_hud()
{
    if (isdefined(self.afk_hud_label))
        self.afk_hud_label destroy();
    if (isdefined(self.afk_hud_timer))
        self.afk_hud_timer destroy();
}

function cuk_afk_disconnect_cleanup()
{
    self endon("afk_ended");
    label = self.afk_hud_label;
    timer = self.afk_hud_timer;
    self waittill("disconnect");
    if (isdefined(label))
        label destroy();
    if (isdefined(timer))
        timer destroy();
}

// ---------------------------------------------------------------- locks, timer, grace

function cuk_afk_position_lock(origin, angles)
{
    self endon("disconnect");
    self endon("afk_ended");
    for (;;)
    {
        wait 0.1;
        d = distancesquared(self.origin, origin);
        if (d > 4)
        {
            if (d > 250 * 250)
                self.afk_map_moved = true;   // a teleporter / timed return moved them
            self setorigin(origin);
            self setplayerangles(angles);
        }
    }
}

function cuk_afk_score_lock()
{
    self endon("disconnect");
    self endon("afk_ended");
    for (;;)
    {
        wait 0.5;
        if (self.score != self.afk_saved_score)
            self.score = self.afk_saved_score;
    }
}

function cuk_afk_timer()
{
    self endon("disconnect");
    self endon("afk_ended");
    total = level.afk_system.duration_s;
    self.afk_hud_timer settimer(total);
    for (i = total; i >= 0; i--)
    {
        if (i == 300)
            self iprintlnbold("^3AFK expires in 5 minutes.");
        else if (i == 60)
        {
            self iprintlnbold("^1AFK expires in 1 minute!");
            self.afk_hud_timer.color = (1, 0.2, 0.2);
            self.afk_hud_label.color = (1, 0.2, 0.2);
        }
        else if (i == 30)
            self iprintlnbold("^1AFK expires in 30 seconds!");
        else if (i == 10)
            self iprintlnbold("^1AFK expires in 10 seconds!");
        if (i > 0)
            wait 1;
    }
    self iprintlnbold("^1AFK time expired!");
    self thread cuk_afk_deactivate();
}

function cuk_afk_grace()
{
    self endon("disconnect");
    level endon("end_game");
    self iprintln("^3Invulnerable for 30s - get your bearings!");
    for (i = 30; i > 0; i--)
    {
        if (i == 10)
            self iprintln("^1Invulnerability ends in 10s!");
        else if (i == 5)
            self iprintln("^1Invulnerability ends in 5s!");
        wait 1;
    }
    if (!self.is_afk)
        self disableinvulnerability();
    self iprintln("^1Invulnerability ended.");
}

// ---------------------------------------------------------------- round freeze

function cuk_afk_freeze_monitor()
{
    level endon("end_game");
    for (;;)
    {
        wait 0.5;
        players = getplayers();
        active = 0;
        afk = 0;
        for (i = 0; i < players.size; i++)
        {
            p = players[i];
            if (!isdefined(p.is_afk))
                continue;
            if (p.is_afk)
                afk++;
            else if (isalive(p) && p.sessionstate == "playing")
                active++;
        }
        freeze = (afk > 0 && active == 0);
        if (freeze && !level.afk_system.round_frozen)
        {
            level.afk_system.round_frozen = true;
            if (isdefined(level.zombie_vars) && isdefined(level.zombie_vars["zombie_use_failsafe"]))
            {
                level.afk_system.saved_use_failsafe = level.zombie_vars["zombie_use_failsafe"];
                level.zombie_vars["zombie_use_failsafe"] = false;
            }
            cuk_afk_say_all("^3Round paused - all players AFK.");
        }
        else if (!freeze && level.afk_system.round_frozen)
        {
            level.afk_system.round_frozen = false;
            if (isdefined(level.afk_system.saved_use_failsafe))
                level.zombie_vars["zombie_use_failsafe"] = level.afk_system.saved_use_failsafe;
            level.afk_system.saved_use_failsafe = undefined;
            cuk_afk_say_all("^2Round resumed.");
        }
    }
}

function cuk_afk_say_all(msg)
{
    players = getplayers();
    for (i = 0; i < players.size; i++)
        players[i] iprintln(msg);
}
