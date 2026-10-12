"""A stand-in for Twitch's chat endpoint: after NICK and JOIN it welcomes the client, then plays a scripted
chat (argv: "delay:user:text" items, delay in seconds after the JOIN) and a PING.

    python mock_twitch.py 2:alice:1 2.2:bob:2 2.4:carol:2      # prints the port on its first line
"""
import asyncio, sys
import websockets

SCRIPT = [a.split(":", 2) for a in sys.argv[1:]]


async def handler(ws):
    nick, chan = "?", "?"
    async for msg in ws:
        print("recv", msg, flush=True)
        if msg.startswith("NICK "):
            nick = msg[5:].strip()
        elif msg.startswith("JOIN "):
            chan = msg[5:].strip()
            await ws.send(":tmi.twitch.tv 001 %s :Welcome, GLHF!\r\n:%s!%s@%s.tmi.twitch.tv JOIN %s\r\n" % (nick, nick, nick, nick, chan))
            await ws.send(":%s.tmi.twitch.tv 366 %s %s :End of /NAMES list" % (nick, nick, chan))
            asyncio.ensure_future(chat(ws, chan))


async def chat(ws, chan):
    t = 0.0
    await ws.send("PING :tmi.twitch.tv")
    for delay, user, text in SCRIPT:
        await asyncio.sleep(max(0.0, float(delay) - t))
        t = float(delay)
        await ws.send(":%s!%s@%s.tmi.twitch.tv PRIVMSG %s :%s" % (user, user, user, chan, text))


async def main():
    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        print(server.sockets[0].getsockname()[1], flush=True)
        await asyncio.Future()

asyncio.run(main())
