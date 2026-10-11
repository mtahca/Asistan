import importlib.util, io, tempfile, unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('local_models', Path(__file__).resolve().parent.parent / 'local_models.py')
lm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lm)


def make_hub(root, repos):
    for repo, revision in repos.items():
        ref = Path(root) / ('models--' + repo.replace('/', '--')) / 'refs' / 'main'
        ref.parent.mkdir(parents=True)
        ref.write_text(revision + '\n')
    (Path(root) / 'datasets--x--y').mkdir()
    return Path(root)


class LocalModelsTest(unittest.TestCase):
    def test_cached_repos_and_revisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            hub = make_hub(tmp, {'org/model-a': 'aaa', 'b/c': 'bbb'})
            self.assertEqual(lm.cached_repos(hub), ['b/c', 'org/model-a'])
            self.assertEqual(lm.local_revision('org/model-a', hub), 'aaa')
            self.assertEqual(lm.local_revision('yok/model', hub), '')
            lm.restore_revision('org/model-a', 'zzz', hub)
            self.assertEqual(lm.local_revision('org/model-a', hub), 'zzz')
        self.assertEqual(lm.cached_repos(Path('/yok/hub')), [])

    def test_version_comparison(self):
        self.assertTrue(lm.is_newer('1.10.0', '1.9.3'))
        self.assertFalse(lm.is_newer('1.0.1', '1.0.1'))
        self.assertFalse(lm.is_newer('1.0.0', '1.0.1'))
        self.assertTrue(lm.is_newer('1.0.0', ''))
        self.assertFalse(lm.is_newer('', '1.0.0'))

    def test_check_reports_package_and_model_updates(self):
        def fake(url):
            if 'pypi.org' in url: return {'info': {'version': '1.1.0'}}
            return {'sha': 'new'} if url.endswith('org/model-a') else {'sha': 'same'}
        with tempfile.TemporaryDirectory() as tmp:
            hub = make_hub(tmp, {'org/model-a': 'old', 'org/model-b': 'same'})
            with patch.object(lm, 'fetch_json', fake), patch.object(lm, 'installed_version', return_value='1.0.1'):
                result = lm.check(hub)
        self.assertTrue(result['package']['update'])
        self.assertEqual([m['repo'] for m in result['models'] if m['update']], ['org/model-a'])
        self.assertEqual(result['errors'], [])

    def test_check_survives_network_errors(self):
        def broken(url): raise OSError('ağ yok')
        with tempfile.TemporaryDirectory() as tmp:
            hub = make_hub(tmp, {'org/model-a': 'old'})
            with patch.object(lm, 'fetch_json', broken), patch.object(lm, 'installed_version', return_value='1.0.1'):
                result = lm.check(hub)
        self.assertFalse(result['package']['update'])
        self.assertFalse(result['models'][0]['update'])
        self.assertEqual(len(result['errors']), 2)

    def run_update(self, verify_ok):
        installs, downloads = [], []
        with tempfile.TemporaryDirectory() as tmp:
            hub = make_hub(Path(tmp) / 'hub', {'org/model-a': 'old'})
            overrides = Path(tmp) / 'local_overrides.txt'
            def snapshot(repo):
                downloads.append(repo); lm.restore_revision(repo, 'new', hub)
            with patch.object(lm, 'fetch_json', lambda url: {'info': {'version': '1.1.0'}} if 'pypi.org' in url else {'sha': 'new'}), \
                 patch.object(lm, 'installed_version', return_value='1.0.1'), \
                 patch.object(lm, 'install_package', lambda uv, python, spec: installs.append(spec)), \
                 patch.object(lm, 'snapshot', snapshot), patch.object(lm, 'run_verify', return_value=verify_ok), \
                 redirect_stdout(io.StringIO()):
                code = lm.update(hub=hub, uv='uv', python='python', overrides=overrides)
            return code, installs, downloads, lm.local_revision('org/model-a', hub), overrides.read_text() if overrides.exists() else ''

    def test_update_success_keeps_new_versions_and_pins_package(self):
        code, installs, downloads, revision, overrides = self.run_update(True)
        self.assertEqual(code, 0)
        self.assertEqual(installs, ['ema-lightning==1.1.0'])
        self.assertEqual(downloads, ['org/model-a'])
        self.assertEqual(revision, 'new')
        self.assertIn('ema-lightning==1.1.0', overrides)

    def test_update_rolls_back_when_verification_fails(self):
        code, installs, downloads, revision, overrides = self.run_update(False)
        self.assertEqual(code, 1)
        self.assertEqual(installs, ['ema-lightning==1.1.0', 'ema-lightning==1.0.1'])
        self.assertEqual(revision, 'old')
        self.assertEqual(overrides, '')

    def test_update_does_nothing_when_current(self):
        with tempfile.TemporaryDirectory() as tmp:
            hub = make_hub(tmp, {'org/model-a': 'same'})
            with patch.object(lm, 'fetch_json', lambda url: {'info': {'version': '1.0.1'}} if 'pypi.org' in url else {'sha': 'same'}), \
                 patch.object(lm, 'installed_version', return_value='1.0.1'), patch.object(lm, 'install_package', side_effect=AssertionError), \
                 redirect_stdout(io.StringIO()):
                self.assertEqual(lm.update(hub=hub, uv='uv', python='python'), 0)


if __name__ == '__main__':
    unittest.main()
