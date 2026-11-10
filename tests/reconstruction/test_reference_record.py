from pathlib import Path
import hashlib
import importlib.util
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('reference',ROOT/'Beta/reconstruction/reference_record.py')
reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)

class ReferenceRecord(unittest.TestCase):
    def scenario(self):
        return {'schema':1,'deployment':{'kind':'clean','previous_build':'none'},
                'result':{'reproduction':'not-run'},'files':[]}
    def test_missing_values_stay_missing(self):
        r=reference.record(self.scenario(),ROOT)
        self.assertEqual(r['identification_gate'],'incomplete')
        self.assertIn('gpu.rendering_luid',r['missing_evidence'])
        self.assertIn('file role: loaded_modules',r['missing_evidence'])
        self.assertFalse(r['simulator_pass'])
    def test_artifacts_verified_not_assumed(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);(root/'test.txt').write_bytes(b'test fixture, not a runtime')
            s=self.scenario();s['files']=[{'role':'runtime','path':'test.txt','expected_sha256':'0'*64}]
            r=reference.record(s,root)
            self.assertFalse(r['artifacts'][0]['matches'])
            self.assertIn('artifact mismatch: test.txt',r['missing_evidence'])
            s['files'][0]['expected_sha256']=hashlib.sha256((root/'test.txt').read_bytes()).hexdigest()
            self.assertTrue(reference.record(s,root)['artifacts'][0]['matches'])
    def test_escape_and_unknown_hash_rejected(self):
        s=self.scenario();s['files']=[{'role':'runtime','path':'../outside','expected_sha256':'0'*64}]
        with self.assertRaisesRegex(ValueError,'escapes'):reference.record(s,ROOT)
        s['files'][0]['path']='README.md';s['files'][0]['expected_sha256']='unknown'
        with self.assertRaisesRegex(ValueError,'pinned'):reference.record(s,ROOT)
    def test_clean_cannot_silently_mean_upgrade(self):
        s=self.scenario();s['deployment']['previous_build']='Test18'
        with self.assertRaisesRegex(ValueError,'Clean'):reference.record(s,ROOT)
    def test_invalid_claim_rejected(self):
        s=self.scenario();s['result']['reproduction']='passed'
        with self.assertRaisesRegex(ValueError,'inferred'):reference.record(s,ROOT)
    def test_false_off_is_known_not_missing(self):
        s=self.scenario();s['nr']={'requested':False};s['display']={'hdr':False,'vrr':False}
        r=reference.record(s,ROOT)
        for key in ('nr.requested','display.hdr','display.vrr'):self.assertNotIn(key,r['missing_evidence'])
    def test_blank_is_not_identification_evidence(self):
        s=self.scenario();s['gpu']={'rendering_luid':'   ','driver':'UNKNOWN'}
        r=reference.record(s,ROOT)
        for key in ('gpu.rendering_luid','gpu.driver'):self.assertIn(key,r['missing_evidence'])

if __name__=='__main__':unittest.main(verbosity=2)
