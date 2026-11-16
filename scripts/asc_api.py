#!/usr/bin/env python3
# Copyright 2026 Pigs Can Fly Labs LLC
# SPDX-License-Identifier: Apache-2.0
"""App Store Connect API steps for scripts/release-apple.sh.

The guided release uploads the IPA with an App Store Connect API key, then
used to hand the rest to a person: wait for Apple's processing email, add the
build to the internal TestFlight group, pick it on the App Store version,
submit for review and release (docs/APP_STORE_SUBMISSION.md Steps 5-9). Each
of those is one or two API calls with the same key, and a person clicking
through them is where the wrong build gets selected or "Add for Review" is
mistaken for "Submit for Review". This script makes those calls, one
subcommand per step, so the bash side can try it and keep its manual
instructions as the fallback.

Exit codes are the contract with the bash side:
  0  done
  1  App Store Connect refused, or the state is not one this step may act on
     (the error is printed); fall back to the manual step
  2  not configured (no key id, issuer or AuthKey_<KEYID>.p8, openssl cannot
     sign, or a usage error); fall back to the manual step
  3  wait-build: the build needs the export-compliance answers (Step 6)
  4  wait-build: timed out
Progress goes to stderr. The last stdout line is a one-line JSON summary,
whatever the exit code (argparse usage errors excepted).

Stdlib only and Python 3.9 compatible because it runs on the release Mac's
system python3, which has no pip packages to lean on: the ES256 JWT is signed
by the openssl binary and its DER signature converted to JWS form here.
"""

from __future__ import annotations

import argparse
import base64
import http.client
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Dict, List, Optional, Tuple

DEFAULT_API_BASE = 'https://api.appstoreconnect.apple.com'
DEFAULT_BUNDLE_ID = 'ca.pigscanfly.liberatedbread'
AUDIENCE = 'appstoreconnect-v1'

# Apple refuses tokens that live longer than 20 minutes; a minute's headroom
# keeps a Mac whose clock runs slightly fast from being refused outright.
TOKEN_LIFETIME = 19 * 60
# Re-mint this long before expiry so a request never leaves with a token that
# lapses in flight; wait-build polls for up to 90 minutes on one process.
TOKEN_REFRESH_MARGIN = 120

EXIT_OK = 0
EXIT_API = 1
EXIT_NOT_CONFIGURED = 2
EXIT_EXPORT_COMPLIANCE = 3
EXIT_TIMEOUT = 4

# The states in which App Store Connect lets the version's build and
# metadata change. Anything else is in review, approved or live, and touching
# it either fails or (worse) succeeds on the wrong version.
EDITABLE_STATES = frozenset({
    'PREPARE_FOR_SUBMISSION', 'DEVELOPER_REJECTED', 'REJECTED',
    'METADATA_REJECTED', 'INVALID_BINARY',
})
# A version already added to a draft submission reads READY_FOR_REVIEW; a
# re-run after a half-finished submit must be able to finish it.
SUBMITTABLE_STATES = EDITABLE_STATES | {'READY_FOR_REVIEW'}
ALREADY_SUBMITTED_STATES = frozenset({'WAITING_FOR_REVIEW', 'IN_REVIEW'})

BETA_READY_STATES = frozenset({'READY_FOR_BETA_TESTING', 'IN_BETA_TESTING'})
BETA_FAILED_STATES = frozenset({'PROCESSING_EXCEPTION', 'EXPIRED'})
BUILD_FAILED_STATES = frozenset({'FAILED', 'INVALID'})

EXPORT_COMPLIANCE_HELP = (
    'Answer export compliance in App Store Connect → TestFlight → this build '
    '(docs/APP_STORE_SUBMISSION.md Step 6): uses encryption → standard '
    'algorithms → exempt under EAR 740.17(b)(1).')


def log(message: str) -> None:
    print(f'asc_api: {message}', file=sys.stderr, flush=True)


