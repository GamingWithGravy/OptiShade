import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Beta/reconstruction'))
import candidate_receipt as receipt


class CandidateReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'test-run').mkdir()
        (self.root / 'reconstruction').mkdir()
        (self.root / 'reconstruction/TESTER_CANDIDATE_CHECKLIST.md').write_text('fixture')
        self.exe = self.root / 'candidate.exe'
        self.exe.write_bytes(b'fixture installer')
        for name in ('route.dll', 'route.pdb'):
            (self.root / name).write_bytes(name.encode())
        self.native = {'SourceSHA256': 'A'*64, 'BuildInputsSHA256': 'B'*64,
                       'BuiltUtc': 'fixture time', 'SourceHead': 'fixture head',
                       'Binaries': {name: receipt.sha256(self.root/name) for name in ('route.dll','route.pdb')}}
        self.checked = {'Passed': True, 'ExecutableSHA256': receipt.sha256(self.exe),
                        'Build': {k:v for k,v in self.native.items() if k != 'Binaries'}}
        self.checked['Build']['NativeBinaries'] = self.native['Binaries'].copy()
        self.write()

    def write(self):
        (self.root/'test-run/native-build.json').write_text(json.dumps(self.native))
        Path(str(self.exe)+'.verification.json').write_text(json.dumps(self.checked))

    def test_receipt(self):
        with patch.object(receipt, 'verify', return_value={'matching_symbols': True, 'rsds': {'guid':'fixture','age':1}}):
            result=receipt.create(self.root,self.exe)
        self.assertEqual(len(result['MatchingSymbols']),1)
        self.assertEqual(result['GameQualification'],'Not run by packaging')

    def test_verified_manager_repack(self):
        build=self.checked['Build']
        build.update(BuildMode='ManagerOnlyRepackVerifiedRuntime', SourceSHA256='C'*64,
                     BuildInputsSHA256='D'*64, NativeBuildSourceSHA256=self.native['SourceSHA256'],
                     ManagerOnlyChanges=['installer/manager.ps1'])
        self.write()
        with patch.object(receipt, 'verified_repack_identity', return_value=build.copy()), patch.object(receipt, 'verify', return_value={'matching_symbols': True}):
            receipt.create(self.root,self.exe)
        wrong=build.copy(); wrong['SourceSHA256']='E'*64
        with patch.object(receipt, 'verified_repack_identity', return_value=wrong):
            with self.assertRaisesRegex(ValueError,'identity mismatch'):receipt.create(self.root,self.exe)
        with patch.object(receipt, 'verified_repack_identity', side_effect=ValueError('unexpected source')):
            with self.assertRaisesRegex(ValueError,'unexpected source'):receipt.create(self.root,self.exe)

    def test_changed_installer(self):
        self.exe.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'another executable'):receipt.create(self.root,self.exe)

    def test_changed_binary(self):
        (self.root/'route.dll').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'artifact changed'):receipt.create(self.root,self.exe)

    def test_wrong_source(self):
        self.checked['Build']['SourceSHA256']='C'*64;self.write()
        with self.assertRaisesRegex(ValueError,'identity mismatch'):receipt.create(self.root,self.exe)

    def test_equivalent_dotnet_and_python_utc_precision(self):
        self.native['BuiltUtc']='2026-10-25T07:09:50.7661520Z'
        self.checked['Build']['BuiltUtc']='2026-10-25T07:09:50.766152Z'
        self.write()
        with patch.object(receipt, 'verify', return_value={'matching_symbols': True, 'rsds': {'guid':'fixture','age':1}}):
            receipt.create(self.root,self.exe)

    def test_different_build_time(self):
        self.native['BuiltUtc']='2026-10-25T07:09:50.7661520Z'
        self.checked['Build']['BuiltUtc']='2026-10-25T07:09:50.766153Z'
        self.write()
        with self.assertRaisesRegex(ValueError,'identity mismatch: BuiltUtc'):receipt.create(self.root,self.exe)

    def test_wrong_symbols(self):
        with patch.object(receipt,'verify',side_effect=ValueError('DLL/PDB mismatch')):
            with self.assertRaisesRegex(ValueError,'DLL/PDB mismatch'):receipt.create(self.root,self.exe)

    def test_escape(self):
        with self.assertRaisesRegex(ValueError,'escapes'):receipt.contained(self.root,'../outside.dll')


if __name__=='__main__':unittest.main()
