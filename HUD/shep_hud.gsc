// [Shep] BO3 HUD (EZZ BOIII) - zombie counter, run clock and round splits (22 Oct 2026).
//
// Drawn like the game's own HUD rather than as a panel: no boxes or bars, just text in the top-right,
// clear of the message feed on the left.
//
//     ZOMBIES 24        zombies left this round (to spawn + alive), red at 5 or fewer
//        ALIVE 9        of those, how many are up on the map right now (smaller, grey)
//        DOGS 2        only on dog rounds / while dogs are alive
//     12:34             run clock (total game time, the figure the speedrun boards use)
//     ROUND 12  1:23    the round that just ended, for 6 s
//
// .counter hides/shows the counter, .timer the clock and splits.
//
// BO3 digits are ~4 units wide at fontscale 1 (WaW's were ~6), so the clock's separator offsets
// are scaled from that.
// No leaks: settext() is only ever called with the fixed strings in cuk_hud_strings(), so the
// configstring table can't fill up however long a game runs. Every number goes through setvalue().
// Each player's elements are destroyed on disconnect, and all per-player threads end then too.

// Every HUD string, registered in one fixed order before anything else on every map. A player who
// carries over a map change (map vote, .restart) keeps the last map's text table, so if two strings
// swapped slots the old text shows: Verruckt drew "DOGS" in the LOCKED tag (10 Oct). The same list
// sits at the top of cuk_hud, cuk_lock and cuk_afk; whichever init runs first registers it. New
// strings only ever go on the end.
function cuk_hud_strings()
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
    level.cuk_hud_alive = 0;
    level.cuk_hud_dogs = 0;
    level.cuk_hud_dogrow = false;
    level.cuk_hud_dog_round = false;

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
        // the run clock starts with shep_stats' run (level.cuk_sr_start: the first player's first move
        // after spawning), so the two always match; a game not started at round 1 isn't timed there,
        // and the clock then runs from the first round seen
        if (isdefined(level.cuk_sr_start))
            level.cuk_hud_total_start = level.cuk_sr_start;
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
        if (level.cuk_hud_total_start <= 0 && level.round_number > 1 && !isdefined(level.cuk_sr_start))
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

        level.cuk_hud_alive = zombies;     // before the spawn queue is added
        dog_round = cuk_is_dog_round();
        if (dog_round)
            dogs += to_spawn;      // on a dog round the spawn queue is dogs
        else
            zombies += to_spawn;

        level.cuk_hud_zombies = zombies;
        level.cuk_hud_dogs = dogs;
        level.cuk_hud_dogrow = dog_round || dogs > 0;
        level.cuk_hud_dog_round = dog_round;
    }
}

// ---------------------------------------------------------------- per-player HUD