class Failure(Exception):
    """Ends the command with a non-zero exit and what the summary should say."""

    def __init__(self, code: int, message: str,
                 fields: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.fields = dict(fields or {})

    def lines(self) -> List[str]:
        return [self.message]


class ApiFailure(Failure):
    """An HTTP error or unreachable API, with Apple's errors[] kept for the human."""

    def __init__(self, method: str, url: str, status: Optional[int],
                 errors: List[Dict[str, Any]], reason: str = '') -> None:
        path = urllib.parse.urlsplit(url).path
        what = f'HTTP {status}' if status is not None else (reason or 'no response')
        super().__init__(EXIT_API, f'{method} {path} failed: {what}',
                         {'httpStatus': status})
        self.status = status
        self.errors = errors

    @property
    def transient(self) -> bool:
        return self.status is None or self.status == 429 or self.status >= 500

    def lines(self) -> List[str]:
        out = [self.message]
        for err in self.errors:
            title = str(err.get('title') or err.get('code') or 'error')
            detail = err.get('detail')
            out.append(f'  {title}: {detail}' if detail else f'  {title}')
        if self.status == 401:
            out.append('  (401: check the key id, the issuer id, that the key '
                       'is not revoked, and this Mac\'s clock)')
        return out


# ── ES256 JWT ────────────────────────────────────────────────────────────────


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def _der_length(buf: bytes, pos: int) -> Tuple[int, int]:
    if pos >= len(buf):
        raise ValueError('DER truncated in a length')
    first = buf[pos]
    pos += 1
    if first < 0x80:
        return first, pos
    count = first & 0x7F
    # 0x80 is BER's indefinite form, never valid DER; an ECDSA signature never
    # needs more than two length bytes.
    if count == 0 or count > 2 or pos + count > len(buf):
        raise ValueError('bad DER length')
    return int.from_bytes(buf[pos:pos + count], 'big'), pos + count


def der_signature_to_raw(der: bytes, size: int = 32) -> bytes:
    """ECDSA-Sig-Value (SEQUENCE { r INTEGER, s INTEGER }) → r||s, each `size` bytes.

    openssl emits the DER form; JWS ES256 wants the fixed-width pair. DER
    integers are minimal and signed, so r or s can arrive one byte longer
    (a 0x00 ahead of a high bit) or shorter (leading zero bytes dropped) than
    32, and both have to come out exactly 32.
    """
    if len(der) < 2 or der[0] != 0x30:
        raise ValueError('not a DER SEQUENCE')
    length, pos = _der_length(der, 1)
    if pos + length != len(der):
        raise ValueError('DER SEQUENCE length does not match the signature')
    raw = b''
    for name in ('r', 's'):
        if pos >= len(der) or der[pos] != 0x02:
            raise ValueError(f'expected a DER INTEGER for {name}')
        length, pos = _der_length(der, pos + 1)
        if length == 0 or pos + length > len(der):
            raise ValueError(f'bad DER INTEGER length for {name}')
        value = der[pos:pos + length].lstrip(b'\x00')
        pos += length
        if len(value) > size:
            raise ValueError(f'{name} is wider than {size} bytes')
        raw += value.rjust(size, b'\x00')
    if pos != len(der):
        raise ValueError('trailing bytes after the DER signature')
    return raw


class TokenMinter:
    """Hands out a JWT, minting a fresh one when the last is close to expiry."""

    def __init__(self, key_id: str, issuer: str, key_file: str,
                 now: Callable[[], float] = time.time,
                 openssl: str = 'openssl') -> None:
        self.key_id = key_id
        self.issuer = issuer
        self.key_file = key_file
        self._now = now
        self._openssl = openssl
        self._token: Optional[str] = None
        self._expires = 0

    def token(self) -> str:
        now = self._now()
        if self._token is None or now >= self._expires - TOKEN_REFRESH_MARGIN:
            self._token, self._expires = self._mint(int(now))
        return self._token

    def _mint(self, iat: int) -> Tuple[str, int]:
        exp = iat + TOKEN_LIFETIME
        header = {'alg': 'ES256', 'kid': self.key_id, 'typ': 'JWT'}
        claims = {'iss': self.issuer, 'iat': iat, 'exp': exp, 'aud': AUDIENCE}
        signing_input = '.'.join(
            b64url(json.dumps(part, separators=(',', ':')).encode('utf-8'))
            for part in (header, claims)).encode('ascii')
        try:
            proc = subprocess.run(
                [self._openssl, 'dgst', '-sha256', '-sign', self.key_file],
                input=signing_input, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=False)
        except OSError as err:
            raise Failure(EXIT_NOT_CONFIGURED,
                          f'cannot run openssl to sign the API token: {err}')
        if proc.returncode != 0 or not proc.stdout:
            first = proc.stderr.decode('utf-8', 'replace').strip().splitlines()
            raise Failure(EXIT_NOT_CONFIGURED,
                          f'openssl could not sign with {self.key_file}'
                          + (f': {first[0]}' if first else ''))
        try:
            raw = der_signature_to_raw(proc.stdout)
        except ValueError as err:
            raise Failure(EXIT_NOT_CONFIGURED,
                          f'{self.key_file} is not a P-256 key ({err})')
        return f'{signing_input.decode("ascii")}.{b64url(raw)}', exp


# ── credentials ──────────────────────────────────────────────────────────────


def key_search_dirs() -> List[str]:
    # The same places, in the same order, as release-apple.sh's asc_key_file
    # (and altool's own search), so whichever key altool uploaded with is the
    # one used here.
    home = os.path.expanduser('~')
    return [os.path.join(home, '.appstoreconnect', 'private_keys'),
            os.path.join(home, 'private_keys'),
            os.path.join(home, '.private_keys'),
            os.path.join('.', 'private_keys')]


def resolve_credentials(args: argparse.Namespace) -> Tuple[str, str, str]:
    key_id = (args.key_id or os.environ.get('ASC_KEY_ID') or '').strip()
    issuer = (args.issuer or os.environ.get('ASC_ISSUER_UUID') or '').strip()
    missing = []
    if not key_id:
        missing.append('a key id (--key-id or ASC_KEY_ID)')
    if not issuer:
        missing.append('an issuer id (--issuer or ASC_ISSUER_UUID)')
    if missing:
        raise Failure(EXIT_NOT_CONFIGURED, 'not configured: need '
                      + ' and '.join(missing))
    if args.key_file:
        if not os.path.isfile(args.key_file):
            raise Failure(EXIT_NOT_CONFIGURED,
                          f'not configured: no key file at {args.key_file}')
        return key_id, issuer, args.key_file
    name = f'AuthKey_{key_id}.p8'
    for directory in key_search_dirs():
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            return key_id, issuer, path
    raise Failure(EXIT_NOT_CONFIGURED,
                  f'not configured: {name} is in none of '
                  + ', '.join(key_search_dirs()) + ' (or pass --key-file)')


# ── HTTP ─────────────────────────────────────────────────────────────────────


class Api:
    def __init__(self, base: str, minter: TokenMinter, timeout: float = 60) -> None:
        self.base = base.rstrip('/')
        self.minter = minter
        self.timeout = timeout

    def request(self, method: str, path: str,
                query: Optional[Dict[str, str]] = None,
                body: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
        # Pagination links come back absolute; everything else is a path.
        url = path if '://' in path else self.base + path
        if query:
            url += ('&' if '?' in url else '?') + urllib.parse.urlencode(query)
        data = None if body is None else json.dumps(body).encode('utf-8')
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header('Authorization', f'Bearer {self.minter.token()}')
        req.add_header('Accept', 'application/json')
        req.add_header('User-Agent', 'asc_api.py')
        if data is not None:
            req.add_header('Content-Type', 'application/json')
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                payload = resp.read()
        except urllib.error.HTTPError as err:
            raise ApiFailure(method, url, err.code, _errors_of(err))
        except urllib.error.URLError as err:
            raise ApiFailure(method, url, None, [], str(err.reason))
        except (OSError, http.client.HTTPException) as err:
            raise ApiFailure(method, url, None, [], str(err) or type(err).__name__)
        if not payload.strip():
            return None
        try:
            return json.loads(payload.decode('utf-8'))
        except ValueError:
            raise ApiFailure(method, url, None, [], 'response was not JSON')

    def get(self, path: str, query: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
        return self.request('GET', path, query) or {}

    def get_all(self, path: str, query: Optional[Dict[str, str]] = None) -> List[Dict[str, Any]]:
        doc = self.get(path, query)
        items = list(doc.get('data') or [])
        for _ in range(50):
            nxt = (doc.get('links') or {}).get('next')
            if not nxt:
                break
            doc = self.get(nxt)
            items.extend(doc.get('data') or [])
        return items


def _errors_of(err: urllib.error.HTTPError) -> List[Dict[str, Any]]:
    try:
        doc = json.loads(err.read().decode('utf-8'))
    except (ValueError, OSError):
        return []
    errors = doc.get('errors') if isinstance(doc, dict) else None
    return [e for e in errors if isinstance(e, dict)] if isinstance(errors, list) else []


def attrs(resource: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    return (resource or {}).get('attributes') or {}


def related_id(resource: Dict[str, Any], name: str) -> Optional[str]:
    data = ((resource.get('relationships') or {}).get(name) or {}).get('data')
    return data.get('id') if isinstance(data, dict) else None


def ref(kind: str, ident: str) -> Dict[str, Any]:
    return {'data': {'type': kind, 'id': ident}}


# ── lookups shared by the subcommands ────────────────────────────────────────


def app_id(api: Api, bundle_id: str) -> str:
    apps = api.get('/v1/apps', {'filter[bundleId]': bundle_id}).get('data') or []
    # The filter is not guaranteed to be an exact match; never act on a
    # neighbouring app because it sorted first.
    exact = [a for a in apps if attrs(a).get('bundleId') == bundle_id]
    if not exact:
        raise Failure(EXIT_API, f'no app with bundle id {bundle_id} is visible '
                      'to this API key')
    return exact[0]['id']


def find_build(api: Api, app: str, version: str, build: str,
               with_beta: bool = False) -> Tuple[Optional[Dict[str, Any]], Dict[str, Any]]:
    query = {'filter[app]': app, 'filter[version]': build,
             'filter[preReleaseVersion.version]': version, 'limit': '10'}
    if with_beta:
        query['include'] = 'buildBetaDetail'
    doc = api.get('/v1/builds', query)
    builds = [b for b in doc.get('data') or [] if attrs(b).get('version') in (None, build)]
    if not builds:
        return None, {}
    found = builds[0]
    beta_id = related_id(found, 'buildBetaDetail')
    details = [r for r in doc.get('included') or [] if r.get('type') == 'buildBetaDetails']
    beta = next((r for r in details if r.get('id') == beta_id), None)
    if beta is None and len(details) == 1:
        beta = details[0]
    return found, attrs(beta)


def require_build(api: Api, app: str, version: str, build: str) -> Dict[str, Any]:
    found, _ = find_build(api, app, version, build)
    if found is None:
        raise Failure(EXIT_API, f'build {build} of {version} is not in App Store '
                      'Connect yet (run wait-build first)')
    return found


def find_version(api: Api, app: str, version: str) -> Optional[Dict[str, Any]]:
    versions = api.get_all(f'/v1/apps/{app}/appStoreVersions', {
        'filter[versionString]': version, 'filter[platform]': 'IOS', 'limit': '10'})
    for candidate in versions:
        a = attrs(candidate)
        if a.get('versionString', version) == version and a.get('platform', 'IOS') == 'IOS':
            return candidate
    return None


def require_version(api: Api, app: str, version: str) -> Dict[str, Any]:
    found = find_version(api, app, version)
    if found is None:
        raise Failure(EXIT_API, f'no iOS App Store version {version} exists '
                      '(prepare-version creates it)')
    return found


def state_of(version: Dict[str, Any]) -> Optional[str]:
    # appStoreState is deprecated in favour of appVersionState; read whichever
    # this API revision sends. The values used here have the same names.
    a = attrs(version)
    return a.get('appStoreState') or a.get('appVersionState')


# ── subcommands ──────────────────────────────────────────────────────────────


def cmd_wait_build(api: Api, args: argparse.Namespace) -> Dict[str, Any]:
    app = app_id(api, args.bundle_id)
    deadline = time.monotonic() + args.timeout
    started = time.monotonic()
    fields: Dict[str, Any] = {'version': args.version, 'build': args.build,
                              'buildId': None, 'processingState': None,
                              'internalBuildState': None}
    last_seen: Any = ('start',)
    last_report = started
    while True:
        try:
            found, beta = find_build(api, app, args.version, args.build, with_beta=True)
        except ApiFailure as err:
            # A blip during a 90-minute wait is no reason to send the human
            # back to watching their inbox.
            if not err.transient:
                raise
            for line in err.lines():
                log(f'{line} (will retry)')
            found, beta = None, {}
            seen = ('error',)
        else:
            if found is not None:
                fields['buildId'] = found['id']
                fields['processingState'] = attrs(found).get('processingState')
                fields['internalBuildState'] = beta.get('internalBuildState')
            seen = ((fields['processingState'], fields['internalBuildState'])
                    if found is not None else None)
        processing = fields['processingState']
        internal = fields['internalBuildState']
        elapsed = int(time.monotonic() - started)

        if found is not None:
            if processing in BUILD_FAILED_STATES:
                raise Failure(EXIT_API, f'build {args.build} processing ended '
                              f'{processing}; Apple\'s email says why', fields)
            if processing == 'VALID':
                if internal in BETA_READY_STATES:
                    log(f'build {args.build} is processed and {internal}')
                    return fields
                if internal == 'MISSING_EXPORT_COMPLIANCE':
                    raise Failure(EXIT_EXPORT_COMPLIANCE,
                                  f'build {args.build} is processed but Missing '
                                  f'Compliance. {EXPORT_COMPLIANCE_HELP}', fields)
                if internal in BETA_FAILED_STATES:
                    raise Failure(EXIT_API, f'build {args.build} is {internal} '
                                  'for TestFlight', fields)

        if seen != last_seen or time.monotonic() - last_report >= 300:
            if found is None and seen != ('error',):
                log(f'build {args.build} of {args.version} not visible yet '
                    f'({elapsed}s); normal for a while after the upload')
            elif found is not None:
                log(f'build {args.build}: processingState={processing} '
                    f'internalBuildState={internal} ({elapsed}s)')
            last_seen = seen
            last_report = time.monotonic()

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise Failure(EXIT_TIMEOUT, f'build {args.build} was not ready after '
                          f'{int(args.timeout)}s', fields)
        time.sleep(max(0.0, min(args.interval, remaining)))


def cmd_add_to_group(api: Api, args: argparse.Namespace) -> Dict[str, Any]:
    app = app_id(api, args.bundle_id)
    build = require_build(api, app, args.version, args.build)
    groups = api.get_all(f'/v1/apps/{app}/betaGroups', {'limit': '200'})
    internal = [g for g in groups if attrs(g).get('isInternalGroup')]
    names = [attrs(g).get('name') for g in internal]
    fields: Dict[str, Any] = {'version': args.version, 'build': args.build,
                              'buildId': build['id'], 'internalGroups': names}
    if args.group:
        chosen = [g for g in internal if attrs(g).get('name') == args.group]
        if not chosen:
            external = any(attrs(g).get('name') == args.group for g in groups)
            why = 'is an external group' if external else 'does not exist'
            raise Failure(EXIT_API, f'TestFlight group {args.group!r} {why}; '
                          f'internal groups: {names}', fields)
        group = chosen[0]
    elif len(internal) == 1:
        group = internal[0]
    elif not internal:
        raise Failure(EXIT_API, 'this app has no internal TestFlight group; '
                      'create one in App Store Connect → TestFlight', fields)
    else:
        raise Failure(EXIT_API, f'several internal TestFlight groups, pass '
                      f'--group: {names}', fields)
    name = attrs(group).get('name')
    fields.update({'group': name, 'groupId': group['id'],
                   'hasAccessToAllBuilds': bool(attrs(group).get('hasAccessToAllBuilds'))})
    del fields['internalGroups']
    if fields['hasAccessToAllBuilds']:
        # Such a group refuses explicit assignment and already sees the build.
        log(f'internal group {name!r} gets every build; nothing to add')
        fields['added'] = False
        return fields
    api.request('POST', f'/v1/betaGroups/{group["id"]}/relationships/builds',
                body={'data': [{'type': 'builds', 'id': build['id']}]})
    log(f'added build {args.build} to internal group {name!r}')
    fields['added'] = True
    return fields


def cmd_prepare_version(api: Api, args: argparse.Namespace) -> Dict[str, Any]:
    whats_new = None
    if args.whats_new_file:
        # Read first: a bad path must not leave the version half-prepared.
        try:
            with open(args.whats_new_file, encoding='utf-8') as handle:
                whats_new = handle.read().strip()
        except OSError as err:
            raise Failure(EXIT_API, f'cannot read --whats-new-file: {err}')
    app = app_id(api, args.bundle_id)
    build = require_build(api, app, args.version, args.build)
    fields: Dict[str, Any] = {'version': args.version, 'build': args.build,
                              'buildId': build['id'], 'created': False}
    version = find_version(api, app, args.version)
    if version is None:
        if args.no_create:
            raise Failure(EXIT_API, f'no iOS App Store version {args.version} '
                          'and --no-create was given', fields)
        doc = api.request('POST', '/v1/appStoreVersions', body={'data': {
            'type': 'appStoreVersions',
            'attributes': {'platform': 'IOS', 'versionString': args.version},
            'relationships': {'app': ref('apps', app)}}}) or {}
        version = doc.get('data') or {}
        if not version.get('id'):
            raise Failure(EXIT_API, 'creating the App Store version returned no id', fields)
        fields['created'] = True
        log(f'created iOS App Store version {args.version}')
    state = state_of(version)
    fields.update({'versionId': version['id'], 'appStoreState': state})
    if state not in EDITABLE_STATES:
        raise Failure(EXIT_API, f'App Store version {args.version} is {state}, '
                      'which cannot be edited', fields)
    api.request('PATCH', f'/v1/appStoreVersions/{version["id"]}/relationships/build',
                body=ref('builds', build['id']))
    log(f'selected build {args.build} for App Store version {args.version}')
    fields['whatsNew'] = 'not-requested'
    if whats_new is not None:
        fields['whatsNew'] = set_whats_new(api, version['id'], args.locale, whats_new)
    return fields


def set_whats_new(api: Api, version_id: str, locale: str, text: str) -> str:
    # Apple refuses What's New on an app's first version, and the release can
    # go ahead without it, so every failure here is a warning.
    if not text:
        log('warning: the What\'s New file is empty; leaving What\'s New alone')
        return 'skipped'
    try:
        locs = api.get_all(f'/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations',
                           {'limit': '200'})
        match = [loc for loc in locs if attrs(loc).get('locale') == locale]
        if not match:
            log(f'warning: no {locale} localization on this version '
                f'(have {[attrs(x).get("locale") for x in locs]}); What\'s New not set')
            return 'skipped'
        api.request('PATCH', f'/v1/appStoreVersionLocalizations/{match[0]["id"]}',
                    body={'data': {'type': 'appStoreVersionLocalizations',
                                   'id': match[0]['id'],
                                   'attributes': {'whatsNew': text}}})
    except ApiFailure as err:
        log('warning: What\'s New was not set (expected on an app\'s first '
            'version); continuing')
        for line in err.lines():
            log(f'  {line}')
        return 'skipped'
    log(f'set What\'s New for {locale}')
    return 'updated'


def cmd_submit(api: Api, args: argparse.Namespace) -> Dict[str, Any]:
    app = app_id(api, args.bundle_id)
    version = require_version(api, app, args.version)
    state = state_of(version)
    fields: Dict[str, Any] = {'version': args.version, 'versionId': version['id'],
                              'appStoreState': state}
    if state in ALREADY_SUBMITTED_STATES:
        log(f'version {args.version} is already {state}; nothing to submit')
        fields['alreadySubmitted'] = True
        return fields
    if state not in SUBMITTABLE_STATES:
        raise Failure(EXIT_API, f'App Store version {args.version} is {state}, '
                      'which cannot be submitted', fields)
    open_subs = api.get_all('/v1/reviewSubmissions', {
        'filter[app]': app, 'filter[platform]': 'IOS',
        'filter[state]': 'READY_FOR_REVIEW', 'limit': '10'})
    if open_subs:
        # Apple allows one draft submission per platform; a second POST is
        # refused, so a draft left by a person or an earlier run is the one.
        submission_id = open_subs[0]['id']
        fields['createdSubmission'] = False
        log(f'reusing draft review submission {submission_id}')
        has_item = submission_has_version(api, submission_id, version['id'])
    else:
        doc = api.request('POST', '/v1/reviewSubmissions', body={'data': {
            'type': 'reviewSubmissions', 'attributes': {'platform': 'IOS'},
            'relationships': {'app': ref('apps', app)}}}) or {}
        submission_id = (doc.get('data') or {}).get('id')
        if not submission_id:
            raise Failure(EXIT_API, 'creating the review submission returned no id', fields)
        fields['createdSubmission'] = True
        log(f'created review submission {submission_id}')
        has_item = False
    fields['submissionId'] = submission_id
    if not has_item:
        api.request('POST', '/v1/reviewSubmissionItems', body={'data': {
            'type': 'reviewSubmissionItems',
            'relationships': {
                'reviewSubmission': ref('reviewSubmissions', submission_id),
                'appStoreVersion': ref('appStoreVersions', version['id'])}}})
        log(f'added version {args.version} to the submission')
    fields['itemAdded'] = not has_item
    # Adding the item is "Add for Review"; Apple receives nothing until this.
    doc = api.request('PATCH', f'/v1/reviewSubmissions/{submission_id}', body={'data': {
        'type': 'reviewSubmissions', 'id': submission_id,
        'attributes': {'submitted': True}}}) or {}
    fields['submissionState'] = attrs(doc.get('data')).get('state')
    fields['alreadySubmitted'] = False
    log(f'submitted version {args.version} for review')
    return fields


def submission_has_version(api: Api, submission_id: str, version_id: str) -> bool:
    try:
        items = api.get_all(f'/v1/reviewSubmissions/{submission_id}/items',
                            {'include': 'appStoreVersion', 'limit': '100'})
    except ApiFailure as err:
        log(f'warning: could not list the draft\'s items ({err.message}); '
            'adding the version anyway')
        return False
    return any(related_id(item, 'appStoreVersion') == version_id for item in items)


def cmd_version_state(api: Api, args: argparse.Namespace) -> Dict[str, Any]:
    app = app_id(api, args.bundle_id)
    version = require_version(api, app, args.version)
    a = attrs(version)
    fields: Dict[str, Any] = {'version': args.version, 'versionId': version['id'],
                              'appStoreState': state_of(version)}
    if a.get('appVersionState'):
        fields['appVersionState'] = a['appVersionState']
    log(f'version {args.version}: appStoreState={fields["appStoreState"]}'
        + (f' appVersionState={a["appVersionState"]}' if a.get('appVersionState') else ''))
    return fields


def cmd_release(api: Api, args: argparse.Namespace) -> Dict[str, Any]:
    app = app_id(api, args.bundle_id)
    version = require_version(api, app, args.version)
    state = state_of(version)
    fields: Dict[str, Any] = {'version': args.version, 'versionId': version['id'],
                              'appStoreState': state, 'released': False}
    if state != 'PENDING_DEVELOPER_RELEASE':
        # Releasing is the one irreversible step; act only on the exact state
        # in which "Release This Version" is what a person would press.
        raise Failure(EXIT_API, f'version {args.version} is {state}, not '
                      'PENDING_DEVELOPER_RELEASE; not releasing', fields)
    api.request('POST', '/v1/appStoreVersionReleaseRequests', body={'data': {
        'type': 'appStoreVersionReleaseRequests',
        'relationships': {'appStoreVersion': ref('appStoreVersions', version['id'])}}})
    log(f'release requested for version {args.version}')
    fields['released'] = True
    return fields


COMMANDS = {
    'wait-build': cmd_wait_build,
    'add-to-group': cmd_add_to_group,
    'prepare-version': cmd_prepare_version,
    'submit': cmd_submit,
    'version-state': cmd_version_state,
    'release': cmd_release,
}


# ── CLI ──────────────────────────────────────────────────────────────────────


def build_parser() -> argparse.ArgumentParser:
    def common(defaults: Any) -> argparse.ArgumentParser:
        p = argparse.ArgumentParser(add_help=False)
        p.add_argument('--key-id', default=defaults,
                       help='API key id (default: $ASC_KEY_ID)')
        p.add_argument('--issuer', default=defaults,
                       help='issuer id (default: $ASC_ISSUER_UUID)')
        p.add_argument('--key-file', default=defaults,
                       help='AuthKey_<KEYID>.p8 (default: searched like altool)')
        p.add_argument('--bundle-id', default=defaults,
                       help=f'default: {DEFAULT_BUNDLE_ID}')
        return p

    parser = argparse.ArgumentParser(
        description='App Store Connect API steps for release-apple.sh.',
        parents=[common(None)])
    # The shared options may come before or after the subcommand; SUPPRESS
    # keeps a subcommand's unset copy from erasing one given before it.
    shared = common(argparse.SUPPRESS)
    sub = parser.add_subparsers(dest='command', metavar='COMMAND')
    sub.required = True

    def add(name: str, help_text: str, build: bool = True) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=help_text, parents=[shared])
        p.add_argument('--version', required=True, help='marketing version X.Y.Z')
        if build:
            p.add_argument('--build', required=True, help='build number (CFBundleVersion)')
        return p

    p = add('wait-build', 'wait for the uploaded build to finish processing')
    p.add_argument('--timeout', type=float, default=5400, help='seconds (default 5400)')
    p.add_argument('--interval', type=float, default=60, help='seconds between polls (default 60)')
    p = add('add-to-group', 'add the build to the internal TestFlight group')
    p.add_argument('--group', help='internal group name (needed when there are several)')
    p = add('prepare-version', 'create/find the App Store version and select the build')
    p.add_argument('--whats-new-file', help='UTF-8 text for What\'s New')
    p.add_argument('--locale', default='en-US', help='localization for What\'s New (default en-US)')
    p.add_argument('--no-create', action='store_true', help='fail instead of creating the version')
    add('submit', 'submit the App Store version for review', build=False)
    add('version-state', 'print the App Store version state', build=False)
    add('release', 'release a version that is Pending Developer Release', build=False)
    return parser


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    args.bundle_id = args.bundle_id or DEFAULT_BUNDLE_ID
    summary: Dict[str, Any] = {'command': args.command}
    try:
        key_id, issuer, key_file = resolve_credentials(args)
        minter = TokenMinter(key_id, issuer, key_file)
        # Mint now: a key openssl cannot use is a setup problem (exit 2), and
        # should not surface as a failed request half-way through a step.
        minter.token()
        base = os.environ.get('LB_ASC_API_BASE') or DEFAULT_API_BASE
        summary.update(COMMANDS[args.command](Api(base, minter), args))
        code = EXIT_OK
    except Failure as failure:
        for line in failure.lines():
            log(line)
        summary.update(failure.fields)
        summary['error'] = failure.message
        code = failure.code
    summary['ok'] = code == EXIT_OK
    summary['exitCode'] = code
    print(json.dumps(summary, separators=(',', ':')), flush=True)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
