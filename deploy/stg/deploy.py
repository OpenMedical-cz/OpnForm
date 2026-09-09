#!/usr/bin/env python3
"""Run as root over SSH. Secrets arrive on stdin, never in command arguments."""

import base64
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import signal
import shutil
import subprocess
import sys
import tempfile

ROOT = Path('/opt/opnform/deploy/stg')
CONFIG = Path('/etc/opnform/stg')
CADDY_SITE = Path('/etc/caddy/sites-enabled/opnform-stg.caddy')
CADDY_CONFIG = Path('/etc/caddy/Caddyfile')


def run(*args, **kwargs):
    subprocess.run(args, check=True, cwd=ROOT, **kwargs)


def atomic_write(path, content):
    fd, temporary = tempfile.mkstemp(prefix='.opnform-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(content)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    if os.geteuid() != 0:
        raise ValueError('Root access is required')
    os.umask(0o077)
    # Fixed subprocess environment; callers cannot override Compose or Python.
    os.environ.clear()
    os.environ.update(PATH='/usr/sbin:/usr/bin:/sbin:/bin', LANG='C.UTF-8')
    lock = open('/run/lock/opnform-stg-deploy.lock', 'w')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    signal.alarm(30)
    raw = sys.stdin.read(16385)
    signal.alarm(0)
    if len(raw) > 16384:
        raise ValueError('Payload too large')
    payload = json.loads(raw)
    if set(payload) != {'api', 'client', 'smtp_password', 'http_password', 'registry_user', 'registry_token'}:
        raise ValueError('Unexpected payload fields')
    if not all(isinstance(value, str) for value in payload.values()):
        raise ValueError('Invalid payload types')
    if not re.fullmatch(r'[A-Za-z0-9_\[\]-]{1,100}', payload['registry_user']):
        raise ValueError('Invalid registry user')
    if not payload['registry_token'] or len(payload['registry_token']) > 4096:
        raise ValueError('Invalid registry credential')
    for name, image in [('api', 'opnform-api'), ('client', 'opnform-client')]:
        if not re.fullmatch(r'ghcr\.io/openmedical-cz/' + image + r'@sha256:[0-9a-f]{64}', payload[name]):
            raise ValueError('Invalid release image digest')
    password = ''.join(payload['smtp_password'].split())
    if not re.fullmatch(r'[A-Za-z0-9]{16}', password):
        raise ValueError('SMTP_PASSWORD must contain a Google app password')
    http_password = payload['http_password']
    if not 16 <= len(http_password) <= 128 or any(character in '\r\n\0' for character in http_password):
        raise ValueError('Invalid staging HTTP password')

    # No service mutations until the mounted device and directories pass.
    run('bash', str(ROOT / 'check-volume.sh'))
    CONFIG.mkdir(parents=True, exist_ok=True, mode=0o700)
    CONFIG.chmod(0o700)
    runtime = CONFIG / 'runtime.env'
    # Never read, rotate, or overwrite an existing application's keys.
    if not runtime.exists():
        template = (ROOT / 'runtime.example').read_text()
        values = {
            'REPLACE_WITH_RANDOM_PASSWORD': secrets.token_hex(32),
            'REPLACE_WITH_LARAVEL_APP_KEY': 'base64:' + base64.b64encode(secrets.token_bytes(32)).decode(),
            'REPLACE_WITH_RANDOM_SHARED_SECRET': secrets.token_hex(32),
        }
        for placeholder, value in values.items():
            template = template.replace(placeholder, value)
        fd = os.open(runtime, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as handle:
            handle.write(template)
    runtime.chmod(0o600)
    atomic_write(CONFIG / 'smtp.env', 'MAIL_PASSWORD=' + password + '\n')

    release = ROOT / 'release.env'
    if release.exists():
        shutil.copyfile(release, ROOT / 'previous-release.env')
    atomic_write(release, f"API_IMAGE={payload['api']}\nCLIENT_IMAGE={payload['client']}\n")

    # Registry login is scoped to a temporary directory and removed afterwards.
    with tempfile.TemporaryDirectory(prefix='opnform-registry-') as registry_config:
        docker = ['docker', '--config', registry_config]
        run(*docker, 'login', 'ghcr.io', '--username', payload['registry_user'],
            '--password-stdin', input=payload['registry_token'], text=True,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        compose = docker + ['compose', '--env-file', str(runtime), '--env-file', str(release)]
        run(*compose, 'config', '--quiet')
        run(*compose, 'pull')

    # Service, scripts, and Compose are installed separately by an administrator.
    run('systemctl', 'restart', 'opnform-stg.service')
    run('curl', '--fail', '--silent', '--show-error', '--output', '/dev/null',
        '--max-time', '30', 'http://127.0.0.1:3080/login')

    # Expose staging only behind authentication. The plaintext never enters argv.
    password_hash = subprocess.check_output(
        ['caddy', 'hash-password', '--algorithm', 'argon2id'],
        input=http_password + '\n', text=True, stderr=subprocess.DEVNULL,
    ).strip()
    site = f'''stg-forms.venova.cz {{
    basic_auth {{
        venova {password_hash}
    }}
    header X-Robots-Tag "noindex, nofollow, noarchive"
    reverse_proxy 127.0.0.1:3080
}}
'''
    previous_site = CADDY_SITE.read_text() if CADDY_SITE.exists() else None
    atomic_write(CADDY_SITE, site)
    try:
        run('caddy', 'validate', '--config', str(CADDY_CONFIG), '--adapter', 'caddyfile',
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        if previous_site is None:
            CADDY_SITE.unlink(missing_ok=True)
        else:
            atomic_write(CADDY_SITE, previous_site)
        raise
    run('systemctl', 'reload', 'caddy')
    print('Staging containers and authenticated HTTPS routing are healthy. Mail delivery still requires verification.')


if __name__ == '__main__':
    try:
        main()
    except Exception:
        # Do not serialize input, environments, exception values, or secrets.
        print('Staging deployment failed; inspect service health without printing secret files.', file=sys.stderr)
        sys.exit(1)
