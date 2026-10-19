// [Shep] BO3 HUD panel (EZZ BOIII) - same style as T4RunTimer.
//
//   RUN      12:34     total game time; after a round ends it shows that round's split
//                      ("R12  1:23", light blue) for 6 s, then goes back to the run clock
//   ZOMBIES     24     zombies left this round (to spawn + alive)
//                      white, yellow at 5 or fewer, red under 3
//   DOGS         6     only on dog rounds / while dogs are alive - the panel grows to fit
//
// BO3 digits are ~4 units wide at fontscale 1 (WaW's were ~6), hence the -4 / -8 / -10 offsets.
// No leaks: settext() is only ever called with a handful of fixed strings ("RUN", "R", ":",
// ":0", "ZOMBIES", "DOGS"), so the configstring table can't fill up however long a game runs.
// Every number goes through setvalue(). Each player's elements are destroyed on disconnect.

// Every HUD string, registered in one fixed order before anything else on every map. A player who
// carries over a map change (map vote, .restart) keeps the last map's text table, so if two strings
// swapped slots the old text shows: Verruckt drew "DOGS" in the LOCKED tag (10 Oct). The same list
// sits at the top of cuk_hud, cuk_lock and cuk_afk; whichever init runs first registers it.
function cuk_hud_strings()
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

autoexec function cuk_hud_init()
{
    cuk_hud_strings();
    level.cuk_hud_total_start = 0;
    level.cuk_hud_round_start = 0;
    level.cuk_hud_round = 0;
    level.cuk_hud_split_round = 0;
    level.cuk_hud_split_ms = 0;
    level.cuk_hud_split_secs = 6;
    level.cuk_hud_zombies = 0;
    level.cuk_hud_dogs = 0;
    level.cuk_hud_dogrow = false;

    level thread cuk_hud_round_monitor();
    level thread cuk_hud_count_monitor();
    level thread cuk_hud_connect();
}

// ---------------------------------------------------------------- level-side tracking

function cuk_hud_round_monitor()
{
    level endon("end_game");
    for (;;)
    {
        wait 0.25;
        if (!isdefined(level.round_number) || level.round_number == level.cuk_hud_round)
            continue;
        if (getplayers().size == 0)
            continue;
        if (level.cuk_hud_round > 0 && level.cuk_hud_round_start > 0)
        {
            level.cuk_hud_split_round = level.cuk_hud_round;
            level.cuk_hud_split_ms = gettime() - level.cuk_hud_round_start;
            level notify("cuk_hud_split");
        }
        level.cuk_hud_round = level.round_number;
        level.cuk_hud_round_start = gettime();
        if (level.cuk_hud_total_start <= 0 && level.round_number > 0)
            level.cuk_hud_total_start = level.cuk_hud_round_start;
    }
}

function cuk_is_dog_round()
{
    return isdefined(level.flag) && isdefined(level.flag["dog_round"]) && level.flag["dog_round"];
}

// One count for everyone, 4x a second: zombies vs dogs by archetype.
function cuk_hud_count_monitor()
{
    level endon("end_game");
    for (;;)
    {
        wait 0.25;
        zombies = 0;
        dogs = 0;
        ai = getaiteamarray("axis");
        if (isdefined(ai))
        {
            for (i = 0; i < ai.size; i++)
            {
                if (!isdefined(ai[i]) || !isalive(ai[i]))
                    continue;
                if (isdefined(ai[i].archetype) && ai[i].archetype == "zombie_dog")
                    dogs++;
                else
                    zombies++;
            }
        }
        to_spawn = 0;
        if (isdefined(level.zombie_total) && level.zombie_total > 0)
            to_spawn = level.zombie_total;

        dog_round = cuk_is_dog_round();
        if (dog_round)
            dogs += to_spawn;      // on a dog round the spawn queue is dogs
        else
            zombies += to_spawn;

        level.cuk_hud_zombies = zombies;
        level.cuk_hud_dogs = dogs;
        level.cuk_hud_dogrow = dog_round || dogs > 0;
    }
}

// ---------------------------------------------------------------- per-player panel

function cuk_hud_connect()
{
    level thread cuk_hud_sweep();
    for (;;)
    {
        level waittill("connected", player);
        player cuk_hud_hook();
    }
}

