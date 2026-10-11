#!/usr/bin/env python3
"""Yerel ses modelleri: sürüm denetimi, güncelleme ve doğrulama.

Kurulum ekranı bu aracı Python ortamıyla çalıştırır:
  local_models.py verify   konuşma tanıma ve ses üretimini sınar
  local_models.py check    yeni sürüm var mı diye bakar, tek satır JSON yazar
  local_models.py update   paketi ve modelleri günceller, sınar, başarısızsa geri alır
Yalnızca standart kütüphane kullanır (huggingface_hub güncellemede ortamdan alınır).
"""
import importlib.metadata as metadata
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

PACKAGE = 'ema-lightning'
PYPI_URL = 'https://pypi.org/pypi/%s/json' % PACKAGE
HF_API = 'https://huggingface.co/api/models/%s'


def hub_dir():
    if os.environ.get('HF_HUB_CACHE'):
        return Path(os.environ['HF_HUB_CACHE'])
    home = Path(os.environ.get('HF_HOME') or Path.home() / '.cache' / 'huggingface')
    return home / 'hub'


def cached_repos(hub=None):
    hub = hub or hub_dir()
    if not hub.is_dir():
        return []
    return sorted(p.name[len('models--'):].replace('--', '/') for p in hub.iterdir() if p.name.startswith('models--') and p.is_dir())


def local_revision(repo, hub=None):
    ref = (hub or hub_dir()) / ('models--' + repo.replace('/', '--')) / 'refs' / 'main'
    try:
        return ref.read_text().strip()
    except OSError:
        return ''


def restore_revision(repo, revision, hub=None):
    ref = (hub or hub_dir()) / ('models--' + repo.replace('/', '--')) / 'refs' / 'main'
    if revision:
        ref.parent.mkdir(parents=True, exist_ok=True)
        ref.write_text(revision)


def installed_version():
    try:
        return metadata.version(PACKAGE)
    except metadata.PackageNotFoundError:
        return ''


def fetch_json(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'Asistan'})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def version_key(text):
    return tuple(int(part) for part in re.findall(r'\d+', text.split('+')[0].split('-')[0]))


def is_newer(latest, installed):
    if not latest or latest == installed:
        return False
    if not installed:
        return True
    try:
        return version_key(latest) > version_key(installed)
    except ValueError:
        return True


def check(hub=None):
    result = {'package': {'name': PACKAGE, 'installed': installed_version(), 'latest': '', 'update': False}, 'models': [], 'errors': []}
    try:
        latest = fetch_json(PYPI_URL)['info']['version']
        result['package'].update(latest=latest, update=is_newer(latest, result['package']['installed']))
    except Exception as error:
        result['errors'].append('Paket sürümü alınamadı: %s' % error)
    for repo in cached_repos(hub):
        local = local_revision(repo, hub)
        item = {'repo': repo, 'local': local, 'remote': '', 'update': False}
        try:
            item['remote'] = fetch_json(HF_API % repo)['sha']
            item['update'] = bool(item['remote']) and item['remote'] != local
        except Exception as error:
            result['errors'].append('%s sürümü alınamadı: %s' % (repo, error))
        result['models'].append(item)
    return result


def verify():
    """setup.sh ile aynı sınama: iki yerel konuşma motoru da çalışmalı."""
    import importlib.util
    import numpy as np
    path = Path(os.environ['ASISTAN_RES']) / 'agent.py'
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location('asistan_setup', path)
    agent = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = agent
    spec.loader.exec_module(agent)
    import mlx_whisper
    mlx_whisper.transcribe(np.zeros(16000, dtype=np.float32), path_or_hf_repo=agent.WHISPER_MODEL, language='tr', verbose=None)
    from ema_lightning import EMA
    speech = EMA(device='cpu').say('Merhaba.', sample_rate=48000)
    assert len(speech.audio) > 0
    print('Konuşma tanıma ve ses üretimi doğrulandı.')


def run_verify():
    return subprocess.run([sys.executable, '-B', os.path.abspath(__file__), 'verify']).returncode == 0


def install_package(uv, python, spec):
    subprocess.run([uv, 'pip', 'install', '--python', python, spec], check=True)


def snapshot(repo):
    from huggingface_hub import snapshot_download
    snapshot_download(repo_id=repo, revision='main')


def update(hub=None, uv=None, python=None, overrides=None):
    """Yeni sürümleri kurar ve sınar; sınama başarısız olursa eski sürüme döner."""
    uv = uv or os.environ.get('ASISTAN_UV') or 'uv'
    python = python or sys.executable
    found = check(hub)
    if found['errors'] and not found['package']['latest']:
        print('Sürümler denetlenemedi: ' + '; '.join(found['errors']))
        return 2
    old_version = found['package']['installed']
    old_revisions = {m['repo']: m['local'] for m in found['models']}
    todo = [m['repo'] for m in found['models'] if m['update']]
    new_version = found['package']['latest'] if found['package']['update'] else ''
    if not new_version and not todo:
        print('Her şey güncel.')
        return 0
    try:
        if new_version:
            print('STEP|paket|start')
            install_package(uv, python, '%s==%s' % (PACKAGE, new_version))
        for repo in todo:
            print('STEP|%s|start' % repo)
            snapshot(repo)
        print('STEP|sinama|start')
        if not run_verify():
            raise RuntimeError('güncel sürümler sınamayı geçemedi')
    except Exception as error:
        print('Güncelleme başarısız (%s); önceki sürüme dönülüyor.' % error)
        if new_version and old_version:
            try:
                install_package(uv, python, '%s==%s' % (PACKAGE, old_version))
            except Exception as back:
                print('Paket geri alınamadı: %s' % back)
        for repo in todo:
            restore_revision(repo, old_revisions.get(repo, ''), hub)
        return 1
    if new_version and overrides:
        keep = [line for line in (overrides.read_text().splitlines() if overrides.exists() else []) if not line.startswith(PACKAGE + '==')]
        overrides.write_text('\n'.join(keep + ['%s==%s' % (PACKAGE, new_version)]) + '\n')
    print('Güncellendi ve sınandı.')
    return 0


def main(argv):
    command = argv[1] if len(argv) > 1 else ''
    if command == 'verify':
        verify()
        return 0
    if command == 'check':
        print(json.dumps(check(), ensure_ascii=False))
        return 0
    if command == 'update':
        home = os.environ.get('ASISTAN_HOME')
        return update(overrides=Path(home) / 'local_overrides.txt' if home else None)
    print(__doc__)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv))
