# Receive one SSH public key over magic-wormhole, speaking the protocol
# of `wormhole ssh invite`, so the sender can use the stock
# `wormhole ssh accept`. Prints the code and instructions on stderr and
# the key on stdout; core-backup decides what to do with it.
import sys

from twisted.internet import task
from twisted.internet.defer import inlineCallbacks
from wormhole import xfer_util
from wormhole.cli.public_relay import RENDEZVOUS_RELAY

APPID = "lothar.com/wormhole/ssh-add"


@inlineCallbacks
def main(reactor, name):
    def on_code(code):
        print(
            f"On {name}, run one of:\n\n"
            f"  core-backup join {code}\n"
            f"  wormhole ssh accept -F /var/lib/backup {code}\n",
            file=sys.stderr,
            flush=True,
        )

    key = yield xfer_util.receive(
        reactor, APPID, RENDEZVOUS_RELAY, None, on_code=on_code
    )
    lines = key.strip().splitlines()
    if len(lines) != 1:
        raise SystemExit("expected exactly one key line")
    sys.stdout.write(lines[0] + "\n")


task.react(main, [sys.argv[1]])
