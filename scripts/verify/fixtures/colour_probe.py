"""Asks for the background (OSC 11) as Claude Code does: at once on each colour-scheme notice of mode 2031, and every
half second. Appends one line to the log for each notice (`notice`) and each answer (`answer rgb:…`)."""
import os
import re
import select
import sys
import time
import tty

log = open(sys.argv[1], 'a', buffering=1)
tty.setraw(0)
os.write(1, b'\x1b[?2031h')
pattern = re.compile(rb'\x1b\[\?997;[12]n|\x1b\]11;(rgb:[0-9a-f/]+)(?:\x1b\\|\x07)')
received, next_question = b'', 0.0
while True:
    if time.time() >= next_question:
        os.write(1, b'\x1b]11;?\x1b\\')
        next_question = time.time() + 0.5
    if select.select([0], [], [], 0.05)[0]:
        received += os.read(0, 1024)
    while (found := pattern.search(received)):
        received = received[found.end():]
        if found.group(1):
            log.write('answer %s\n' % found.group(1).decode())
        else:
            log.write('notice\n')
            os.write(1, b'\x1b]11;?\x1b\\')
