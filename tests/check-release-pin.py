#!/usr/bin/env python3
"""Compare the public bootstrap's immutable runtime with the reviewed checkout.

No downloaded code is extracted or executed. Docs/tests/deploy.sh are excluded
because the bootstrap commit must follow the runtime commit it references.
"""
import io
import pathlib
import re
import subprocess
import sys
import tarfile
import tempfile


def runtime_files(repo):
    paths = [repo / 'install.sh', repo / 'xray-manager.sh']
    paths += sorted((repo / 'lib').glob('*.sh'))
    paths += sorted(p for p in (repo / 'assets').iterdir() if p.is_file())
    return {p.relative_to(repo).as_posix(): p.read_bytes() for p in paths}


def verify(archive, expected):
    actual = {}
    with tarfile.open(archive, 'r:gz') as tar:
        for member in tar:
            path = pathlib.PurePosixPath(member.name)
            if path.is_absolute() or '..' in path.parts:
                raise ValueError('unsafe archive path')
            relative = '/'.join(path.parts[1:])
            if relative not in expected and not relative.startswith(('lib/', 'assets/')):
                continue
            if member.isdir():
                continue
            if not member.isfile() or member.size > 2 * 1024 * 1024 or relative in actual:
                raise ValueError('invalid runtime member: ' + relative)
            actual[relative] = tar.extractfile(member).read()
    differences = sorted(p for p in set(actual) | set(expected) if actual.get(p) != expected.get(p))
    if differences:
        raise ValueError('bootstrap runtime differs from checkout: ' + ', '.join(differences))


def self_test(expected, directory):
    archive = directory / 'fixture.tar.gz'
    for outdated in (False, True):
        with tarfile.open(archive, 'w:gz') as tar:
            for name, content in expected.items():
                if outdated and name == 'lib/common.sh':
                    content += b'\n# stale release runtime\n'
                member = tarfile.TarInfo('AI-fixture/' + name)
                member.size = len(content)
                tar.addfile(member, io.BytesIO(content))
        try:
            verify(archive, expected)
        except ValueError:
            if not outdated:
                raise
        else:
            if outdated:
                raise AssertionError('stale runtime accepted')
    print('PASS: release gate accepts matching runtime and rejects stale core defaults')


def main():
    repo = pathlib.Path(__file__).resolve().parent.parent
    pins = re.findall(r'^\s*(https://github\.com/miaoshououdezhi/AI/archive/[0-9a-f]{40}\.tar\.gz)\s*$',
                      (repo / 'deploy.sh').read_text(), re.M)
    if len(pins) != 1:
        raise ValueError('deploy.sh must contain exactly one immutable project runtime URL')
    expected = runtime_files(repo)
    with tempfile.TemporaryDirectory() as directory:
        scratch = pathlib.Path(directory)
        self_test(expected, scratch)
        if sys.argv[1:] == ['--self-test']:
            return
        if sys.argv[1:]:
            raise ValueError('only --self-test is supported')
        archive = scratch / 'release.tar.gz'
        subprocess.run(['curl', '--fail', '--silent', '--show-error', '--location', '--proto', '=https',
                        '--proto-redir', '=https', '--tlsv1.2', '--retry', '2', '--connect-timeout', '15',
                        '--max-time', '180', '--max-filesize', '10485760', '--output', str(archive), pins[0]], check=True)
        verify(archive, expected)
        print('PASS: public bootstrap pin matches all reviewed runtime files: ' + pins[0])


if __name__ == '__main__':
    main()
