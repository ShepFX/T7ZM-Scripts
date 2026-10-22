# Shep Black Ops III (T7) zombie scripts

The GSC the Shep Black Ops III zombies servers actually run, on the EZZ BOIII
client. Every file here was taken from a live server, so what is in this repo is
what is running.

Scripts install into `boiii/custom_scripts/zm/`. They load at map load, and chat
commands arrive per player as `self waittill("chat", text)`, which EZZ BOIII
provides.

## What is deployed where

| In this repo | Deployed as | Running on |
| --- | --- | --- |
| `AFK/shep_afk.gsc` | `shep_afk.gsc` | 5 zombie servers |
| `HUD/shep_hud.gsc` | `shep_hud.gsc` | 5 zombie servers |
| `MapVote/shep_mapvote.gsc` | `shep_mapvote.gsc` | 5 zombie servers |
| `NoGums/shep_nogums.gsc` | `shep_nogums.gsc` | 5 zombie servers |
| `RoundLock/shep_lock.gsc` | `shep_lock.gsc` | 5 zombie servers |
| `Stats/shep_stats.gsc` | `shep_stats.gsc` | 5 zombie servers |

Last verified against the live servers on 2026-10-22.

## The scripts

- **AFK** (`.afk`): from round 20, with a 45-minute cooldown. A 1-minute
  countdown first, cancelled by taking damage or going down. While AFK (up to 15
  minutes) you are held at spawn with godmode and frozen points, and if everyone
  is AFK the round pauses. Port of the WaW AFK script.
- **HUD** (`.counter`, `.timer`): zombies left this round, how many are alive
  right now, dogs, the run clock and per-round splits, as plain text in the top
  right with no panels. The clock starts with the speedrun timing below, so the
  two always match. Text is a fixed set of strings and every number goes
  through `setvalue()`, so long games can't overflow the configstring table.
- **Map vote** (`.map`, `.1`, `.2` ..., `.map kino`, `.restart`): vote for
  another map in the rotation or a restart. A majority wins (solo is instant),
  votes last 60 seconds, with a 5-minute cooldown and one vote per player every
  10 minutes.
- **No gums**: disables GobbleGums by setting the per-round gum limit to 0
  before the gum system starts, so every machine refuses to sell. Turning the gum
  system off outright causes a "Clientfield Mismatch" kick, so don't do that.
- **Round lock** (`.lock`): a majority vote locks the server with a random
  4-digit join password, and from round 20 it locks itself. The password clears
  when the game ends.
- **Stats**: writes high rounds, speedrun milestones and easter eggs, the live
  round, and per-player game stats (kills, downs, revives, box, perks,
  Pack-a-Punch, power-ups) for the stats website. Files are kept per server port
  under `boiii/scriptdata/cuk/<port>/`. Players are identified by their XUID,
  converted to the decimal number IW4MAdmin uses. Speedrun timing starts at the
  first player's first move or button press after spawning (3 seconds after
  spawning at the latest), so a slow load-in costs nothing. Easter eggs also
  count round-1 leavers who stayed at least a minute.
