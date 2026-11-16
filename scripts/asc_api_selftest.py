#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""Drives scripts/asc_api.py against a fake App Store Connect.

asc_api.py acts on the real store with a real key: selecting a build,
submitting for review and releasing cannot be tried out against Apple
without doing them. So this runs it, as release-apple.sh does, against an
in-memory fake of the endpoints it calls, and checks both what it asked
for and what it told the bash side (exit code, last-line JSON). The JWT is
checked the way Apple would: the r||s signature is turned back into DER and
verified by openssl against the key's public half, since a signature that
is merely well-formed is still refused with a 401.

Stdlib and the openssl binary only; the fake listens on 127.0.0.1 with an
ephemeral port, and NO_PROXY keeps an inherited HTTPS_PROXY out of the way.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

HERE = pathlib.Path(__file__).resolve().parent
SCRIPT = HERE / 'asc_api.py'

KEY_ID = 'TESTKEY123'
ISSUER = '69a6de7e-0000-47e3-e053-5b8c7c11a4d1'
BUNDLE = 'ca.pigscanfly.liberatedbread'
APP_ID = '6400000001'
FORBIDDEN_BUNDLE = 'ca.pigscanfly.forbidden'

_status = 0


def check(label: str, ok: bool, detail: str = '') -> None:
    global _status
    if ok:
        print(f'  ok    {label}')
    else:
        _status = 1
        print(f'  FAIL  {label}{": " + detail if detail else ""}',
              file=sys.stderr)


def load():
    spec = importlib.util.spec_from_file_location('asc_api', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + '=' * (-len(text) % 4))


def raw_to_der(raw: bytes) -> bytes:
    """The inverse of asc_api.der_signature_to_raw, for openssl -verify."""
    def integer(value: bytes) -> bytes:
        value = value.lstrip(b'\x00') or b'\x00'
        if value[0] & 0x80:
            value = b'\x00' + value
        return b'\x02' + bytes([len(value)]) + value
    body = integer(raw[:32]) + integer(raw[32:])
    return b'\x30' + bytes([len(body)]) + body


# ── the fake App Store Connect ───────────────────────────────────────────────


