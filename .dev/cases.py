import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
LP = "[lua:4rtefakt.crowd] "
K17 = ";".join("%d:near=17;%d:atk" % (t, t + 1) for t in range(40, 140, 25))


def server(*chat, extra=""):
    """The mock chat on a free port: (process, env additions, lines for the mod's settings)."""
    def start():
        p = subprocess.Popen([sys.executable, "-u", os.path.join(HERE, "mock_twitch.py")] + list(chat), stdout=subprocess.PIPE, text=True)
        port = p.stdout.readline().strip()
        return p, {"CLERIA_DRIVE_REALTIME": "1"}, 'Server="ws://127.0.0.1:%s"\nChannel="TestChannel"\n%s' % (port, extra)
    return start


CASES = {
    # The handshake (anonymous nick, the channel lowercased, PONG for PING), then a vote started at once: alice votes 1,
    # bob 2, carol 2, bob changes to 3, dave says "2 please" (not a vote), erin 3. Tally 1 / 1 / 2: option 3 wins.
    "vote": dict(room="S_10/S_1002/S_1002",
        server=server("1.5:alice:1", "1.7:bob:2", "1.9:carol:2", "2.1:bob:3", "2.3:dave:2 please", "2.5:erin: 3 ",
                      extra="VoteTime=6\nPollEvery=600"),
        drive="60:lua=cc vote;300:lua=cc;301:shot;520:lua=cc;560:quit",
        expect=[LP + "Crowd Control loaded for #TestChannel", LP + "joined #TestChannel", LP + "vote: ",
                LP + "status connected seen 6 vote ", " tally 1 1 2 active -", LP + "votes 1 1 2", LP + "effect: ",
                "==== server", "recv NICK justinfan", "recv JOIN #testchannel", "recv PONG :tmi.twitch.tv"],
        shots={"vote": 301}),
    # Nobody votes: nothing happens (the default).
    "no_votes": dict(room="S_10/S_1002/S_1002", server=server(extra="VoteTime=2\nPollEvery=600"),
        drive="60:lua=cc vote;300:lua=cc;320:quit",
        expect=[LP + "vote: ", LP + "votes 0 0 0", LP + "no votes: nothing happens"], absent=[LP + "effect: "]),
    # The effects on the engine's numbers. Power Surge: the kill's hits are doubled (20 -> 40: two hits for 74 HP).
    "surge": dict(room="S_10/S_1002/S_1002", server=server(extra="PollEvery=600"),
        drive="8:opt=DamageDealt=10;20:lua=cc apply surge;40:near=17;41:atk;65:near=17;90:quit",
        expect=[LP + "effect: surge", "near cast 17 id 17 hp 74 ", "near cast 17 id 17 hp 34 "]),
    # Iron Skin: a hit of 21 becomes 10. Glass Skin: 42.
    "iron": dict(room="S_10/S_1002/S_1002", server=server(extra="PollEvery=600"),
        drive="20:lua=cc apply iron;30:hurt=60;40:stats;50:quit", expect=[LP + "effect: iron", "hp 50/60"]),
    "glass": dict(room="S_10/S_1002/S_1002", server=server(extra="PollEvery=600"),
        drive="20:lua=cc apply glass;30:hurt=60;40:stats;50:quit", expect=[LP + "effect: glass", "hp 18/60"]),
    # Instant effects: Blood Tax (60 -> 40), Heal (+30 -> 60, capped), Jackpot (100 SP at level 1); a timed one ends.
    "instant": dict(room="S_10/S_1002/S_1002", server=server(extra="PollEvery=600\nEffectTime=2"),
        drive="20:lua=cc apply tax;30:stats;40:lua=cc apply heal;50:stats;60:lua=cc apply jackpot;70:stats;"
              "80:lua=cc apply wisdom;260:lua=cc;270:quit",
        expect=["hp 40/60 sp 0", "hp 60/60 sp 0", "hp 60/60 sp 100", LP + "effect: wisdom", LP + "effect over: wisdom", " active -"]),
}

# Not in the default run (it needs the network): python .dev/run.py real_twitch
EXTRA = {
    # The real endpoint, read anonymously: the welcome and the join of a public channel.
    "real_twitch": dict(room="S_10/S_1002/S_1002", settings='Channel="twitch"\nPollEvery=600', env={"CLERIA_DRIVE_REALTIME": "1"},
        drive="600:lua=cc;620:quit", expect=[LP + "joined #twitch", LP + "status connected"]),
}
if len(sys.argv) > 1:
    CASES.update(EXTRA)
