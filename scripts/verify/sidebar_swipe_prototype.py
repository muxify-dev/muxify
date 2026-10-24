"""A disposable, interactive Sidebar swipe demo. Run with make prototype-sidebar-swipe; Ctrl-C cleans it up."""

import json
import signal
import time

from scripts.verify.sandbox import Sandbox, alive


def stop(*_):
    raise KeyboardInterrupt


def main():
    with Sandbox('sidebar_swipe_prototype') as s:
        project = s.root/'demo'
        project.mkdir()
        (s.root/'config/muxify/config.yaml').write_text('sidebar:\n  agents: false\n')
        topics = s.root/'state/muxify/topics'
        topics.mkdir()
        for index, title in enumerate(['Sidebar swipe experiment', 'Polish the small details', 'A place for the next idea']):
            topic = 'demo-' + str(index)
            (topics/(topic + '.json')).write_text(json.dumps(dict(id=topic, title=title, slug=topic, order=index)))
            session = s.tmux('new-session', '-d', '-P', '-F', '#{session_id}', '-s', ['muxify', 'design', 'notes'][index],
                             '-c', str(project), '/bin/zsh -f')
            s.tmux('set-option', '-t', session, '@muxify_topic', topic)
        s.launch(['-sidebarVisible', 'YES', '-sessionsVisible', 'YES', '-sidebarWorkView', 'Topics'])
        print('Sidebar swipe prototype is running in its own Muxify copy.', flush=True)
        print('Select its window, then swipe left/right with two fingers over the Topics/Sessions section.', flush=True)
        print('Try a slow preview, a short flick, reversing direction, and vertical scrolling.', flush=True)
        print('Close the demo or press Ctrl-C to clean up its throwaway tmux server. Run files: ' + str(s.root), flush=True)
        signal.signal(signal.SIGTERM, stop)
        try:
            while alive(s.pid):
                time.sleep(0.25)
        except KeyboardInterrupt:
            pass


if __name__ == '__main__':
    main()