class Fake:
    """In-memory App Store Connect state; reset() before each scenario."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.reset()

    def reset(self, **kw: Any) -> None:
        self.requests: List[Dict[str, Any]] = []
        # Each GET /v1/builds moves one step along the script and stays on the
        # last step; None is "not visible yet".
        self.build_script: List[Optional[Tuple[str, str]]] = kw.get(
            'build_script', [('VALID', 'READY_FOR_BETA_TESTING')])
        self.build_step = 0
        self.groups: List[Dict[str, Any]] = kw.get('groups', [])
        self.group_builds: Dict[str, List[str]] = {g['id']: [] for g in self.groups}
        self.versions: Dict[str, Dict[str, Any]] = kw.get('versions', {})
        self.localizations: Dict[str, Dict[str, Any]] = kw.get('localizations', {})
        self.refuse_whats_new = kw.get('refuse_whats_new', False)
        self.submissions: Dict[str, Dict[str, Any]] = kw.get('submissions', {})
        self.release_requests: List[str] = []
        self.next_id = 100

    def new_id(self, prefix: str) -> str:
        self.next_id += 1
        return f'{prefix}-{self.next_id}'

    def calls(self, method: str, path_start: str) -> List[Dict[str, Any]]:
        return [r for r in self.requests
                if r['method'] == method and r['path'].startswith(path_start)]


FAKE = Fake()
# Every bearer token the fake has seen, across resets, for the leak check.
SEEN_TOKENS: set = set()
BUILD_ID = 'build-1'
BUILD_NUMBER = '202611161200'
VERSION = '0.2.0'


def error(status: int, title: str, detail: str) -> Tuple[int, Dict[str, Any]]:
    return status, {'errors': [{'status': str(status), 'code': 'TEST',
                                'title': title, 'detail': detail}]}


def version_resource(vid: str) -> Dict[str, Any]:
    v = FAKE.versions[vid]
    return {'type': 'appStoreVersions', 'id': vid, 'attributes': {
        'platform': 'IOS', 'versionString': v['versionString'],
        'appStoreState': v['state'], 'appVersionState': v['state']}}


def handle(method: str, path: str, query: Dict[str, str],
           body: Optional[Dict[str, Any]]) -> Tuple[int, Optional[Dict[str, Any]]]:
    parts = path.strip('/').split('/')

    if method == 'GET' and path == '/v1/apps':
        if query.get('filter[bundleId]') == FORBIDDEN_BUNDLE:
            return error(403, 'This request is forbidden for security reasons',
                         'The API key in use does not allow this request')
        if query.get('filter[bundleId]') != BUNDLE:
            return 200, {'data': []}
        return 200, {'data': [{'type': 'apps', 'id': APP_ID,
                               'attributes': {'bundleId': BUNDLE}}]}

    if method == 'GET' and path == '/v1/builds':
        if (query.get('filter[app]') != APP_ID
                or query.get('filter[version]') != BUILD_NUMBER
                or query.get('filter[preReleaseVersion.version]') != VERSION):
            return 200, {'data': []}
        step = FAKE.build_script[min(FAKE.build_step, len(FAKE.build_script) - 1)]
        FAKE.build_step += 1
        if step is None:
            return 200, {'data': []}
        processing, internal = step
        doc: Dict[str, Any] = {'data': [{
            'type': 'builds', 'id': BUILD_ID,
            'attributes': {'version': BUILD_NUMBER, 'processingState': processing},
            'relationships': {'buildBetaDetail': {
                'data': {'type': 'buildBetaDetails', 'id': 'bbd-1'}}}}]}
        if query.get('include') == 'buildBetaDetail':
            doc['included'] = [{'type': 'buildBetaDetails', 'id': 'bbd-1',
                                'attributes': {'internalBuildState': internal,
                                               'externalBuildState': 'READY_FOR_BETA_SUBMISSION'}}]
        return 200, doc

    if method == 'GET' and path == f'/v1/apps/{APP_ID}/betaGroups':
        return 200, {'data': [{'type': 'betaGroups', 'id': g['id'], 'attributes': {
            'name': g['name'], 'isInternalGroup': g['internal'],
            'hasAccessToAllBuilds': g.get('all', False)}} for g in FAKE.groups]}

    if (method == 'POST' and len(parts) == 5 and parts[1] == 'betaGroups'
            and parts[3:] == ['relationships', 'builds']):
        gid = parts[2]
        group = next((g for g in FAKE.groups if g['id'] == gid), None)
        if group is None:
            return error(404, 'The specified resource does not exist', gid)
        if group.get('all'):
            return error(409, 'The request cannot be fulfilled',
                         'group has access to all builds')
        FAKE.group_builds[gid].extend(d['id'] for d in body['data'])
        return 204, None

    if method == 'GET' and path == f'/v1/apps/{APP_ID}/appStoreVersions':
        found = [vid for vid, v in FAKE.versions.items()
                 if v['versionString'] == query.get('filter[versionString]')
                 and query.get('filter[platform]') == 'IOS']
        return 200, {'data': [version_resource(vid) for vid in found]}

    if method == 'POST' and path == '/v1/appStoreVersions':
        data = body['data']
        if data['relationships']['app']['data']['id'] != APP_ID:
            return error(404, 'no such app', '')
        vid = FAKE.new_id('ver')
        FAKE.versions[vid] = {'versionString': data['attributes']['versionString'],
                              'state': 'PREPARE_FOR_SUBMISSION', 'build': None}
        # Apple creates the primary-locale localization with the version.
        FAKE.localizations[FAKE.new_id('loc')] = {'version': vid, 'locale': 'en-US',
                                                  'whatsNew': None}
        return 201, {'data': version_resource(vid)}

    if (method == 'PATCH' and len(parts) == 5 and parts[1] == 'appStoreVersions'
            and parts[3:] == ['relationships', 'build']):
        FAKE.versions[parts[2]]['build'] = body['data']['id']
        return 204, None

    if (method == 'GET' and len(parts) == 4 and parts[1] == 'appStoreVersions'
            and parts[3] == 'appStoreVersionLocalizations'):
        return 200, {'data': [
            {'type': 'appStoreVersionLocalizations', 'id': lid,
             'attributes': {'locale': loc['locale'], 'whatsNew': loc['whatsNew']}}
            for lid, loc in FAKE.localizations.items() if loc['version'] == parts[2]]}

    if method == 'PATCH' and len(parts) == 3 and parts[1] == 'appStoreVersionLocalizations':
        if FAKE.refuse_whats_new:
            return error(409, 'An attribute value is not acceptable for the current resource state.',
                         'The attribute \'whatsNew\' can not be edited at this time')
        FAKE.localizations[parts[2]]['whatsNew'] = body['data']['attributes']['whatsNew']
        return 200, {'data': {'type': 'appStoreVersionLocalizations', 'id': parts[2]}}

    if method == 'GET' and path == '/v1/reviewSubmissions':
        found = [sid for sid, s in FAKE.submissions.items()
                 if query.get('filter[app]') == APP_ID
                 and query.get('filter[platform]') == 'IOS'
                 and s['state'] == query.get('filter[state]')]
        return 200, {'data': [{'type': 'reviewSubmissions', 'id': sid,
                               'attributes': {'state': FAKE.submissions[sid]['state'],
                                              'platform': 'IOS'}} for sid in found]}

    if method == 'POST' and path == '/v1/reviewSubmissions':
        if any(s['state'] == 'READY_FOR_REVIEW' for s in FAKE.submissions.values()):
            return error(409, 'conflict', 'a draft submission already exists')
        sid = FAKE.new_id('sub')
        FAKE.submissions[sid] = {'state': 'READY_FOR_REVIEW', 'items': []}
        return 201, {'data': {'type': 'reviewSubmissions', 'id': sid,
                              'attributes': {'state': 'READY_FOR_REVIEW'}}}

    if (method == 'GET' and len(parts) == 4 and parts[1] == 'reviewSubmissions'
            and parts[3] == 'items'):
        return 200, {'data': [
            {'type': 'reviewSubmissionItems', 'id': f'item-{vid}', 'relationships': {
                'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': vid}}}}
            for vid in FAKE.submissions[parts[2]]['items']]}

    if method == 'POST' and path == '/v1/reviewSubmissionItems':
        rel = body['data']['relationships']
        sub = FAKE.submissions[rel['reviewSubmission']['data']['id']]
        vid = rel['appStoreVersion']['data']['id']
        if vid in sub['items']:
            return error(409, 'conflict', 'item already in submission')
        sub['items'].append(vid)
        FAKE.versions[vid]['state'] = 'READY_FOR_REVIEW'
        return 201, {'data': {'type': 'reviewSubmissionItems', 'id': f'item-{vid}'}}

    if method == 'PATCH' and len(parts) == 3 and parts[1] == 'reviewSubmissions':
        sub = FAKE.submissions[parts[2]]
        if body['data']['attributes'].get('submitted'):
            if not sub['items']:
                return error(409, 'conflict', 'nothing to submit')
            sub['state'] = 'WAITING_FOR_REVIEW'
            for vid in sub['items']:
                FAKE.versions[vid]['state'] = 'WAITING_FOR_REVIEW'
        return 200, {'data': {'type': 'reviewSubmissions', 'id': parts[2],
                              'attributes': {'state': sub['state']}}}

    if method == 'POST' and path == '/v1/appStoreVersionReleaseRequests':
        vid = body['data']['relationships']['appStoreVersion']['data']['id']
        if FAKE.versions[vid]['state'] != 'PENDING_DEVELOPER_RELEASE':
            return error(409, 'conflict', 'not pending developer release')
        FAKE.release_requests.append(vid)
        FAKE.versions[vid]['state'] = 'PROCESSING_FOR_APP_STORE'
        return 201, {'data': {'type': 'appStoreVersionReleaseRequests', 'id': 'rel-1'}}

    return error(404, 'The specified resource does not exist',
                 f'the fake has no {method} {path}')


class Handler(BaseHTTPRequestHandler):
    def _serve(self) -> None:
        split = urllib.parse.urlsplit(self.path)
        query = dict(urllib.parse.parse_qsl(split.query))
        length = int(self.headers.get('Content-Length') or 0)
        raw = self.rfile.read(length) if length else b''
        body = json.loads(raw) if raw else None
        auth = self.headers.get('Authorization', '')
        with FAKE.lock:
            if auth.startswith('Bearer '):
                SEEN_TOKENS.add(auth[len('Bearer '):])
            FAKE.requests.append({'method': self.command, 'path': split.path,
                                  'query': query, 'body': body, 'auth': auth})
            if not auth.startswith('Bearer ') or auth.count('.') != 2:
                status, doc = error(401, 'Authentication credentials are missing or invalid.',
                                    'Provide a properly configured and signed bearer token')
            else:
                status, doc = handle(self.command, split.path, query, body)
        payload = b'' if doc is None else json.dumps(doc).encode()
        self.send_response(status)
        if payload:
            self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = do_POST = do_PATCH = _serve

    def log_message(self, *args: Any) -> None:
        pass


# ── running the script ───────────────────────────────────────────────────────


class Env:
    def __init__(self, root: str, base: str) -> None:
        self.root = root
        self.home = os.path.join(root, 'home')
        self.base = base
        self.outputs: List[str] = []


ENV: Optional[Env] = None


def run(*args: str, env: Optional[Dict[str, str]] = None,
        creds: bool = True) -> Tuple[int, Dict[str, Any], str]:
    assert ENV is not None
    full = dict(os.environ)
    for name in ('ASC_KEY_ID', 'ASC_ISSUER_UUID'):
        full.pop(name, None)
    full.update({'HOME': ENV.home, 'LB_ASC_API_BASE': ENV.base,
                 'NO_PROXY': '127.0.0.1,localhost', 'no_proxy': '127.0.0.1,localhost'})
    if creds:
        full.update({'ASC_KEY_ID': KEY_ID, 'ASC_ISSUER_UUID': ISSUER})
    full.update(env or {})
    proc = subprocess.run([sys.executable, str(SCRIPT), *args], cwd=ENV.root, env=full,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    out = proc.stdout.decode('utf-8', 'replace')
    err = proc.stderr.decode('utf-8', 'replace')
    ENV.outputs.extend([out, err])
    lines = out.strip().splitlines()
    try:
        summary = json.loads(lines[-1]) if lines else {}
    except ValueError:
        summary = {'_unparsed': lines[-1]}
    return proc.returncode, summary, err


def openssl(*args: str, data: Optional[bytes] = None) -> subprocess.CompletedProcess:
    return subprocess.run(['openssl', *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, check=False)


def make_key(root: str) -> Tuple[str, str]:
    ec = os.path.join(root, 'ec.pem')
    keydir = os.path.join(root, 'home', '.appstoreconnect', 'private_keys')
    os.makedirs(keydir)
    p8 = os.path.join(keydir, f'AuthKey_{KEY_ID}.p8')
    pub = os.path.join(root, 'pub.pem')
    for cmd in (['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', ec],
                ['pkcs8', '-topk8', '-nocrypt', '-in', ec, '-out', p8],
                ['ec', '-in', ec, '-pubout', '-out', pub]):
        proc = openssl(*cmd)
        if proc.returncode != 0:
            raise SystemExit(f'openssl {cmd[0]} failed: {proc.stderr.decode()}')
    return p8, pub


# ── scenarios ────────────────────────────────────────────────────────────────


def test_der(asc: Any) -> None:
    print('DER → JWS signature conversion')
    r33 = b'\x00' + b'\x80' + bytes(range(1, 32))          # high bit: 0x00 prefix
    s31 = bytes(range(2, 33))[:31]                         # leading zero dropped
    der = b'\x30' + bytes([2 + 33 + 2 + 31]) + b'\x02\x21' + r33 + b'\x02\x1f' + s31
    raw = asc.der_signature_to_raw(der)
    check('a 33-byte r loses its sign byte and a 31-byte s is left-padded',
          raw == r33[1:] + b'\x00' + s31, raw.hex())
    tiny = b'\x30\x06\x02\x01\x05\x02\x01\x07'
    check('one-byte r and s pad to 32 bytes each',
          asc.der_signature_to_raw(tiny) == b'\x00' * 31 + b'\x05' + b'\x00' * 31 + b'\x07')
    for raw_in in (b'\x00' * 3 + b'\x7f' * 29 + b'\xff' * 32,
                   b'\x81' * 32 + b'\x00\x01' + b'\x02' * 30):
        check('raw → DER → raw round-trips with leading zeros and high bits',
              asc.der_signature_to_raw(raw_to_der(raw_in)) == raw_in, raw_in.hex())
    long_form = b'\x30\x81\x06\x02\x01\x05\x02\x01\x07'
    check('a long-form SEQUENCE length is accepted',
          asc.der_signature_to_raw(long_form)[-1:] == b'\x07')
    for label, bad in (('not a SEQUENCE', b'\x31\x06\x02\x01\x05\x02\x01\x07'),
                       ('length mismatch', b'\x30\x07\x02\x01\x05\x02\x01\x07'),
                       ('trailing bytes', b'\x30\x08\x02\x01\x05\x02\x01\x07\x00\x00'),
                       ('r wider than 32', b'\x30' + bytes([2 + 33 + 3]) + b'\x02\x21'
                        + b'\x01' * 33 + b'\x02\x01\x07'),
                       ('truncated', b'\x30\x06\x02\x01')):
        try:
            asc.der_signature_to_raw(bad)
            check(f'malformed DER is refused ({label})', False, 'no ValueError')
        except ValueError:
            check(f'malformed DER is refused ({label})', True)


def test_token_refresh(asc: Any, p8: str) -> None:
    print('token lifetime')
    clock = [1_800_000_000.0]
    minter = asc.TokenMinter(KEY_ID, ISSUER, p8, now=lambda: clock[0])
    first = minter.token()
    clock[0] += 600
    check('the token is reused while it has time left', minter.token() == first)
    clock[0] += asc.TOKEN_LIFETIME - 600 - 60
    second = minter.token()
    claims = json.loads(b64url_decode(second.split('.')[1]))
    check('a token near expiry is replaced by a newly minted one',
          second != first and claims['iat'] == int(clock[0]), str(claims))


def test_jwt(pub: str) -> None:
    print('JWT')
    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'PREPARE_FOR_SUBMISSION'}})
    code, summary, _ = run('version-state', '--version', VERSION)
    check('version-state exits 0 and reports the state',
          code == 0 and summary.get('appStoreState') == 'PREPARE_FOR_SUBMISSION',
          f'{code} {summary}')
    check('version-state includes appVersionState when Apple sends it',
          summary.get('appVersionState') == 'PREPARE_FOR_SUBMISSION', str(summary))
    auth = FAKE.requests[0]['auth'] if FAKE.requests else ''
    token = auth[len('Bearer '):]
    parts = token.split('.')
    if len(parts) != 3:
        check('the bearer token has three parts', False, repr(auth[:20]))
        return
    header = json.loads(b64url_decode(parts[0]))
    claims = json.loads(b64url_decode(parts[1]))
    check('the header is {alg ES256, kid, typ JWT}',
          header == {'alg': 'ES256', 'kid': KEY_ID, 'typ': 'JWT'}, str(header))
    check('the claims carry iss, iat, exp and the App Store Connect audience',
          set(claims) == {'iss', 'iat', 'exp', 'aud'} and claims['iss'] == ISSUER
          and claims['aud'] == 'appstoreconnect-v1', str(claims))
    check('the token lives no longer than Apple\'s 20 minutes',
          0 < claims['exp'] - claims['iat'] <= 1200, str(claims))
    raw = b64url_decode(parts[2])
    check('the signature is the 64-byte r||s form', len(raw) == 64, str(len(raw)))
    with tempfile.TemporaryDirectory() as tmp:
        sig = os.path.join(tmp, 'sig.der')
        with open(sig, 'wb') as handle:
            handle.write(raw_to_der(raw))
        proc = openssl('dgst', '-sha256', '-verify', pub, '-signature', sig,
                       data=f'{parts[0]}.{parts[1]}'.encode())
        check('the signature, back in DER, verifies against the public key',
              proc.returncode == 0, proc.stdout.decode() + proc.stderr.decode())
        tampered = f'{parts[0]}.{parts[1]}x'.encode()
        proc = openssl('dgst', '-sha256', '-verify', pub, '-signature', sig, data=tampered)
        check('and does not verify over different input', proc.returncode != 0)
    return None


def test_not_configured(p8: str) -> None:
    print('not configured')
    FAKE.reset()
    code, summary, err = run('version-state', '--version', VERSION, creds=False)
    check('no key id or issuer exits 2', code == 2 and summary.get('exitCode') == 2,
          f'{code} {summary}')
    check('and names both', 'ASC_KEY_ID' in err and 'ASC_ISSUER_UUID' in err, err)
    code, summary, err = run('version-state', '--version', VERSION, creds=False,
                             env={'ASC_KEY_ID': KEY_ID})
    check('a key id without an issuer exits 2', code == 2, f'{code} {summary}')
    code, summary, err = run('version-state', '--version', VERSION,
                             env={'ASC_KEY_ID': 'NOSUCHKEY'})
    check('no AuthKey_<KEYID>.p8 in any searched directory exits 2',
          code == 2 and 'AuthKey_NOSUCHKEY.p8' in err and summary.get('ok') is False,
          f'{code} {summary} {err}')
    code, _, err = run('version-state', '--version', VERSION, '--key-file',
                       os.path.join(ENV.root, 'missing.p8'))
    check('a --key-file that does not exist exits 2', code == 2, f'{code} {err}')
    junk = os.path.join(ENV.root, 'junk.p8')
    with open(junk, 'w') as handle:
        handle.write('not a key\n')
    code, _, err = run('version-state', '--version', VERSION, '--key-file', junk)
    check('a key openssl cannot sign with exits 2', code == 2, f'{code} {err}')
    check('none of those made a request', FAKE.requests == [], str(FAKE.requests))
    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'READY_FOR_SALE'}})
    code, summary, _ = run('--key-id', KEY_ID, '--issuer', ISSUER, '--key-file', p8,
                           'version-state', '--version', VERSION, creds=False)
    check('flags before the subcommand work too, with --key-file',
          code == 0 and summary.get('appStoreState') == 'READY_FOR_SALE', f'{code} {summary}')
    local = os.path.join(ENV.root, 'private_keys')
    os.makedirs(local, exist_ok=True)
    with open(p8, 'rb') as src, open(os.path.join(local, 'AuthKey_LOCALKEY.p8'), 'wb') as dst:
        dst.write(src.read())
    code, summary, _ = run('version-state', '--version', VERSION, '--key-id', 'LOCALKEY')
    check('./private_keys is searched like altool does', code == 0, f'{code} {summary}')


def test_api_error() -> None:
    print('API errors')
    FAKE.reset()
    code, summary, err = run('version-state', '--version', VERSION,
                             '--bundle-id', FORBIDDEN_BUNDLE)
    check('an HTTP error exits 1', code == 1 and summary.get('ok') is False,
          f'{code} {summary}')
    check('Apple\'s errors[] title and detail are printed',
          'This request is forbidden for security reasons' in err
          and 'The API key in use does not allow this request' in err, err)
    check('the summary carries the HTTP status', summary.get('httpStatus') == 403, str(summary))
    code, summary, err = run('version-state', '--version', VERSION,
                             '--bundle-id', 'com.example.other')
    check('an app the key cannot see exits 1', code == 1 and 'com.example.other' in err,
          f'{code} {err}')
    FAKE.reset()
    code, summary, err = run('version-state', '--version', '9.9.9')
    check('a version that does not exist exits 1', code == 1, f'{code} {summary}')


def test_wait_build() -> None:
    print('wait-build')
    args = ('wait-build', '--version', VERSION, '--build', BUILD_NUMBER, '--interval', '0')
    FAKE.reset(build_script=[None, None, ('PROCESSING', 'PROCESSING'),
                             ('VALID', 'PROCESSING'), ('VALID', 'READY_FOR_BETA_TESTING')])
    code, summary, err = run(*args)
    check('not visible → PROCESSING → VALID/READY_FOR_BETA_TESTING exits 0',
          code == 0 and summary.get('processingState') == 'VALID'
          and summary.get('internalBuildState') == 'READY_FOR_BETA_TESTING'
          and summary.get('buildId') == BUILD_ID, f'{code} {summary} {err}')
    check('it polled through every state', FAKE.build_step == 5, str(FAKE.build_step))
    builds = FAKE.calls('GET', '/v1/builds')
    check('the poll filters app, build number and version and includes buildBetaDetail',
          bool(builds) and builds[0]['query'] == {
              'filter[app]': APP_ID, 'filter[version]': BUILD_NUMBER,
              'filter[preReleaseVersion.version]': VERSION,
              'include': 'buildBetaDetail', 'limit': '10'}, str(builds[:1]))
    check('a not-yet-visible build is reported as normal', 'not visible yet' in err, err)

    FAKE.reset(build_script=[('VALID', 'IN_BETA_TESTING')])
    code, summary, _ = run(*args)
    check('IN_BETA_TESTING also exits 0', code == 0, f'{code} {summary}')

    FAKE.reset(build_script=[('PROCESSING', 'PROCESSING'),
                             ('VALID', 'MISSING_EXPORT_COMPLIANCE')])
    code, summary, err = run(*args)
    check('MISSING_EXPORT_COMPLIANCE exits 3',
          code == 3 and summary.get('internalBuildState') == 'MISSING_EXPORT_COMPLIANCE',
          f'{code} {summary}')
    check('and says how to answer it', '740.17(b)(1)' in err and 'Step 6' in err, err)

    for processing, internal in (('INVALID', 'PROCESSING'), ('FAILED', 'PROCESSING'),
                                 ('VALID', 'PROCESSING_EXCEPTION')):
        FAKE.reset(build_script=[(processing, internal)])
        code, summary, _ = run(*args)
        check(f'{processing}/{internal} exits 1',
              code == 1 and summary.get('processingState') == processing, f'{code} {summary}')

    FAKE.reset(build_script=[('PROCESSING', 'PROCESSING')])
    code, summary, err = run('wait-build', '--version', VERSION, '--build', BUILD_NUMBER,
                             '--timeout', '0.3', '--interval', '0.05')
    check('a build still PROCESSING at the deadline exits 4',
          code == 4 and summary.get('processingState') == 'PROCESSING', f'{code} {summary}')
    check('after polling more than once', FAKE.build_step > 1, str(FAKE.build_step))

    FAKE.reset(build_script=[None])
    code, summary, _ = run(*args, '--timeout', '0')
    check('a build never seen also times out with 4 and a null buildId',
          code == 4 and summary.get('buildId') is None, f'{code} {summary}')


GROUPS = [{'id': 'grp-ext', 'name': 'Public', 'internal': False},
          {'id': 'grp-int', 'name': 'Team', 'internal': True}]


def test_add_to_group() -> None:
    print('add-to-group')
    args = ('add-to-group', '--version', VERSION, '--build', BUILD_NUMBER)
    FAKE.reset(groups=[dict(g) for g in GROUPS])
    code, summary, _ = run(*args)
    check('the only internal group gets the build',
          code == 0 and FAKE.group_builds == {'grp-ext': [], 'grp-int': [BUILD_ID]}
          and summary.get('added') is True and summary.get('group') == 'Team',
          f'{code} {summary} {FAKE.group_builds}')
    posts = FAKE.calls('POST', '/v1/betaGroups/')
    check('with a JSON:API to-many body',
          bool(posts) and posts[0]['body'] == {'data': [{'type': 'builds', 'id': BUILD_ID}]},
          str(posts))

    FAKE.reset(groups=[{'id': 'grp-int', 'name': 'Team', 'internal': True, 'all': True}])
    code, summary, err = run(*args)
    check('a group with access to all builds: exit 0, nothing posted',
          code == 0 and summary.get('added') is False
          and summary.get('hasAccessToAllBuilds') is True
          and FAKE.calls('POST', '/v1/betaGroups/') == [], f'{code} {summary}')
    check('and says so', 'every build' in err, err)

    several = [dict(g) for g in GROUPS] + [{'id': 'grp-int2', 'name': 'Founders',
                                            'internal': True}]
    FAKE.reset(groups=several)
    code, summary, err = run(*args)
    check('several internal groups and no --group exits 1 and lists them',
          code == 1 and 'Team' in err and 'Founders' in err
          and FAKE.calls('POST', '/v1/betaGroups/') == [], f'{code} {err}')
    FAKE.reset(groups=[dict(g) for g in several])
    code, summary, _ = run(*args, '--group', 'Founders')
    check('--group picks the named internal group',
          code == 0 and FAKE.group_builds['grp-int2'] == [BUILD_ID], f'{code} {summary}')
    FAKE.reset(groups=[dict(g) for g in several])
    code, _, err = run(*args, '--group', 'Public')
    check('--group naming an external group exits 1', code == 1 and 'external' in err,
          f'{code} {err}')

    FAKE.reset(groups=[dict(g) for g in GROUPS], build_script=[None])
    code, _, err = run(*args)
    check('a build not in App Store Connect exits 1', code == 1 and 'wait-build' in err,
          f'{code} {err}')


def test_prepare_version() -> None:
    print('prepare-version')
    notes = os.path.join(ENV.root, 'whatsnew.txt')
    with open(notes, 'w', encoding='utf-8') as handle:
        handle.write('Fixes and “quotes”.\n')
    args = ('prepare-version', '--version', VERSION, '--build', BUILD_NUMBER)

    FAKE.reset()
    code, summary, err = run(*args, '--whats-new-file', notes)
    vid = next(iter(FAKE.versions), None)
    check('a missing version is created, the build selected, What\'s New set',
          code == 0 and summary.get('created') is True and summary.get('whatsNew') == 'updated'
          and vid is not None and FAKE.versions[vid]['build'] == BUILD_ID,
          f'{code} {summary} {err}')
    created = FAKE.calls('POST', '/v1/appStoreVersions')
    check('the create body names platform, versionString and the app',
          bool(created) and created[0]['body'] == {'data': {
              'type': 'appStoreVersions',
              'attributes': {'platform': 'IOS', 'versionString': VERSION},
              'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}},
          str(created))
    patch = FAKE.calls('PATCH', f'/v1/appStoreVersions/{vid}/relationships/build')
    check('the build is selected with a to-one relationship body',
          bool(patch) and patch[0]['body'] == {'data': {'type': 'builds', 'id': BUILD_ID}},
          str(patch))
    loc = next(iter(FAKE.localizations.values()), {})
    check('What\'s New is the file\'s UTF-8 text, trimmed',
          loc.get('whatsNew') == 'Fixes and “quotes”.', repr(loc))

    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'REJECTED',
                                   'build': 'old'}},
               localizations={'loc-1': {'version': 'ver-1', 'locale': 'en-US',
                                        'whatsNew': None}},
               refuse_whats_new=True)
    code, summary, err = run(*args, '--whats-new-file', notes)
    check('an existing REJECTED version is reused, not recreated',
          FAKE.calls('POST', '/v1/appStoreVersions') == [] and summary.get('created') is False,
          str(summary))
    check('a refused What\'s New is a warning: exit 0, whatsNew "skipped"',
          code == 0 and summary.get('whatsNew') == 'skipped'
          and FAKE.versions['ver-1']['build'] == BUILD_ID, f'{code} {summary}')
    check('and the refusal detail is shown', 'can not be edited at this time' in err, err)

    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'WAITING_FOR_REVIEW',
                                   'build': 'old'}})
    code, summary, err = run(*args)
    check('a version in WAITING_FOR_REVIEW is refused with 1, untouched',
          code == 1 and FAKE.versions['ver-1']['build'] == 'old'
          and FAKE.calls('PATCH', '/v1/') == [] and 'WAITING_FOR_REVIEW' in err,
          f'{code} {summary}')

    FAKE.reset()
    code, summary, _ = run(*args, '--no-create')
    check('--no-create with no version exits 1 and creates nothing',
          code == 1 and FAKE.versions == {}, f'{code} {summary}')

    FAKE.reset()
    code, summary, _ = run(*args, '--whats-new-file', os.path.join(ENV.root, 'nope.txt'))
    check('an unreadable --whats-new-file exits 1 before any change',
          code == 1 and FAKE.requests == [], f'{code} {summary}')

    FAKE.reset(versions={'ver-1': {'versionString': VERSION,
                                   'state': 'PREPARE_FOR_SUBMISSION', 'build': None}})
    code, summary, _ = run(*args)
    check('without --whats-new-file whatsNew is "not-requested"',
          code == 0 and summary.get('whatsNew') == 'not-requested', f'{code} {summary}')


def test_submit() -> None:
    print('submit')
    args = ('submit', '--version', VERSION)
    FAKE.reset(versions={'ver-1': {'versionString': VERSION,
                                   'state': 'PREPARE_FOR_SUBMISSION', 'build': BUILD_ID}})
    code, summary, err = run(*args)
    sid = summary.get('submissionId')
    check('with no draft, a submission is created, filled and submitted',
          code == 0 and summary.get('createdSubmission') is True
          and summary.get('itemAdded') is True
          and FAKE.submissions.get(sid, {}).get('state') == 'WAITING_FOR_REVIEW'
          and summary.get('submissionState') == 'WAITING_FOR_REVIEW', f'{code} {summary} {err}')
    created = FAKE.calls('POST', '/v1/reviewSubmissions')
    check('the submission body is platform IOS with the app relationship',
          bool(created) and created[0]['body'] == {'data': {
              'type': 'reviewSubmissions', 'attributes': {'platform': 'IOS'},
              'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}},
          str(created))
    item = FAKE.calls('POST', '/v1/reviewSubmissionItems')
    check('the item links the submission and the version',
          bool(item) and item[0]['body']['data']['relationships'] == {
              'reviewSubmission': {'data': {'type': 'reviewSubmissions', 'id': sid}},
              'appStoreVersion': {'data': {'type': 'appStoreVersions', 'id': 'ver-1'}}},
          str(item))
    patch = FAKE.calls('PATCH', f'/v1/reviewSubmissions/{sid}')
    check('submitted:true is PATCHed last',
          bool(patch) and FAKE.requests[-1] is patch[-1]
          and patch[0]['body']['data']['attributes'] == {'submitted': True}, str(patch))

    FAKE.reset(versions={'ver-1': {'versionString': VERSION,
                                   'state': 'PREPARE_FOR_SUBMISSION', 'build': BUILD_ID}},
               submissions={'sub-old': {'state': 'READY_FOR_REVIEW', 'items': []},
                            'sub-done': {'state': 'COMPLETE', 'items': []}})
    code, summary, _ = run(*args)
    check('an open draft is reused, not duplicated',
          code == 0 and summary.get('submissionId') == 'sub-old'
          and summary.get('createdSubmission') is False
          and FAKE.calls('POST', '/v1/reviewSubmissions') == []
          and FAKE.submissions['sub-old'] == {'state': 'WAITING_FOR_REVIEW',
                                              'items': ['ver-1']}, f'{code} {summary}')

    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'READY_FOR_REVIEW',
                                   'build': BUILD_ID}},
               submissions={'sub-old': {'state': 'READY_FOR_REVIEW', 'items': ['ver-1']}})
    code, summary, _ = run(*args)
    check('a draft already holding the version is just submitted (a resumed run)',
          code == 0 and summary.get('itemAdded') is False
          and FAKE.calls('POST', '/v1/reviewSubmissionItems') == []
          and FAKE.submissions['sub-old']['state'] == 'WAITING_FOR_REVIEW',
          f'{code} {summary}')

    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'IN_REVIEW'}})
    code, summary, _ = run(*args)
    check('a version already IN_REVIEW exits 0 without touching anything',
          code == 0 and summary.get('alreadySubmitted') is True
          and [r['method'] for r in FAKE.requests] == ['GET', 'GET'], f'{code} {summary}')

    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'READY_FOR_SALE'}})
    code, summary, _ = run(*args)
    check('a live version is not submitted (exit 1)', code == 1, f'{code} {summary}')


def test_release() -> None:
    print('release')
    args = ('release', '--version', VERSION)
    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'WAITING_FOR_REVIEW'}})
    code, summary, err = run(*args)
    check('a version not PENDING_DEVELOPER_RELEASE is not released (exit 1)',
          code == 1 and FAKE.release_requests == []
          and FAKE.calls('POST', '/v1/') == [] and 'WAITING_FOR_REVIEW' in err
          and summary.get('appStoreState') == 'WAITING_FOR_REVIEW', f'{code} {summary}')
    FAKE.reset(versions={'ver-1': {'versionString': VERSION,
                                   'state': 'PENDING_DEVELOPER_RELEASE'}})
    code, summary, _ = run(*args)
    check('PENDING_DEVELOPER_RELEASE is released (exit 0)',
          code == 0 and summary.get('released') is True and FAKE.release_requests == ['ver-1'],
          f'{code} {summary}')
    posts = FAKE.calls('POST', '/v1/appStoreVersionReleaseRequests')
    check('with the appStoreVersion relationship',
          bool(posts) and posts[0]['body'] == {'data': {
              'type': 'appStoreVersionReleaseRequests',
              'relationships': {'appStoreVersion': {
                  'data': {'type': 'appStoreVersions', 'id': 'ver-1'}}}}}, str(posts))


def test_no_secrets(p8: str) -> None:
    print('secrets')
    tokens = set(SEEN_TOKENS)
    with open(p8) as handle:
        key_lines = [line for line in handle.read().splitlines()
                     if line and not line.startswith('-----')]
    leaked = [t for t in tokens if any(t in out for out in ENV.outputs)]
    leaked += [k for k in key_lines if any(k in out for out in ENV.outputs)]
    check('no token or key material appears in any output', not leaked and bool(tokens))


def test_summary_shape() -> None:
    print('summary')
    FAKE.reset(versions={'ver-1': {'versionString': VERSION, 'state': 'IN_REVIEW'}})
    full = dict(os.environ, HOME=ENV.home, LB_ASC_API_BASE=ENV.base,
                NO_PROXY='127.0.0.1,localhost', no_proxy='127.0.0.1,localhost',
                ASC_KEY_ID=KEY_ID, ASC_ISSUER_UUID=ISSUER)
    proc = subprocess.run([sys.executable, str(SCRIPT), 'version-state', '--version', VERSION],
                          cwd=ENV.root, env=full, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, timeout=60)
    lines = proc.stdout.decode().splitlines()
    check('stdout is exactly one JSON line with command, ok and exitCode',
          len(lines) == 1 and {'command', 'ok', 'exitCode'} <= set(json.loads(lines[0])),
          repr(lines))


def main() -> int:
    global ENV
    asc = load()
    test_der(asc)
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory() as root:
            ENV = Env(root, f'http://127.0.0.1:{server.server_address[1]}')
            p8, pub = make_key(root)
            test_token_refresh(asc, p8)
            test_jwt(pub)
            test_not_configured(p8)
            test_api_error()
            test_wait_build()
            test_add_to_group()
            test_prepare_version()
            test_submit()
            test_release()
            test_summary_shape()
            test_no_secrets(p8)
    finally:
        server.shutdown()
        server.server_close()
    if _status == 0:
        print('asc_api selftest: all passed')
    return _status


if __name__ == '__main__':
    raise SystemExit(main())
