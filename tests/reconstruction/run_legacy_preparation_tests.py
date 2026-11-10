"""Compile exact legacy command adapters with OS-independent observation seams."""
import argparse
from pathlib import Path
import subprocess
import tempfile

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--root',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--compiler',default='g++')
    args=parser.parse_args()
    args.root=args.root.resolve()
    source=(args.root/'Beta/legacy-nr/upstream/src/feed_control.h').read_text()
    for marker in ('static automatic::ApplyResult Apply(', 'static Json ConfigureAuto(', 'static Json ConfigureNr(', '\n}\nstatic void StartLegacyControl()'):
        if source.count(marker)!=1:
            raise SystemExit('Legacy command extraction boundary changed: '+marker)
    apply=source[source.index('static automatic::ApplyResult Apply('):source.index('static Json ConfigureAuto(')]
    configure=source[source.index('static Json ConfigureAuto('):source.index('\n}\nstatic void StartLegacyControl()')]
    fixture=(args.root/'tests/reconstruction/legacy_preparation_tests.cpp').read_text()
    if fixture.count('// PRODUCTION_CONTROL_FUNCTIONS')!=1:
        raise SystemExit('Legacy command fixture insertion point changed')
    generated=fixture.replace('// PRODUCTION_CONTROL_FUNCTIONS',apply+configure)
    with tempfile.TemporaryDirectory(prefix='optishade-legacy-prepare-') as temporary:
        temp=Path(temporary);cpp=temp/'legacy_preparation.cpp';cpp.write_text(generated)
        binary=temp/('legacy_preparation.exe' if Path(args.compiler).name.lower() in ('cl','cl.exe') else 'legacy_preparation')
        includes=[args.root/'Beta/shared',args.root/'Beta/legacy-nr/upstream/src',args.root/'Beta/optiscaler/external/nlohmann']
        if Path(args.compiler).name.lower() in ('cl','cl.exe'):
            command=[args.compiler,'/nologo','/EHsc','/std:c++20',*['/I'+str(p) for p in includes],str(cpp),'/Fe:'+str(binary)]
        else:
            command=[args.compiler,'-std=c++20','-O0','-Wall','-Wextra','-pthread',*['-I'+str(p) for p in includes],str(cpp),'-o',str(binary)]
        subprocess.run(command,cwd=temp,check=True)
        subprocess.run([str(binary)],cwd=temp,check=True)

if __name__=='__main__':
    main()