// EZZ BOIII can miss the "connected" notify for players who carry over a map change, so this
// safety net hooks anyone on the server who has no listener yet (once per player, via the flag).
function cuk_hud_sweep()
{
    for (;;)
    {
        wait 2;
        players = getplayers();
        for (i = 0; i < players.size; i++)
            if (isdefined(players[i]))
                players[i] cuk_hud_hook();
    }
}

function cuk_hud_hook()
{
    if (isdefined(self.cuk_hud_hooked))
        return;
    self.cuk_hud_hooked = true;
    self thread cuk_hud_build();
}

function cuk_hud_build()
{
    self endon("disconnect");
    level endon("end_game");
    if (!isdefined(self.sessionstate) || self.sessionstate != "playing")
        self waittill("spawned_player");   // a player hooked late by the sweep may already be in
    if (isdefined(self.cuk_hud_ready))
        return;
    self.cuk_hud_ready = true;

    px = 20;
    py = 24;
    w = 84;
    self.cuk_px = px;
    self.cuk_py = py;
    self.cuk_w = w;
    self.cuk_tx = px + 78;
    self.cuk_split_until = 0;

    // amber accent, like the T4 panel
    self.cuk_bg     = cuk_bar(self, px, py, w, 15, 0.04, 0.04, 0.07, 0.72, 5);
    self.cuk_accent = cuk_bar(self, px + w, py, 4, 15, 1.00, 0.55, 0.05, 0.90, 6);

    // RUN row
    self.cuk_title = cuk_text(self, "left", px + 5, py + 2, 1.00, 0.55, 0.05);
    self.cuk_title settext("RUN");
    self.cuk_rnd = cuk_text(self, "left", px + 13, py + 2, 1.00, 0.55, 0.05);
    self.cuk_rnd setvalue(0);
    self.cuk_rnd.alpha = 0;
    self.cuk_secs = cuk_text(self, "right", self.cuk_tx, py + 2, 1, 1, 1);
    self.cuk_sep  = cuk_text(self, "right", self.cuk_tx - 4, py + 2, 1, 1, 1);
    self.cuk_mins = cuk_text(self, "right", self.cuk_tx - 10, py + 2, 1, 1, 1);
    self.cuk_sep settext(":0");
    self.cuk_padded = true;
    self.cuk_secs setvalue(0);
    self.cuk_mins setvalue(0);

    // ZOMBIES row
    self.cuk_zt = cuk_text(self, "left", px + 5, py + 17, 0.75, 0.75, 0.80);
    self.cuk_zt settext("ZOMBIES");
    self.cuk_zn = cuk_text(self, "right", self.cuk_tx, py + 17, 1, 1, 1);
    self.cuk_zn setvalue(0);

    // DOGS row (hidden until needed)
    self.cuk_dt = cuk_text(self, "left", px + 5, py + 32, 1.00, 0.45, 0.20);
    self.cuk_dt settext("DOGS");
    self.cuk_dn = cuk_text(self, "right", self.cuk_tx, py + 32, 1.00, 0.45, 0.20);
    self.cuk_dn setvalue(0);
    self.cuk_dt.alpha = 0;
    self.cuk_dn.alpha = 0;
    self.cuk_rows = 0;
    self cuk_set_rows(2);

    self thread cuk_hud_cleanup();
    self thread cuk_hud_tick();
    self thread cuk_hud_split_loop();
}

// Resize the background to 2 or 3 rows; the DOGS row fades in/out.
function cuk_set_rows(rows)
{
    if (rows == self.cuk_rows)
        return;
    self.cuk_rows = rows;
    h = 4 + rows * 15;
    self.cuk_bg setshader("white", self.cuk_w, h);
    self.cuk_accent setshader("white", 4, h);
    a = 0;
    if (rows == 3)
        a = 1;
    self.cuk_dt fadeovertime(0.2);
    self.cuk_dt.alpha = a;
    self.cuk_dn fadeovertime(0.2);
    self.cuk_dn.alpha = a;
}

