#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Asserts that scripts/play_publish.py makes the Play calls a release needs.

play_publish.py runs a handful of times a year, against the one Play listing
there is, with the real upload; a bug found there is found mid-release, after
the tag is pushed. So everything it does is exercised here against a fake
androidpublisher v3 and a fake OAuth token endpoint on 127.0.0.1, with the
script run as the release runs it: a subprocess, its exit code and its last
stdout line. The fake keeps edits and tracks in memory the way Play does
(nothing changes until commit, a deleted edit is gone), so "the edit was
deleted" and "nothing was released" are checked against state, not guessed
from a request log.

The JWT is checked with openssl against the public half of a throwaway key,
because a signature Google would reject looks exactly like one it accepts
until the day of the release.

Stdlib only, needs openssl. No network beyond loopback.
"""

from __future__ import annotations

import base64
import copy
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / 'play_publish.py'
PACKAGE = 'ca.pigscanfly.liberatedbread'
TOKEN = 'ya29.fake-access-token-must-never-be-printed'

_status = 0


def check(label: str, ok: bool, detail: str = '') -> None:
    global _status
    if ok:
        print(f'  ok    {label}')
    else:
        _status = 1
        print(f'  FAIL  {label}{": " + detail if detail else ""}',
              file=sys.stderr)


def unb64(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))


# ── the fake Play ───────────────────────────────────────────────────────────

class FakePlay:
    """In-memory androidpublisher: edits copy the live tracks, commit swaps."""

    def __init__(self) -> None:
        self.reset()

    def reset(self, *, tracks: dict | None = None, upload_code: int = 42,
              draft_app: bool = False, fail: tuple | None = None) -> None:
        self.tracks = copy.deepcopy(tracks or {})
        self.upload_code = upload_code
        self.draft_app = draft_app
        # (method, path regex, http code, message): refuse matching calls.
        self.fail = fail
        self.edits: dict[str, dict] = {}
        self.calls: list[dict] = []
        self.assertions: list[str] = []
        self.next_edit = 1

    def summary(self) -> list[str]:
        return [f"{c['method']} {c['route']}" for c in self.calls]

    def put_bodies(self) -> list[dict]:
        return [c['json'] for c in self.calls if c['method'] == 'PUT']


FAKE = FakePlay()
APP = re.escape(f'/androidpublisher/v3/applications/{PACKAGE}/edits')
UPLOAD = re.escape(f'/upload/androidpublisher/v3/applications/{PACKAGE}/edits')


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args) -> None:
        pass

    def reply(self, code: int, body: object = None) -> None:
        data = b'' if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def refuse(self, code: int, message: str) -> None:
        self.reply(code, {'error': {'code': code, 'message': message,
                                    'status': 'FAILED_PRECONDITION'}})

    def handle_any(self) -> None:
        url = urllib.parse.urlsplit(self.path)
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b''
        route = url.path.replace(f'/applications/{PACKAGE}', '/app')
        call = {'method': self.command, 'path': url.path, 'route': route,
                'query': urllib.parse.parse_qs(url.query),
                'type': self.headers.get('Content-Type', ''), 'raw': raw,
                'json': None}
        try:
            call['json'] = json.loads(raw) if raw and not route.startswith(
                '/upload') and route != '/token' else None
        except ValueError:
            pass
        FAKE.calls.append(call)

        if url.path == '/token':
            return self.token(raw)
        if self.headers.get('Authorization') != f'Bearer {TOKEN}':
            return self.refuse(401, 'Request had invalid authentication.')
        if FAKE.fail and FAKE.fail[0] == self.command and re.search(
                FAKE.fail[1], url.path):
            return self.refuse(FAKE.fail[2], FAKE.fail[3])
        self.route(url, call)

    def token(self, raw: bytes) -> None:
        form = urllib.parse.parse_qs(raw.decode())
        if form.get('grant_type') != [
                'urn:ietf:params:oauth:grant-type:jwt-bearer']:
            return self.reply(400, {'error': 'unsupported_grant_type'})
        FAKE.assertions.append(form['assertion'][0])
        self.reply(200, {'access_token': TOKEN, 'expires_in': 3599,
                         'token_type': 'Bearer'})

    def edit(self, edit_id: str) -> dict | None:
        edit = FAKE.edits.get(edit_id)
        if edit is None:
            self.refuse(404, f'Edit {edit_id} not found.')
        return edit

    def route(self, url, call) -> None:
        path, cmd = url.path, self.command
        if cmd == 'POST' and re.fullmatch(APP, path):
            edit_id = f'edit-{FAKE.next_edit}'
            FAKE.next_edit += 1
            FAKE.edits[edit_id] = {'tracks': copy.deepcopy(FAKE.tracks)}
            return self.reply(200, {'id': edit_id,
                                    'expiryTimeSeconds': str(int(time.time()) + 3600)})
        m = re.fullmatch(UPLOAD + r'/([^/]+)/bundles', path)
        if cmd == 'POST' and m:
            if self.edit(m.group(1)) is None:
                return
            if (call['query'].get('uploadType') != ['media']
                    or call['type'] != 'application/octet-stream'):
                return self.refuse(400, 'Media upload expected.')
            return self.reply(200, {'versionCode': FAKE.upload_code,
                                    'sha1': 'x', 'sha256': 'f' * 64})
        m = re.fullmatch(APP + r'/([^/:]+):commit', path)
        if cmd == 'POST' and m:
            edit = self.edit(m.group(1))
            if edit is None:
                return
            FAKE.tracks = edit['tracks']
            del FAKE.edits[m.group(1)]
            return self.reply(200, {'id': m.group(1)})
        m = re.fullmatch(APP + r'/([^/:]+)', path)
        if cmd == 'DELETE' and m:
            if self.edit(m.group(1)) is None:
                return
            del FAKE.edits[m.group(1)]
            return self.reply(204)
        m = re.fullmatch(APP + r'/([^/:]+)/tracks', path)
        if cmd == 'GET' and m:
            edit = self.edit(m.group(1))
            if edit is None:
                return
            return self.reply(200, {
                'kind': 'androidpublisher#tracksListResponse',
                'tracks': [{'track': name, 'releases': releases}
                           for name, releases in edit['tracks'].items()]})
        m = re.fullmatch(APP + r'/([^/:]+)/tracks/([^/]+)', path)
        if m and cmd in ('GET', 'PUT'):
            edit = self.edit(m.group(1))
            if edit is None:
                return
            track = urllib.parse.unquote(m.group(2))
            if cmd == 'GET':
                return self.reply(200, {'track': track, 'releases':
                                        edit['tracks'].get(track, [])})
            body = call['json'] or {}
            if FAKE.draft_app and any(r.get('status') != 'draft'
                                      for r in body.get('releases', [])):
                return self.refuse(400, 'Only releases with status draft may '
                                   'be created on draft app.')
            edit['tracks'][track] = body.get('releases', [])
            return self.reply(200, body)
        self.refuse(404, f'no fake route for {cmd} {path}')

    do_GET = do_POST = do_PUT = do_DELETE = handle_any


# ── running the script ──────────────────────────────────────────────────────

class Env:
    def __init__(self, tmp: pathlib.Path, port: int) -> None:
        self.tmp = tmp
        self.base = f'http://127.0.0.1:{port}'
        self.key = tmp / 'key.pem'
        self.pub = tmp / 'pub.pem'
        subprocess.run(['openssl', 'genpkey', '-algorithm', 'RSA', '-pkeyopt',
                        'rsa_keygen_bits:2048', '-out', str(self.key)],
                       check=True, capture_output=True)
        subprocess.run(['openssl', 'pkey', '-in', str(self.key), '-pubout',
                        '-out', str(self.pub)], check=True, capture_output=True)
        self.private_key = self.key.read_text()
        self.sa = tmp / 'sa.json'
        self.sa.write_text(json.dumps({
            'type': 'service_account',
            'project_id': 'selftest',
            'client_email': 'release@selftest.iam.gserviceaccount.com',
            'private_key': self.private_key,
            'token_uri': f'{self.base}/token',
        }))
        self.aab = tmp / 'app-release.aab'
        self.aab.write_bytes(os.urandom(200_000))
        self.notes = tmp / 'notes.txt'
        self.notes.write_text('Fixes the toaster.\n')
        # The script's PEM temp files land here, so the test can see that
        # none are left behind.
        self.scratch = tmp / 'scratch'
        self.scratch.mkdir()
        self.outputs: list[str] = []

    def run(self, *args: str, sa: str | None = None,
            env: dict | None = None) -> tuple[int, dict, str]:
        full = dict(os.environ)
        full.pop('LB_PLAY_SERVICE_ACCOUNT', None)
        full.update({
            'LB_PLAY_API_BASE': self.base,
            'NO_PROXY': '127.0.0.1,localhost',
            'no_proxy': '127.0.0.1,localhost',
            'TMPDIR': str(self.scratch),
            'HOME': str(self.tmp / 'home'),
        })
        full.update(env or {})
        argv = [sys.executable, str(SCRIPT), *args,
                '--service-account', sa or str(self.sa)]
        proc = subprocess.run(argv, env=full, capture_output=True, text=True,
                              timeout=60)
        self.outputs.append(proc.stdout + proc.stderr)
        lines = proc.stdout.strip().splitlines()
        try:
            summary = json.loads(lines[-1]) if lines else {}
        except ValueError:
            summary = {'unparsed': lines[-1]}
        return proc.returncode, summary, proc.stderr


def internal_track(code: int = 42) -> dict:
    return {'internal': [{
        'name': '0.2.0', 'versionCodes': [str(code)], 'status': 'completed',
        'releaseNotes': [{'language': 'en-US', 'text': 'Tested notes.'}]}]}


# ── the cases ───────────────────────────────────────────────────────────────

def test_jwt(env: Env) -> None:
    check('one JWT was sent to the token endpoint', len(FAKE.assertions) == 1,
          f'{len(FAKE.assertions)} assertions')
    if not FAKE.assertions:
        return
    head64, claims64, sig64 = FAKE.assertions[0].split('.')
    header = json.loads(unb64(head64))
    claims = json.loads(unb64(claims64))
    check('the JWT header is RS256', header == {'alg': 'RS256', 'typ': 'JWT'},
          repr(header))
    check('the JWT claims name the account, scope and token endpoint',
          claims.get('iss') == 'release@selftest.iam.gserviceaccount.com'
          and claims.get('scope') ==
          'https://www.googleapis.com/auth/androidpublisher'
          and claims.get('aud') == f'{env.base}/token', repr(claims))
    check('the JWT lives an hour from now',
          claims.get('exp', 0) - claims.get('iat', 0) == 3600
          and abs(claims.get('iat', 0) - time.time()) < 120, repr(claims))
    data, sig = env.tmp / 'jwt.data', env.tmp / 'jwt.sig'
    data.write_bytes(f'{head64}.{claims64}'.encode())
    sig.write_bytes(unb64(sig64))
    verify = subprocess.run(['openssl', 'dgst', '-sha256', '-verify',
                             str(env.pub), '-signature', str(sig), str(data)],
                            capture_output=True, text=True)
    check('the JWT signature verifies against the public key',
          verify.returncode == 0 and 'Verified OK' in verify.stdout,
          verify.stdout + verify.stderr)
    token_call = FAKE.calls[0]
    check('the token request is a form POST',
          token_call['type'] == 'application/x-www-form-urlencoded',
          token_call['type'])


def test_upload(env: Env) -> None:
    FAKE.reset()
    code, out, err = env.run('upload', '--aab', str(env.aab),
                             '--track', 'internal',
                             '--expect-version-code', '42',
                             '--notes-file', str(env.notes),
                             '--release-name', '0.2.0')
    check('upload exits 0', code == 0, f'exit {code}: {err}')
    test_jwt(env)
    check('upload: edit, bundle, track, commit, in that order',
          FAKE.summary() == [
              'POST /token',
              'POST /androidpublisher/v3/app/edits',
              'POST /upload/androidpublisher/v3/app/edits/edit-1/bundles',
              'PUT /androidpublisher/v3/app/edits/edit-1/tracks/internal',
              'POST /androidpublisher/v3/app/edits/edit-1:commit'],
          repr(FAKE.summary()))
    upload = FAKE.calls[2]
    check('the AAB is sent whole as a media upload',
          upload['raw'] == env.aab.read_bytes()
          and upload['query'].get('uploadType') == ['media']
          and upload['type'] == 'application/octet-stream',
          f"{len(upload['raw'])} bytes, {upload['type']}")
    check('the track gets one completed release with notes and a name',
          FAKE.put_bodies() == [{'track': 'internal', 'releases': [{
              'versionCodes': ['42'], 'status': 'completed', 'name': '0.2.0',
              'releaseNotes': [{'language': 'en-US',
                                'text': 'Fixes the toaster.'}]}]}],
          repr(FAKE.put_bodies()))
    check('the release is live on internal after the commit',
          FAKE.tracks.get('internal', [{}])[0].get('versionCodes') == ['42']
          and not FAKE.edits, repr(FAKE.tracks))
    check('upload stdout JSON carries versionCode, track and status',
          out.get('ok') is True and out.get('versionCode') == 42
          and out.get('track') == 'internal' and out.get('status') == 'completed'
          and out.get('exit') == 0, repr(out))


def test_upload_mismatch(env: Env) -> None:
    FAKE.reset(upload_code=43)
    code, out, err = env.run('upload', '--aab', str(env.aab),
                             '--expect-version-code', '41')
    check('a versionCode mismatch exits 1', code == 1, f'exit {code}')
    check('the mismatch is explained', '43' in err and '41' in err, err)
    check('a versionCode mismatch deletes the edit and commits nothing',
          'DELETE /androidpublisher/v3/app/edits/edit-1' in FAKE.summary()
          and not any(':commit' in s or s.startswith('PUT')
                      for s in FAKE.summary())
          and not FAKE.edits and not FAKE.tracks, repr(FAKE.summary()))
    check('mismatch stdout JSON says not ok',
          out.get('ok') is False and out.get('exit') == 1, repr(out))


def test_draft_app(env: Env) -> None:
    FAKE.reset(draft_app=True)
    code, out, err = env.run('upload', '--aab', str(env.aab),
                             '--notes-file', str(env.notes))
    check('a draft app upload exits 0', code == 0, f'exit {code}: {err}')
    bodies = FAKE.put_bodies()
    check('the refused completed release is retried as a draft in one edit',
          [b['releases'][0]['status'] for b in bodies] == ['completed', 'draft']
          and FAKE.summary().count('POST /androidpublisher/v3/app/edits') == 1
          and FAKE.summary()[-1].endswith('edit-1:commit'), repr(FAKE.summary()))
    check('the draft keeps its notes',
          bodies[-1]['releases'][0].get('releaseNotes') ==
          [{'language': 'en-US', 'text': 'Fixes the toaster.'}], repr(bodies))
    check('the human is told to roll the draft out in Play Console',
          'Play Console' in err and 'DRAFT' in err, err)
    check('draft upload stdout JSON says draft',
          out.get('status') == 'draft' and out.get('versionCode') == 42,
          repr(out))

    FAKE.reset(draft_app=True, tracks=internal_track())
    code, out, err = env.run('promote', '--version-code', '42',
                             '--user-fraction', '0.2')
    release = FAKE.tracks.get('production', [{}])[0]
    check('a draft app promote lands a draft without a userFraction',
          code == 0 and release.get('status') == 'draft'
          and 'userFraction' not in release and out.get('status') == 'draft',
          f'exit {code}, {release}, {out}')


def test_promote(env: Env) -> None:
    FAKE.reset(tracks=internal_track())
    code, out, err = env.run('promote', '--version-code', '42',
                             '--from', 'internal', '--to', 'production',
                             '--user-fraction', '0.1')
    check('promote exits 0', code == 0, f'exit {code}: {err}')
    check('promote reads the source track, writes the target, commits',
          FAKE.summary()[1:] == [
              'POST /androidpublisher/v3/app/edits',
              'GET /androidpublisher/v3/app/edits/edit-1/tracks/internal',
              'PUT /androidpublisher/v3/app/edits/edit-1/tracks/production',
              'POST /androidpublisher/v3/app/edits/edit-1:commit'],
          repr(FAKE.summary()))
    check('promote never uploads',
          not any('/upload/' in s for s in FAKE.summary()))
    check('a userFraction promote is a staged inProgress release',
          FAKE.put_bodies() == [{'track': 'production', 'releases': [{
              'versionCodes': ['42'], 'status': 'inProgress',
              'userFraction': 0.1, 'name': '0.2.0',
              'releaseNotes': [{'language': 'en-US',
                                'text': 'Tested notes.'}]}]}],
          repr(FAKE.put_bodies()))
    check('staged promote stdout JSON',
          out.get('status') == 'inProgress' and out.get('userFraction') == 0.1
          and out.get('from') == 'internal' and out.get('to') == 'production',
          repr(out))

    FAKE.reset(tracks=internal_track())
    code, out, err = env.run('promote', '--version-code', '42',
                             '--notes-file', str(env.notes),
                             '--release-name', '0.2.0 (42)')
    release = FAKE.tracks.get('production', [{}])[0]
    check('promote without a fraction completes, with the given notes',
          code == 0 and release.get('status') == 'completed'
          and 'userFraction' not in release
          and release.get('name') == '0.2.0 (42)'
          and release.get('releaseNotes')[0]['text'] == 'Fixes the toaster.'
          and out.get('status') == 'completed', f'exit {code}, {release}')

    FAKE.reset(tracks=internal_track(41))
    code, out, err = env.run('promote', '--version-code', '42')
    check('promoting a versionCode not on the source track exits 1',
          code == 1 and 'internal' in err, f'exit {code}: {err}')
    check('... deletes the edit and touches no track',
          not any(s.startswith('PUT') or ':commit' in s
                  for s in FAKE.summary())
          and 'DELETE /androidpublisher/v3/app/edits/edit-1' in FAKE.summary()
          and not FAKE.edits and 'production' not in FAKE.tracks,
          repr(FAKE.summary()))


def test_rollout(env: Env) -> None:
    staged = {'production': [
        {'versionCodes': ['40'], 'status': 'completed'},
        {'versionCodes': ['42'], 'status': 'inProgress', 'userFraction': 0.1,
         'name': '0.2.0'}]}
    FAKE.reset(tracks=staged)
    code, out, err = env.run('rollout', '--track', 'production',
                             '--version-code', '42', '--complete')
    check('rollout --complete exits 0', code == 0, f'exit {code}: {err}')
    check('rollout --complete sends the release completed, without a fraction',
          FAKE.put_bodies() == [{'track': 'production', 'releases': [{
              'versionCodes': ['42'], 'status': 'completed',
              'name': '0.2.0'}]}], repr(FAKE.put_bodies()))
    check('rollout --complete commits',
          FAKE.summary()[-1].endswith(':commit') and not FAKE.edits,
          repr(FAKE.summary()))
    check('rollout stdout JSON',
          out.get('status') == 'completed' and out.get('userFraction') is None
          and out.get('track') == 'production', repr(out))

    FAKE.reset(tracks=staged)
    code, out, err = env.run('rollout', '--version-code', '42',
                             '--user-fraction', '0.5')
    check('rollout --user-fraction widens the staged release',
          code == 0 and FAKE.tracks['production'][0].get('userFraction') == 0.5
          and FAKE.tracks['production'][0].get('status') == 'inProgress',
          f'exit {code}, {FAKE.tracks}')

    FAKE.reset(tracks=staged)
    code, out, err = env.run('rollout', '--version-code', '42', '--halt')
    check('rollout --halt halts it',
          code == 0 and FAKE.tracks['production'][0].get('status') == 'halted',
          f'exit {code}, {FAKE.tracks}')

    FAKE.reset(tracks=staged)
    code, out, err = env.run('rollout', '--version-code', '99', '--complete')
    check('rollout of a versionCode not on the track exits 1, edit deleted',
          code == 1 and not FAKE.edits and FAKE.tracks == staged
          and FAKE.summary()[-1].startswith('DELETE'), f'exit {code}')


def test_status(env: Env) -> None:
    tracks = {**internal_track(), 'production': [
        {'versionCodes': ['42'], 'status': 'inProgress', 'userFraction': 0.2}],
        'beta': []}
    FAKE.reset(tracks=tracks)
    code, out, err = env.run('status', '--version-code', '42')
    check('status of a released versionCode exits 0', code == 0,
          f'exit {code}: {err}')
    check('status lists each track carrying it',
          out.get('found') is True and out.get('ok') is True
          and sorted((t['track'], t['status'], t['userFraction'])
                     for t in out.get('tracks', [])) ==
          [('internal', 'completed', None), ('production', 'inProgress', 0.2)],
          repr(out))
    check('status deletes its edit',
          FAKE.summary()[-1] == 'DELETE /androidpublisher/v3/app/edits/edit-1'
          and not FAKE.edits and FAKE.tracks == tracks, repr(FAKE.summary()))

    FAKE.reset(tracks=tracks)
    code, out, err = env.run('status', '--version-code', '7')
    check('status of an unknown versionCode exits 3', code == 3, f'exit {code}')
    check('... says not found and deletes its edit',
          out.get('found') is False and out.get('tracks') == []
          and not FAKE.edits, repr(out))


def test_not_configured(env: Env) -> None:
    FAKE.reset()
    missing = str(env.tmp / 'nowhere.json')
    code, out, err = env.run('upload', '--aab', str(env.aab), sa=missing)
    check('a missing service account exits 2 and calls nothing',
          code == 2 and FAKE.calls == [] and missing in err,
          f'exit {code}, {len(FAKE.calls)} calls: {err}')
    check('... with a not-ok JSON line', out.get('ok') is False
          and out.get('exit') == 2 and out.get('command') == 'upload',
          repr(out))

    # The default path is under $HOME, which is empty here.
    argv = [sys.executable, str(SCRIPT), 'status', '--version-code', '1']
    proc = subprocess.run(argv, capture_output=True, text=True, env={
        **{k: v for k, v in os.environ.items()
           if k != 'LB_PLAY_SERVICE_ACCOUNT'},
        'HOME': str(env.tmp / 'home'), 'LB_PLAY_API_BASE': env.base})
    check('with no flag or env, the default path is used and is missing',
          proc.returncode == 2 and FAKE.calls == []
          and '.config/liberatedbread/play-service-account.json' in proc.stderr,
          proc.stderr)

    code, out, err = env.run('status', '--version-code', '1', sa=missing,
                             env={'LB_PLAY_SERVICE_ACCOUNT': str(env.sa)})
    check('--service-account wins over LB_PLAY_SERVICE_ACCOUNT',
          code == 2 and FAKE.calls == [], f'exit {code}')

    argv = [sys.executable, str(SCRIPT), 'status', '--version-code', '42']
    FAKE.reset(tracks=internal_track())
    proc = subprocess.run(argv, capture_output=True, text=True, env={
        **os.environ, 'LB_PLAY_SERVICE_ACCOUNT': str(env.sa),
        'LB_PLAY_API_BASE': env.base, 'NO_PROXY': '127.0.0.1',
        'no_proxy': '127.0.0.1', 'TMPDIR': str(env.scratch)})
    env.outputs.append(proc.stdout + proc.stderr)
    check('LB_PLAY_SERVICE_ACCOUNT is used when there is no flag',
          proc.returncode == 0, proc.stderr)

    FAKE.reset()
    code, out, err = env.run('rollout', '--version-code', '1')
    check('bad arguments exit 2 with a JSON line and call nothing',
          code == 2 and out.get('ok') is False and FAKE.calls == [],
          f'exit {code}, {out}')


def test_api_error(env: Env) -> None:
    message = 'The caller does not have permission'
    FAKE.reset(fail=('POST', r'/edits$', 403, message))
    code, out, err = env.run('upload', '--aab', str(env.aab))
    check("an API refusal exits 1 and prints Play's message",
          code == 1 and message in err and 'HTTP 403' in err,
          f'exit {code}: {err}')
    check('... and the JSON line carries it',
          out.get('ok') is False and message in out.get('error', ''),
          repr(out))

    message = 'APK specifies a version code that has already been used.'
    FAKE.reset(fail=('POST', r'/bundles$', 403, message))
    code, out, err = env.run('upload', '--aab', str(env.aab))
    check('a refused upload exits 1 with the message and deletes the edit',
          code == 1 and message in err and not FAKE.edits
          and FAKE.summary()[-1].startswith('DELETE'), f'exit {code}: {err}')


def main() -> int:
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            env = Env(pathlib.Path(tmp), server.server_address[1])
            test_upload(env)
            test_upload_mismatch(env)
            test_draft_app(env)
            test_promote(env)
            test_rollout(env)
            test_status(env)
            test_not_configured(env)
            test_api_error(env)

            everything = '\n'.join(env.outputs)
            check('no run printed the access token', TOKEN not in everything)
            body = ''.join(env.private_key.strip().splitlines()[1:-1])
            check('no run printed the private key',
                  body[:40] not in everything.replace('\n', ''))
            check('every signing key copy was deleted',
                  os.listdir(env.scratch) == [], repr(os.listdir(env.scratch)))
    finally:
        server.shutdown()
        server.server_close()

    if _status == 0:
        print('play_publish selftest: all passed')
    return _status


if __name__ == '__main__':
    raise SystemExit(main())
