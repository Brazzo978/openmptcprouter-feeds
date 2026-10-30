#!/usr/bin/env python3
"""Exercise the package hold in a temporary APK-world fixture, not /etc/apk."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'files/etc/uci-defaults/4103-mqvpn-world-hold'

class WorldHold(unittest.TestCase):
    def run_hold(self, world, installed):
        with tempfile.TemporaryDirectory() as name:
            root=Path(name); (root/'bin').mkdir(); (root/'apk').mkdir()
            apk=root/'bin/apk'
            apk.write_text('#!/bin/sh\nprintf "mqvpn %s\\n" "$FIXTURE_VERSION"\n')
            apk.chmod(0o755)
            target=root/'apk/world'; target.write_text(world)
            source=SCRIPT.read_text().replace('world=/etc/apk/world', f'world={target}')
            source=source.replace('mktemp /etc/apk/.mqvpn-world.XXXXXX',
                                  f'mktemp {root}/apk/.mqvpn-world.XXXXXX')
            script=root/'hold.sh';script.write_text(source)
            env=dict(os.environ,PATH=str(root/'bin')+os.pathsep+os.environ['PATH'],
                     FIXTURE_VERSION=installed)
            subprocess.run(['sh',str(script)],env=env,check=True)
            result=target.read_text()
            subprocess.run(['sh',str(script)],env=env,check=True)
            self.assertEqual(target.read_text(),result,'repeat must be idempotent')
            return result

    def test_r5_replaces_stale_pin_and_retains_other_packages(self):
        self.assertEqual(self.run_hold('base-files\nmqvpn=0.16.2-r4\nbtop\n','0.16.2-r5'),
                         'base-files\nmqvpn=0.16.2-r5\nbtop\n')

    def test_r5_adds_missing_pin(self):
        self.assertEqual(self.run_hold('base-files\n','0.16.2-r5'),
                         'base-files\nmqvpn=0.16.2-r5\n')

    def test_wrong_installed_version_does_not_change_world(self):
        world='base-files\nmqvpn=0.16.2-r4\n'
        self.assertEqual(self.run_hold(world,'0.16.2-r4'),world)

    def test_duplicate_constraints_collapse_to_one(self):
        self.assertEqual(self.run_hold('mqvpn\nmqvpn>=0.16\nbtop\n','0.16.2-r5'),
                         'mqvpn=0.16.2-r5\nbtop\n')

if __name__ == '__main__': unittest.main(verbosity=2)
