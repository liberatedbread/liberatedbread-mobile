#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Drives the Google Play Developer API (androidpublisher v3) for a release.

scripts/release-android.sh used to stop twice and ask a human to click through
Play Console: once to upload the AAB to Internal testing, and once to promote
the tested release to Production. Both are a handful of API calls, and the
console steps are where releases go wrong (the wrong file, a rebuilt AAB
promoted instead of the tested one, Production picked instead of Internal).
With a service account configured, this script does those steps; without one
it exits 2 and the bash side prints the old manual instructions, so a machine
that has never been set up for the API releases exactly as before.

Stdlib only, Python 3.9 (macOS's system python3), because the release runs on
whatever laptop holds the upload keystore and must not need a virtualenv or
google-auth. The one thing the stdlib cannot do is RSA signing, so the JWT is
signed by the openssl CLI that every Mac and Linux box already has.

Usage:
  play_publish.py upload  --aab PATH [--track internal] [--expect-version-code N]
                          [--notes-file F] [--release-name NAME]
  play_publish.py promote --version-code N [--from internal] [--to production]
                          [--user-fraction F] [--notes-file F] [--release-name NAME]
  play_publish.py rollout --version-code N [--track production]
                          (--user-fraction F | --complete | --halt)
  play_publish.py status  --version-code N
Common: [--service-account PATH] [--package ca.pigscanfly.liberatedbread]
        [--language en-US]

Exit codes:
  0  done (status: the versionCode is on at least one track)
  1  Play refused, or the result was not what was asked; any edit is deleted
  2  nothing was attempted: no service account, no openssl, or bad arguments
  3  status only: no track has a release with that versionCode

Progress goes to stderr. The last line on stdout is always one JSON object,
{"ok": true|false, "command": ..., ...}, for the caller to parse.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_PACKAGE = 'ca.pigscanfly.liberatedbread'
DEFAULT_LANGUAGE = 'en-US'
DEFAULT_API_BASE = 'https://androidpublisher.googleapis.com'
DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token'
DEFAULT_SA_PATH = '~/.config/liberatedbread/play-service-account.json'
SCOPE = 'https://www.googleapis.com/auth/androidpublisher'

# Every call but the upload is a small JSON exchange; the upload carries a
# release AAB of tens of MB over whatever uplink the release laptop has, and a
# timeout there would leave a human wondering whether Play got the bundle.
API_TIMEOUT = 60
UPLOAD_TIMEOUT = 900

EXIT_OK, EXIT_FAILED, EXIT_NOT_RUN, EXIT_NOT_FOUND = 0, 1, 2, 3


class Failure(Exception):
    """Play refused, or answered with something other than what was asked."""


class NotRun(Exception):
    """Nothing was sent to Play; the caller should fall back to the console."""


def log(message: str) -> None:
    print(f'play_publish: {message}', file=sys.stderr, flush=True)


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


# ── credentials ─────────────────────────────────────────────────────────────

def service_account_path(flag: str | None) -> str:
    raw = flag or os.environ.get('LB_PLAY_SERVICE_ACCOUNT') or DEFAULT_SA_PATH
    return os.path.expanduser(raw)


def load_service_account(path: str) -> dict:
    if not os.path.isfile(path):
        raise NotRun(f'no Play service account at {path}. Pass '
                     '--service-account or set LB_PLAY_SERVICE_ACCOUNT to use '
                     'the API.')
    try:
        with open(path, encoding='utf-8') as handle:
            info = json.load(handle)
    except (OSError, ValueError) as error:
        raise NotRun(f'cannot read the service account {path}: '
                     f'{type(error).__name__}') from None
    missing = [k for k in ('client_email', 'private_key') if not info.get(k)]
    if missing:
        raise NotRun(f'the service account {path} has no {", ".join(missing)}; '
                     'download a JSON key for it from Google Cloud.')
    return info


def sign_rs256(pem: str, data: bytes) -> bytes:
    if not shutil.which('openssl'):
        raise NotRun('openssl is not on PATH; it signs the service-account JWT.')
    # openssl reads the key from a file, so the key touches disk: mkstemp
    # creates it owner-only, and it is gone before this returns whatever
    # happens, so a crash cannot leave a Play publishing key in /tmp.
    fd, key_path = tempfile.mkstemp(prefix='play-sa-', suffix='.pem')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            handle.write(pem)
        proc = subprocess.run(
            ['openssl', 'dgst', '-sha256', '-sign', key_path],
            input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=False)
    finally:
        os.unlink(key_path)
    if proc.returncode != 0 or not proc.stdout:
        # openssl's stderr names the parse failure, never the key material.
        detail = proc.stderr.decode('utf-8', 'replace').strip().splitlines()
        raise NotRun('openssl could not sign with the service-account key'
                     + (f': {detail[0]}' if detail else '.'))
    return proc.stdout


def make_jwt(info: dict, now: int | None = None) -> str:
    iat = int(time.time()) if now is None else now
    header = {'alg': 'RS256', 'typ': 'JWT'}
    claims = {
        'iss': info['client_email'],
        'scope': SCOPE,
        'aud': info.get('token_uri') or DEFAULT_TOKEN_URI,
        'iat': iat,
        'exp': iat + 3600,
    }
    signing_input = (b64url(json.dumps(header, separators=(',', ':')).encode())
                     + '.'
                     + b64url(json.dumps(claims, separators=(',', ':')).encode()))
    signature = sign_rs256(info['private_key'], signing_input.encode('ascii'))
    return signing_input + '.' + b64url(signature)


# ── HTTP ────────────────────────────────────────────────────────────────────

def error_message(body: bytes) -> str:
    """Play's own words for a refusal, which are what a human can act on."""
    text = body.decode('utf-8', 'replace')
    try:
        parsed = json.loads(text)
    except ValueError:
        return text.strip()[:500] or '(empty response)'
    error = parsed.get('error') if isinstance(parsed, dict) else None
    if isinstance(error, dict):
        return str(error.get('message') or error.get('status') or error)
    if isinstance(error, str):
        # The OAuth token endpoint's shape, not the API's.
        described = parsed.get('error_description')
        return f'{error}: {described}' if described else error
    return text.strip()[:500]


def request(method: str, url: str, *, token: str | None = None,
            body: object = None, raw=None, content_type: str | None = None,
            length: int | None = None, timeout: int = API_TIMEOUT) -> dict:
    """One call. urllib, so HTTPS_PROXY/NO_PROXY are honoured as curl would."""
    headers = {'Accept': 'application/json'}
    data = raw
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        content_type = content_type or 'application/json; charset=utf-8'
    if content_type:
        headers['Content-Type'] = content_type
    if length is not None:
        headers['Content-Length'] = str(length)
    if token:
        headers['Authorization'] = f'Bearer {token}'
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    where = f'{method} {urllib.parse.urlsplit(url).path}'
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = resp.read()
    except urllib.error.HTTPError as error:
        raise Failure(f'{where}: HTTP {error.code}: '
                      f'{error_message(error.read())}') from None
    except (urllib.error.URLError, OSError) as error:
        reason = getattr(error, 'reason', error)
        raise Failure(f'{where}: {reason}') from None
    if not payload.strip():
        return {}
    try:
        return json.loads(payload)
    except ValueError:
        raise Failure(f'{where}: the response was not JSON') from None


def access_token(info: dict) -> str:
    token_uri = info.get('token_uri') or DEFAULT_TOKEN_URI
    form = urllib.parse.urlencode({
        'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        'assertion': make_jwt(info),
    }).encode('ascii')
    log(f'signing in as {info["client_email"]}')
    reply = request('POST', token_uri, raw=form,
                    content_type='application/x-www-form-urlencoded')
    token = reply.get('access_token')
    if not token:
        raise Failure(f'POST {token_uri}: no access_token in the reply')
    return token


class Play:
    def __init__(self, base: str, package: str, token: str) -> None:
        self.base = base.rstrip('/')
        self.package = package
        self.token = token

    def _app(self, upload: bool = False) -> str:
        prefix = '/upload' if upload else ''
        pkg = urllib.parse.quote(self.package, safe='')
        return f'{self.base}{prefix}/androidpublisher/v3/applications/{pkg}'

    def call(self, method: str, path: str, body: object = None) -> dict:
        return request(method, self._app() + '/edits' + path,
                       token=self.token, body=body)

    def upload_bundle(self, edit_id: str, aab: str) -> dict:
        url = (f'{self._app(upload=True)}/edits/{edit_id}/bundles'
               '?uploadType=media')
        size = os.path.getsize(aab)
        # Streamed from the file rather than read whole: urllib sends a file
        # object in blocks once it knows the length.
        with open(aab, 'rb') as handle:
            return request('POST', url, token=self.token, raw=handle,
                           content_type='application/octet-stream',
                           length=size, timeout=UPLOAD_TIMEOUT)


class Edit:
    """A Play edit that is always either committed or deleted.

    An edit left open is never useful (Play invalidates every open edit as
    soon as any edit for the app is committed, the console's included), and
    deleting it is the one unambiguous record that this run changed nothing.
    """

    def __init__(self, play: Play) -> None:
        self.play = play
        self.id = ''
        self.done = False

    def __enter__(self) -> 'Edit':
        self.id = self.play.call('POST', '', {}).get('id', '')
        if not self.id:
            raise Failure('POST edits: Play returned no edit id')
        log(f'opened edit {self.id}')
        return self

    def __exit__(self, *_exc) -> None:
        if self.done or not self.id:
            return
        try:
            self.play.call('DELETE', f'/{self.id}')
            log(f'deleted edit {self.id}; nothing was changed in Play')
        except Failure as error:
            log(f'could not delete edit {self.id}: {error}')

    def get_track(self, track: str) -> dict:
        return self.play.call('GET', f'/{self.id}/tracks/{quote(track)}')

    def put_track(self, track: str, releases: list) -> dict:
        return self.play.call('PUT', f'/{self.id}/tracks/{quote(track)}',
                              {'track': track, 'releases': releases})

    def commit(self) -> None:
        # changesNotSentForReview is deliberately left out. Setting it true
        # holds the changes back until someone presses "Send for review" in
        # the console, which would make an "uploaded" release silently not
        # go anywhere. Play only demands it when the app is in a state that
        # needs a human anyway (managed publishing, a rejected update), and
        # then the commit fails with a message saying so and the release
        # falls back to the console.
        self.play.call('POST', f'/{self.id}:commit')
        self.done = True
        log(f'committed edit {self.id}')


def quote(segment: str) -> str:
    return urllib.parse.quote(segment, safe='')


# ── releases ────────────────────────────────────────────────────────────────

def has_code(release: dict, version_code: int) -> bool:
    return str(version_code) in [str(v) for v in release.get('versionCodes', [])]


def find_release(track: dict, version_code: int) -> dict | None:
    for release in track.get('releases', []) or []:
        if has_code(release, version_code):
            return release
    return None


def read_notes(path: str | None, language: str) -> list | None:
    if not path:
        return None
    with open(path, encoding='utf-8') as handle:
        text = handle.read().strip()
    return [{'language': language, 'text': text}] if text else None


def is_draft_app_refusal(error: Failure) -> bool:
    # A never-published app accepts only draft releases until its first
    # rollout is started in the console; Play says so in the message
    # ("Only releases with status draft may be created on draft app.").
    return 'draft' in str(error).lower()


def put_release(edit: Edit, track: str, release: dict) -> str:
    """Puts one release on a track, as a draft if the app is still a draft.

    Only the new release is sent: Play keeps the releases still serving on the
    track (the completed one a staged rollout is replacing) on its own, and
    re-sending them would ask for two completed releases at once.
    """
    try:
        edit.put_track(track, [release])
        return release['status']
    except Failure as error:
        if not is_draft_app_refusal(error) or release['status'] == 'draft':
            raise
        log(f'Play refused a {release["status"]} release: {error}')
        draft = {k: v for k, v in release.items() if k != 'userFraction'}
        draft['status'] = 'draft'
        edit.put_track(track, [draft])
        log('this app has never been published, so Play takes only drafts. '
            f'The release is a DRAFT on {track}: start its rollout by hand in '
            'Play Console.')
        return 'draft'


def percent(fraction: float) -> str:
    return f'{fraction * 100:g}%'


def staged_status(fraction: float | None) -> tuple[str, float | None]:
    if fraction is not None and 0 < fraction < 1:
        return 'inProgress', fraction
    return 'completed', None


# ── subcommands ─────────────────────────────────────────────────────────────

def cmd_upload(args, play: Play) -> tuple[int, dict]:
    notes = read_notes(args.notes_file, args.language)
    with Edit(play) as edit:
        log(f'uploading {args.aab} ({os.path.getsize(args.aab)} bytes)')
        bundle = play.upload_bundle(edit.id, args.aab)
        code = bundle.get('versionCode')
        if code is None:
            raise Failure('Play accepted the upload but returned no versionCode')
        code = int(code)
        log(f'Play has the bundle: versionCode {code}')
        if args.expect_version_code is not None and code != args.expect_version_code:
            raise Failure(f'the bundle is versionCode {code}, expected '
                          f'{args.expect_version_code}; not releasing it')
        release = {'versionCodes': [str(code)], 'status': 'completed'}
        if args.release_name:
            release['name'] = args.release_name
        if notes:
            release['releaseNotes'] = notes
        status = put_release(edit, args.track, release)
        edit.commit()
    log(f'versionCode {code} is on {args.track} ({status})')
    return EXIT_OK, {'versionCode': code, 'track': args.track,
                     'status': status, 'sha256': bundle.get('sha256')}


def cmd_promote(args, play: Play) -> tuple[int, dict]:
    notes = read_notes(args.notes_file, args.language)
    code = args.version_code
    with Edit(play) as edit:
        source = find_release(edit.get_track(args.source), code)
        if source is None:
            raise Failure(f'no release on {args.source} has versionCode {code}; '
                          'promote only what was tested')
        status, fraction = staged_status(args.user_fraction)
        release = {'versionCodes': [str(code)], 'status': status}
        # The tested release's name and notes come along unless replaced, as
        # the console's "Promote release" does.
        name = args.release_name or source.get('name')
        if name:
            release['name'] = name
        notes = notes or source.get('releaseNotes')
        if notes:
            release['releaseNotes'] = notes
        if fraction is not None:
            release['userFraction'] = fraction
        status = put_release(edit, args.target, release)
        edit.commit()
    if status != 'draft':
        fraction_note = f' to {percent(fraction)} of users' if fraction else ''
        log(f'versionCode {code} promoted {args.source} -> {args.target}: '
            f'{status}{fraction_note}')
    return EXIT_OK, {'versionCode': code, 'from': args.source,
                     'to': args.target, 'status': status,
                     'userFraction': fraction if status == 'inProgress' else None}


def cmd_rollout(args, play: Play) -> tuple[int, dict]:
    code = args.version_code
    with Edit(play) as edit:
        current = find_release(edit.get_track(args.track), code)
        if current is None:
            raise Failure(f'no release on {args.track} has versionCode {code}')
        release = dict(current)
        if args.complete:
            release['status'] = 'completed'
            release.pop('userFraction', None)
        elif args.halt:
            release['status'] = 'halted'
        else:
            release['status'] = 'inProgress'
            release['userFraction'] = args.user_fraction
        edit.put_track(args.track, [release])
        edit.commit()
    fraction = release.get('userFraction')
    log(f'versionCode {code} on {args.track}: {release["status"]}'
        + (f' ({percent(fraction)})' if fraction else ''))
    return EXIT_OK, {'versionCode': code, 'track': args.track,
                     'status': release['status'], 'userFraction': fraction}


def cmd_status(args, play: Play) -> tuple[int, dict]:
    code = args.version_code
    found = []
    with Edit(play) as edit:
        # Read-only: the edit is deleted on the way out, never committed.
        listing = play.call('GET', f'/{edit.id}/tracks')
    for track in listing.get('tracks', []) or []:
        for release in track.get('releases', []) or []:
            if has_code(release, code):
                found.append({'track': track.get('track'),
                              'status': release.get('status'),
                              'userFraction': release.get('userFraction'),
                              'name': release.get('name')})
    for entry in found:
        fraction = entry['userFraction']
        print(f"{entry['track']}: {entry['status']}"
              + (f' ({percent(fraction)})' if fraction else ''), file=sys.stderr)
    if not found:
        log(f'versionCode {code} is on no track')
    return (EXIT_OK if found else EXIT_NOT_FOUND,
            {'versionCode': code, 'found': bool(found), 'tracks': found})


# ── command line ────────────────────────────────────────────────────────────

class Usage(Exception):
    pass


class Parser(argparse.ArgumentParser):
    # Bad arguments still owe the caller its JSON line, and must read as
    # "nothing attempted" (2), which happens to be argparse's code too.
    def error(self, message: str):
        raise Usage(f'{self.prog}: {message}')


def fraction(text: str) -> float:
    value = float(text)
    if not 0 < value <= 1:
        raise argparse.ArgumentTypeError('must be in (0, 1]')
    return value


def parse(argv: list[str]) -> argparse.Namespace:
    common = Parser(add_help=False)
    common.add_argument('--service-account', metavar='PATH',
                        help='service-account JSON key (default: '
                        '$LB_PLAY_SERVICE_ACCOUNT, else ' + DEFAULT_SA_PATH + ')')
    common.add_argument('--package', default=DEFAULT_PACKAGE)
    common.add_argument('--language', default=DEFAULT_LANGUAGE,
                        help='language of --notes-file (default %(default)s)')

    parser = Parser(prog='play_publish.py',
                    description='Google Play releases through the API.')
    sub = parser.add_subparsers(dest='command', metavar='COMMAND')
    sub.required = True

    p = sub.add_parser('upload', parents=[common],
                       help='upload an AAB and release it on a testing track')
    p.add_argument('--aab', required=True, metavar='PATH')
    p.add_argument('--track', default='internal')
    p.add_argument('--expect-version-code', type=int, metavar='N')
    p.add_argument('--notes-file', metavar='F')
    p.add_argument('--release-name', metavar='NAME')
    p.set_defaults(func=cmd_upload)

    p = sub.add_parser('promote', parents=[common],
                       help='carry a tested release to another track')
    p.add_argument('--version-code', type=int, required=True, metavar='N')
    p.add_argument('--from', dest='source', default='internal')
    p.add_argument('--to', dest='target', default='production')
    p.add_argument('--user-fraction', type=fraction, metavar='F',
                   help='staged rollout fraction, 0 < F < 1 (1 = everyone)')
    p.add_argument('--notes-file', metavar='F')
    p.add_argument('--release-name', metavar='NAME')
    p.set_defaults(func=cmd_promote)

    p = sub.add_parser('rollout', parents=[common],
                       help='widen, complete or halt a staged release')
    p.add_argument('--version-code', type=int, required=True, metavar='N')
    p.add_argument('--track', default='production')
    how = p.add_mutually_exclusive_group(required=True)
    how.add_argument('--user-fraction', type=fraction, metavar='F')
    how.add_argument('--complete', action='store_true')
    how.add_argument('--halt', action='store_true')
    p.set_defaults(func=cmd_rollout)

    p = sub.add_parser('status', parents=[common],
                       help='which tracks carry a versionCode')
    p.add_argument('--version-code', type=int, required=True, metavar='N')
    p.set_defaults(func=cmd_status)

    args = parser.parse_args(argv)
    if args.command == 'rollout' and args.user_fraction == 1:
        raise Usage('play_publish.py rollout: use --complete for 1')
    if args.command == 'upload' and not os.path.isfile(args.aab):
        raise Usage(f'play_publish.py upload: no AAB at {args.aab}')
    notes = getattr(args, 'notes_file', None)
    if notes and not os.path.isfile(notes):
        raise Usage(f'play_publish.py {args.command}: no notes file at {notes}')
    return args


def emit(summary: dict) -> None:
    print(json.dumps(summary), flush=True)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    command = next((a for a in argv if not a.startswith('-')), None)
    try:
        args = parse(argv)
    except Usage as error:
        print(error, file=sys.stderr)
        emit({'ok': False, 'command': command, 'exit': EXIT_NOT_RUN,
              'error': str(error)})
        return EXIT_NOT_RUN

    base = {'command': args.command, 'package': args.package}
    try:
        info = load_service_account(service_account_path(args.service_account))
        api_base = os.environ.get('LB_PLAY_API_BASE') or DEFAULT_API_BASE
        play = Play(api_base, args.package, access_token(info))
        code, result = args.func(args, play)
    except NotRun as error:
        log(str(error))
        emit({'ok': False, **base, 'exit': EXIT_NOT_RUN, 'error': str(error)})
        return EXIT_NOT_RUN
    except Failure as error:
        log(f'FAILED: {error}')
        emit({'ok': False, **base, 'exit': EXIT_FAILED, 'error': str(error)})
        return EXIT_FAILED
    # A versionCode on no track is an answer, not an error.
    emit({'ok': True, **base, 'exit': code, **result})
    return code


if __name__ == '__main__':
    raise SystemExit(main())
