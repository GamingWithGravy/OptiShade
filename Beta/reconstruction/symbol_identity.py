#!/usr/bin/env python3
"""Read PE RSDS and PDB stream-1 identities; never load the inspected DLL."""
from pathlib import Path
import argparse
import json
import struct
import uuid

def u32(data,offset): return struct.unpack_from('<I',data,offset)[0]
def span(data,offset,length):
    if offset<0 or length<0 or offset+length>len(data): raise ValueError('Truncated identity data')
    return data[offset:offset+length]
def identity(guid,age): return {'guid':str(uuid.UUID(bytes_le=guid)),'age':age}
def pe_identity(path):
    data=path.read_bytes()
    if span(data,0,2)!=b'MZ': raise ValueError('Not a PE file')
    pe=u32(data,0x3c)
    if span(data,pe,4)!=b'PE\0\0': raise ValueError('Invalid PE signature')
    sections=struct.unpack_from('<H',data,pe+6)[0]
    optional=pe+24;size=struct.unpack_from('<H',data,pe+20)[0]
    magic=struct.unpack_from('<H',data,optional)[0]
    if magic not in (0x10b,0x20b): raise ValueError('Unsupported PE optional header')
    directory=optional+(112 if magic==0x20b else 96)+6*8
    rva,length=struct.unpack_from('<II',data,directory)
    if not rva or length%28: raise ValueError('Missing or invalid PE debug directory')
    offset=None
    for n in range(sections):
        sec=optional+size+n*40
        virtual_size,base,raw_size,raw=struct.unpack_from('<IIII',data,sec+8)
        if base<=rva<base+max(virtual_size,raw_size): offset=raw+rva-base;break
    if offset is None: raise ValueError('Unmapped debug directory')
    found=[]
    for n in range(length//28):
        entry=span(data,offset+n*28,28)
        if u32(entry,12)!=2: continue
        cv=span(data,u32(entry,24),u32(entry,16))
        if cv[:4]==b'RSDS' and len(cv)>=24: found.append(identity(cv[4:20],u32(cv,20)))
    if len(found)!=1: raise ValueError('Expected exactly one RSDS identity')
    return found[0]
def pdb_identity(path):
    # Random-access reads avoid loading hundreds of megabytes of symbols.
    with path.open('rb') as stream:
        header=stream.read(56)
        if header[:32]!=b'Microsoft C/C++ MSF 7.00\r\n\x1aDS\0\0\0': raise ValueError('Not an MSF7 PDB')
        block,_,blocks,size,_,map_block=struct.unpack_from('<6I',header,32)
        if block not in (512,1024,2048,4096,8192,16384,32768) or size>64*1024*1024:
            raise ValueError('Unsupported or excessive PDB directory')
        def read(offset,length):
            stream.seek(offset);data=stream.read(length)
            if len(data)!=length: raise ValueError('Truncated PDB')
            return data
        count=(size+block-1)//block
        indexes=read(map_block*block,count*4)
        directory=b''.join(read(u32(indexes,n*4)*block,block) for n in range(count))[:size]
        streams=u32(directory,0)
        if streams<2 or streams>1000000: raise ValueError('Invalid PDB stream directory')
        sizes=struct.unpack_from('<'+str(streams)+'I',directory,4)
        pos=4+4*streams
        for n,size in enumerate(sizes[:2]):
            count=0 if size==0xffffffff else (size+block-1)//block
            if n==1:
                if size<28 or count==0: raise ValueError('Missing PDB identity stream')
                info=read(u32(directory,pos)*block,28)
                return identity(info[12:28],u32(info,8))
            pos+=count*4
def verify(binary,symbols):
    pe=pe_identity(binary);pdb=pdb_identity(symbols)
    if pe!=pdb: raise ValueError(f'DLL/PDB identity mismatch: {pe} != {pdb}')
    return {'rsds':pe,'matching_symbols':True,'scope':'Binary/symbol identity only; no runtime test'}
if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary',type=Path);parser.add_argument('symbols',type=Path)
    args=parser.parse_args();print(json.dumps(verify(args.binary,args.symbols),indent=2))