// EZZ BOIII sends every chat line to the player as  self waittill("chat", text).
function cuk_hud_chat()
{
    self endon("disconnect");
    for (;;)
    {
        self waittill("chat", text);
        if (!isdefined(text))
            continue;
        text = "" + text;
        for (i = 0; i < 64 && text != ""; i++)
        {
            c = getsubstr(text, 0, 1);
            if (c != " " && c != "\t")
                break;
            text = getsubstr(text, 1, text.size);
        }
        text = tolower(text);
        if (text == ".counter")
        {
            self.cuk_counter_on = !self.cuk_counter_on;
            self cuk_hud_refresh(0.2);
        }
        else if (text == ".timer")
        {
            self.cuk_timer_on = !self.cuk_timer_on;
            self cuk_hud_refresh(0.2);
        }
    }
}

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

    // Layout in 640x480 HUD units from the top right. Everything lines up on the right edge; a label
    // sits left of its number, so it is placed from the width of the digits. shep_lock.gsc puts its
    // LOCKED tag left of the ZOMBIES label (x -62, y 18), so move that too if this moves.
    x = -6;
    self.cuk_x = x;
    self.cuk_y0 = 10;
    self.cuk_row_h = 20;
    self.cuk_clock_h = 13;
    self.cuk_lab_dy = 8;          // label below the number's top, so the baselines meet
    self.cuk_num_w = 8;           // one big digit (scale 2.0)
    self.cuk_alive_w = 6.4;       // one digit of the smaller ALIVE number (scale 1.6)
    self.cuk_alive_dy = 6;        // its label below the number's top
    self.cuk_alive_h = 16;        // the ALIVE row
    self.cuk_small_w = 4;         // one label-size digit
    self.cuk_tx = x;              // right edge of the clock
    self.cuk_stx = x;             // right edge of the split time
    self.cuk_split_until = 0;

    // counter: a big number with a small label in front of it
    self.cuk_zn = cuk_text(self, "right", x, 2.0, 0.95, 0.95, 0.92);
    self.cuk_zn setvalue(0);
    self.cuk_zt = cuk_text(self, "right", x, 1.0, 0.86, 0.86, 0.82);
    self.cuk_zt settext("ZOMBIES");
    self cuk_place_label(1, self.cuk_zt);
    self.cuk_an = cuk_text(self, "right", x, 1.6, 0.74, 0.76, 0.78);
    self.cuk_an setvalue(0);
    self.cuk_at = cuk_text(self, "right", x, 1.0, 0.74, 0.76, 0.78);
    self.cuk_at settext("ALIVE");
    self.cuk_at.x = x - self.cuk_alive_w - 5;
    self.cuk_dn = cuk_text(self, "right", x, 2.0, 0.94, 0.70, 0.24);
    self.cuk_dn setvalue(0);
    self.cuk_dt = cuk_text(self, "right", x, 1.0, 0.94, 0.70, 0.24);
    self.cuk_dt settext("DOGS");
    self cuk_place_label(1, self.cuk_dt);

    // run clock m:ss: minutes, a separator that reads ":" or ":0", seconds
    self.cuk_secs = cuk_text(self, "right", self.cuk_tx, 1.3, 0.95, 0.95, 0.92);
    self.cuk_sep  = cuk_text(self, "right", self.cuk_tx - 5, 1.3, 0.95, 0.95, 0.92);
    self.cuk_mins = cuk_text(self, "right", self.cuk_tx - 13, 1.3, 0.95, 0.95, 0.92);
    self.cuk_sep settext(":0");
    self.cuk_padded = true;
    self.cuk_secs setvalue(0);
    self.cuk_mins setvalue(0);

    // split: "ROUND 12  1:23"
    self.cuk_st = cuk_text(self, "right", x, 1.0, 0.86, 0.86, 0.82);
    self.cuk_st settext("ROUND");
    self.cuk_sr = cuk_text(self, "right", x, 1.0, 0.86, 0.86, 0.82);
    self.cuk_sr setvalue(0);
    self.cuk_ss = cuk_text(self, "right", self.cuk_stx, 1.0, 0.66, 0.83, 1.00);
    self.cuk_ssep = cuk_text(self, "right", self.cuk_stx - 4, 1.0, 0.66, 0.83, 1.00);
    self.cuk_sm = cuk_text(self, "right", self.cuk_stx - 10, 1.0, 0.66, 0.83, 1.00);
    self.cuk_ssep settext(":0");
    self.cuk_ss setvalue(0);
    self.cuk_sm setvalue(0);

    self.cuk_elems = array(self.cuk_zn, self.cuk_zt, self.cuk_dn, self.cuk_dt, self.cuk_secs, self.cuk_sep,
        self.cuk_mins, self.cuk_st, self.cuk_sr, self.cuk_ss, self.cuk_ssep, self.cuk_sm, self.cuk_an, self.cuk_at);
    for (i = 0; i < self.cuk_elems.size; i++)
        self.cuk_elems[i].alpha = 0;

    self.cuk_counter_on = true;
    self.cuk_timer_on = true;
    self.cuk_zshow = true;
    self.cuk_ashow = false;
    self.cuk_dshow = false;
    self.cuk_split_on = false;
    self.cuk_hud_ready = true;

    self thread cuk_hud_cleanup();
    self cuk_hud_refresh(0);
    self thread cuk_hud_tick();
    self thread cuk_hud_split_loop();
    self thread cuk_hud_chat();
}

// Puts every row where it belongs for what is on show and fades each element to its alpha.
// Rows stack from the top: zombies, alive, dogs, clock, split.
function cuk_hud_refresh(t)
{
    y = self.cuk_y0;
    za = 0;
    aa = 0;
    da = 0;
    if (self.cuk_counter_on)
    {
        if (self.cuk_zshow)
        {
            self.cuk_zn.y = y;
            self.cuk_zt.y = y + self.cuk_lab_dy;
            y += self.cuk_row_h;
            za = 1;
        }
        if (self.cuk_zshow && self.cuk_ashow)
        {
            self.cuk_an.y = y;
            self.cuk_at.y = y + self.cuk_alive_dy;
            y += self.cuk_alive_h;
            aa = 1;
        }
        if (self.cuk_dshow)
        {
            self.cuk_dn.y = y;
            self.cuk_dt.y = y + self.cuk_lab_dy;
            y += self.cuk_row_h;
            da = 1;
        }
        y += 2;
    }
    cuk_fade(self.cuk_zn, za, t);
    cuk_fade(self.cuk_zt, za * 0.8, t);
    cuk_fade(self.cuk_an, aa * 0.9, t);
    cuk_fade(self.cuk_at, aa * 0.7, t);
    cuk_fade(self.cuk_dn, da, t);
    cuk_fade(self.cuk_dt, da * 0.85, t);

    ca = 0;
    sa = 0;
    if (self.cuk_timer_on)
    {
        if (level.cuk_hud_total_start > 0)
            ca = 0.9;
        if (self.cuk_split_on)
            sa = 1;
    }
    clock = array(self.cuk_secs, self.cuk_sep, self.cuk_mins);
    for (i = 0; i < clock.size; i++)
    {
        clock[i].y = y;
        cuk_fade(clock[i], ca, t);
    }
    y += self.cuk_clock_h;

    split = array(self.cuk_st, self.cuk_sr, self.cuk_ss, self.cuk_ssep, self.cuk_sm);
    for (i = 0; i < split.size; i++)
    {
        split[i].y = y;
        a = sa;
        if (i < 2)
            a = sa * 0.8;
        cuk_fade(split[i], a, t);
    }
}

