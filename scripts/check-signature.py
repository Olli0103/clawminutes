#!/usr/bin/env python3
"""Fail if permissions would be bound to a changing per-build hash."""
import pathlib, subprocess
app=pathlib.Path.home()/'.openclaw/teams-transcribe/ocmh.app'
r=subprocess.run(['/usr/bin/codesign','-d','-r-',str(app)],capture_output=True,text=True)
assert r.returncode==0, 'FAIL: helper has no verifiable signature'
assert 'cdhash' not in r.stdout+r.stderr, 'FAIL: helper identity still changes with every rebuild; stable signing needs user approval'
print('PASS: designated requirement is stable across code updates')
