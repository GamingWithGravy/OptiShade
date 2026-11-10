"""Synthetic file identity regressions. Fixtures are never executed."""
from pathlib import Path
import importlib.util
import struct
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('symbols',ROOT/'Beta/reconstruction/symbol_identity.py')
symbols=importlib.util.module_from_spec(spec);spec.loader.exec_module(symbols)

class Symbols(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.root=Path(self.tmp.name)
  self.dll=self.root/'fixture.dll';self.pdb=self.root/'fixture.pdb'
  guid=bytes(range(16));pe=bytearray(1024);pe[:2]=b'MZ'
  struct.pack_into('<I',pe,0x3c,128);pe[128:132]=b'PE\0\0'
  struct.pack_into('<H',pe,134,1);struct.pack_into('<H',pe,148,240)
  struct.pack_into('<H',pe,152,0x20b)
  struct.pack_into('<II',pe,152+112+48,4096,28)
  struct.pack_into('<IIII',pe,392+8,512,4096,512,512)
  struct.pack_into('<I',pe,512+12,2);struct.pack_into('<I',pe,512+16,24)
  struct.pack_into('<I',pe,512+24,600);pe[600:604]=b'RSDS';pe[604:620]=guid
  struct.pack_into('<I',pe,620,7);self.dll.write_bytes(pe)
  pdb=bytearray(2048);pdb[:32]=b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0'
  struct.pack_into('<6I',pdb,32,512,0,4,16,0,1)
  struct.pack_into('<I',pdb,512,2)
  struct.pack_into('<4I',pdb,1024,2,0,28,3)
  struct.pack_into('<I',pdb,1536+8,7);pdb[1536+12:1536+28]=guid
  self.pdb.write_bytes(pdb)
 def tearDown(self):self.tmp.cleanup()
 def test_matching_identity(self):self.assertTrue(symbols.verify(self.dll,self.pdb)['matching_symbols'])
 def test_wrong_age_rejected(self):
  data=bytearray(self.pdb.read_bytes());struct.pack_into('<I',data,1544,8);self.pdb.write_bytes(data)
  with self.assertRaisesRegex(ValueError,'mismatch'):symbols.verify(self.dll,self.pdb)
 def test_wrong_guid_rejected(self):
  data=bytearray(self.pdb.read_bytes());data[1548]^=1;self.pdb.write_bytes(data)
  with self.assertRaisesRegex(ValueError,'mismatch'):symbols.verify(self.dll,self.pdb)
 def test_truncated_pdb_rejected(self):
  self.pdb.write_bytes(self.pdb.read_bytes()[:1100])
  with self.assertRaisesRegex(ValueError,'Truncated'):symbols.verify(self.dll,self.pdb)
 def test_not_a_dll_rejected(self):
  self.dll.write_bytes(b'not an executable')
  with self.assertRaisesRegex(ValueError,'Not a PE'):symbols.verify(self.dll,self.pdb)

if __name__=='__main__':unittest.main(verbosity=2)