function cuk_fade(e, a, t)
{
    if (t > 0)
        e fadeovertime(t);
    e.alpha = a;
}

function cuk_hud_tick()
{
    self endon("disconnect");
    level endon("end_game");
    lastz = -1;
    lasta = -1;
    lastd = -1;
    clock_started = false;
    for (;;)
    {
        wait 0.25;

        // counters; a dog round with no zombies left shows the dogs on their own
        z = level.cuk_hud_zombies;
        a = level.cuk_hud_alive;
        d = level.cuk_hud_dogs;
        zshow = !(level.cuk_hud_dog_round && z == 0);
        ashow = zshow && z > 0;           // ALIVE only while zombies are left in the round
        dshow = level.cuk_hud_dogrow;
        if (zshow != self.cuk_zshow || ashow != self.cuk_ashow || dshow != self.cuk_dshow)
        {
            self.cuk_zshow = zshow;
            self.cuk_ashow = ashow;
            self.cuk_dshow = dshow;
            self cuk_hud_refresh(0.25);
        }
        if (z != lastz)
        {
            if (lastz < 0 || cuk_digits(z) != cuk_digits(lastz))
                self cuk_place_label(cuk_digits(z), self.cuk_zt);
            lastz = z;
            self.cuk_zn setvalue(z);
            if (z <= 5)
                self.cuk_zn.color = (0.92, 0.22, 0.14);
            else
                self.cuk_zn.color = (0.95, 0.95, 0.92);
        }
        if (a != lasta)
        {
            if (lasta < 0 || cuk_digits(a) != cuk_digits(lasta))
                self.cuk_at.x = self.cuk_x - cuk_digits(a) * self.cuk_alive_w - 5;
            lasta = a;
            self.cuk_an setvalue(a);
        }
        if (d != lastd)
        {
            if (lastd < 0 || cuk_digits(d) != cuk_digits(lastd))
                self cuk_place_label(cuk_digits(d), self.cuk_dt);
            lastd = d;
            self.cuk_dn setvalue(d);
        }

        // run clock
        if (level.cuk_hud_total_start <= 0)
            continue;
        if (!clock_started)
        {
            clock_started = true;
            self cuk_hud_refresh(0.3);
        }
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
            self.cuk_sep.x = self.cuk_tx - 5;
        }
        else
        {
            self.cuk_sep settext(":");
            self.cuk_sep.x = self.cuk_tx - 10;
        }
    }
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

// The round that just finished shows under the clock for 6 s; a second round ending restarts it.
function cuk_hud_split_show()
{
    self endon("disconnect");
    self notify("cuk_split_new");
    self endon("cuk_split_new");
    level endon("end_game");

    total = int(level.cuk_hud_split_ms / 1000);
    if (total < 0)
        total = 0;
    m = int(total / 60);
    s = total - m * 60;
    // right to left: the time at the edge, the round number before it, then "ROUND"
    w = self.cuk_small_w;
    rx = self.cuk_stx - ((cuk_digits(m) + 2) * w + 3) - 6;
    self.cuk_sr.x = rx;
    self.cuk_st.x = rx - cuk_digits(level.cuk_hud_split_round) * w - 3;
    if (s < 10)
    {
        self.cuk_ssep settext(":0");
        self.cuk_ssep.x = self.cuk_stx - 4;
    }
    else
    {
        self.cuk_ssep settext(":");
        self.cuk_ssep.x = self.cuk_stx - 8;
    }
    self.cuk_sr setvalue(level.cuk_hud_split_round);
    self.cuk_sm setvalue(m);
    self.cuk_ss setvalue(s);

    self.cuk_split_on = true;
    self cuk_hud_refresh(0.3);
    wait level.cuk_hud_split_secs;
    self.cuk_split_on = false;
    self cuk_hud_refresh(0.6);
}

function cuk_hud_cleanup()
{
    elems = self.cuk_elems;
    self waittill("disconnect");
    for (i = 0; i < elems.size; i++)
        if (isdefined(elems[i]))
            elems[i] destroy();
}

// ---------------------------------------------------------------- element helpers

function cuk_digits(n)
{
    if (n >= 100)
        return 3;
    if (n >= 10)
        return 2;
    return 1;
}

// the label sits left of its number, so it moves when the digit count changes
function cuk_place_label(num_digits, lab)
{
    lab.x = self.cuk_x - num_digits * self.cuk_num_w - 4;
}

function cuk_text(player, align, x, scale, r, g, b)
{
    e = newclienthudelem(player);
    e.foreground = 1;
    e.hidewhendead = 0;
    e.hidewheninmenu = 1;
    e.horzalign = "right";
    e.vertalign = "top";
    e.alignx = align;
    e.aligny = "top";
    e.x = x;
    e.y = 0;
    e.fontscale = scale;
    e.color = (r, g, b);
    e.alpha = 1;
    e.sort = 7;
    return e;
}