function cuk_hud_tick()
{
    self endon("disconnect");
    level endon("end_game");
    lastz = -1;
    lastd = -1;
    for (;;)
    {
        wait 0.25;

        // counters
        z = level.cuk_hud_zombies;
        if (z != lastz)
        {
            lastz = z;
            self.cuk_zn setvalue(z);
            if (z < 3)
                self.cuk_zn.color = (1, 0.15, 0.15);       // red
            else if (z <= 5)
                self.cuk_zn.color = (1, 0.85, 0.20);       // yellow
            else
                self.cuk_zn.color = (1, 1, 1);
        }
        if (level.cuk_hud_dogrow)
            self cuk_set_rows(3);
        else
            self cuk_set_rows(2);
        d = level.cuk_hud_dogs;
        if (d != lastd)
        {
            lastd = d;
            self.cuk_dn setvalue(d);
        }

        // run clock (once a second is enough; skip while a split is showing)
        if (gettime() < self.cuk_split_until || level.cuk_hud_total_start <= 0)
            continue;
        self cuk_show_time(gettime() - level.cuk_hud_total_start);
    }
}

function cuk_show_time(ms)
{
    total = int(ms / 1000);
    if (total < 0)
        total = 0;
    m = int(total / 60);
    s = total - m * 60;
    self.cuk_mins setvalue(m);
    self.cuk_secs setvalue(s);
    padded = s < 10;
    if (padded != self.cuk_padded)
    {
        self.cuk_padded = padded;
        if (padded)
        {
            self.cuk_sep settext(":0");
            self.cuk_sep.x = self.cuk_tx - 4;
        }
        else
        {
            self.cuk_sep settext(":");
            self.cuk_sep.x = self.cuk_tx - 8;
        }
    }
}

function cuk_clock_color(r, g, b)
{
    self.cuk_mins.color = (r, g, b);
    self.cuk_sep.color = (r, g, b);
    self.cuk_secs.color = (r, g, b);
}

function cuk_hud_split_loop()
{
    self endon("disconnect");
    level endon("end_game");
    for (;;)
    {
        level waittill("cuk_hud_split");
        self thread cuk_hud_split_show();
    }
}

function cuk_hud_split_show()
{
    self endon("disconnect");
    self notify("cuk_split_new");
    self endon("cuk_split_new");
    level endon("end_game");

    self.cuk_split_until = gettime() + level.cuk_hud_split_secs * 1000;
    self.cuk_title settext("R");
    self.cuk_rnd setvalue(level.cuk_hud_split_round);
    self.cuk_rnd.alpha = 1;
    self cuk_clock_color(0.62, 0.86, 1.00);
    self cuk_show_time(level.cuk_hud_split_ms);

    wait level.cuk_hud_split_secs;

    self.cuk_split_until = 0;
    self.cuk_title settext("RUN");
    self.cuk_rnd.alpha = 0;
    self cuk_clock_color(1, 1, 1);
    if (level.cuk_hud_total_start > 0)
        self cuk_show_time(gettime() - level.cuk_hud_total_start);
}

function cuk_hud_cleanup()
{
    elems = array(self.cuk_bg, self.cuk_accent, self.cuk_title, self.cuk_rnd, self.cuk_secs, self.cuk_sep,
        self.cuk_mins, self.cuk_zt, self.cuk_zn, self.cuk_dt, self.cuk_dn);
    self waittill("disconnect");
    for (i = 0; i < elems.size; i++)
        if (isdefined(elems[i]))
            elems[i] destroy();
}

// ---------------------------------------------------------------- element helpers

function cuk_text(player, align, x, y, r, g, b)
{
    e = newclienthudelem(player);
    e.foreground = 1;
    e.hidewhendead = 0;
    e.hidewheninmenu = 1;
    e.horzalign = "left";
    e.vertalign = "top";
    e.alignx = align;
    e.aligny = "top";
    e.x = x;
    e.y = y;
    e.fontscale = 1.0;
    e.color = (r, g, b);
    e.alpha = 1;
    e.sort = 7;
    return e;
}

function cuk_bar(player, x, y, w, h, r, g, b, a, srt)
{
    e = newclienthudelem(player);
    e.foreground = 1;
    e.hidewhendead = 0;
    e.hidewheninmenu = 1;
    e.horzalign = "left";
    e.vertalign = "top";
    e.alignx = "left";
    e.aligny = "top";
    e.x = x;
    e.y = y;
    e.sort = srt;
    e setshader("white", w, h);
    e.color = (r, g, b);
    e.alpha = a;
    return e;
}
