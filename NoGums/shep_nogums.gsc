// [Shep] GobbleGums are disabled on the BO3 servers.
//
// How: _zm_bgb_machine's __init__ only sets the per-round purchase limit to 3 "if not already defined".
// This autoexec runs before any system __init__, so defining it as 0 here makes every gum machine show
// "come back next round" and refuse to sell - no gums can be had, on any map.
//
// Do NOT switch the gum system off with level.bgb_in_use = 0 (tried first): the client still registers the
// gum HUD clientfields, the server then doesn't, and every player is refused with "Clientfield Mismatch".
//
// A check line is written to boiii/scriptdata/cuk/<port>/nogums.txt (max_buys should be 0).

autoexec function cuk_nogums_init()
{
    level.bgb_machine_max_uses_per_round = 0;
    level thread cuk_nogums_report();
}

function cuk_nogums_report()
{
    wait 15;
    port = getdvarstring("net_port");
    machines = "undefined";
    if (isdefined(level.bgb_machines))
        machines = "" + level.bgb_machines.size;
    max_buys = "undefined";
    if (isdefined(level.bgb_machine_max_uses_per_round))
        max_buys = "" + level.bgb_machine_max_uses_per_round;
    writefile("cuk/" + port + "/nogums.txt", getdvarstring("mapname") + " machines=" + machines + " max_buys=" + max_buys + "\n");
}
