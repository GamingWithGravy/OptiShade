"""Generate version/channel consumers from shared/build-version.json.

Common applies --channel only inside its disposable workspace. --check never
rewrites source. Narrow field matches deliberately reject an unknown layout.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def render_outputs(root, channel=None):
    root = Path(root).resolve()
    definition_path = root / 'shared/build-version.json'
    definition = json.loads(definition_path.read_text(encoding='utf-8-sig'))
    if (definition.get('schema') != 1 or
            not re.fullmatch(r'(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)', str(definition.get('version', ''))) or
            type(definition.get('betaRevision')) is not int or not 1 <= definition['betaRevision'] <= 65535 or
            definition.get('channel') not in ('stable', 'beta')):
        raise ValueError('Invalid shared/build-version.json')
    definition = dict(definition, channel=channel or definition['channel'])
    if definition['channel'] not in ('stable', 'beta'):
        raise ValueError('Unknown build channel')
    major, minor, patch = map(int, definition['version'].split('.'))
    if any(part > 65535 for part in (major, minor, patch)):
        raise ValueError('Version exceeds Windows resource field capacity')
    channel = definition['channel']
    revision = definition['betaRevision'] if channel == 'beta' else 0
    version = definition['version'] + (f'-beta.{revision}' if channel == 'beta' else '')
    outputs = {}

    def edit(relative, replacements):
        path = root / relative
        before = path.read_bytes()
        text = before.decode('utf-8-sig')
        for pattern, replacement in replacements:
            text, count = re.subn(pattern, lambda match: replacement(match), text, flags=re.MULTILINE)
            if count != 1:
                raise ValueError(f'Version consumer changed; expected one field in {relative}: {pattern} (found {count})')
        outputs[path] = (b'\xef\xbb\xbf' if before.startswith(b'\xef\xbb\xbf') else b'') + text.encode('utf-8')

    edit('package.ps1', [(r"\$buildVersion='[^']+';\$buildChannel='(?:stable|beta)'",
                          lambda _: f"$buildVersion='{version}';$buildChannel='{channel}'")])
    edit('installer/ownership.ps1', [(r"(function GetBundledOptiShadeVersion\s*\{\s*)'[^']+'(\s*\})",
                                      lambda m: m[1] + f"'P{version}'" + m[2])])
    edit('installer/updates.ps1', [
        (r"(function GetOptiShadeUpdate\(\[string\]\$Current=)'[^']+'", lambda m: m[1] + f"'{version}'"),
        (r"(function GetOptiShadePreviousReleases\(\[string\]\$Current=)'[^']+'", lambda m: m[1] + f"'{version}'"),
        (r"(function ShowOptiShadeRevert\(\$Owner,\[string\]\$Current=)'[^']+'", lambda m: m[1] + f"'{version}'")])
    edit('installer/anti-cheat.ps1', [(r"(WarningVersion=1;WarningHash=[^\r\n]+;Operation=\$Operation;Build=)'[^']+'",
                                      lambda m: m[1] + f"'{version}'")])
    edit('installer/manager.ps1', [(r"(InitializeOptiShadeUpdateChannel -InstalledChannel )(?:stable|beta)\b",
                                    lambda m: m[1] + channel)])
    edit('installer/sm86-mfg.ps1', [(r"(function GetOptiShadeMfgPolicyChannel \{[\s\S]*?\n[ \t]*return )'(?:stable|beta)'",
                                     lambda m: m[1] + f"'{channel}'")])
    edit('installer/manager.xaml', [
        (r'Title="OptiShade [^"]+"', lambda _: f'Title="OptiShade {version} / {channel.title()} candidate"'),
        (r'Text="[^"]*"( FontSize="14" x:Name="HeaderVersion")', lambda m: f'Text="{version}"' + m[1])])
    macros = {'MAJOR': major, 'MINOR': minor, 'PATCH': patch, 'REVISION': revision}
    replacements = [(rf'(#define OPTISHADE_VERSION_{name} )\d+', lambda m, value=value: m[1] + str(value))
                    for name, value in macros.items()]
    replacements += [
        (r'(#define OPTISHADE_VERSION_TEXT )"[^"]+"', lambda m: m[1] + f'"{version}"'),
        (r'(#define OPTISHADE_VERSION_DISPLAY )"[^"]+"', lambda m: m[1] + f'"{definition["version"]} {channel}"'),
        (r'(#define OPTISHADE_BUILD_CHANNEL )"(?:stable|beta)"', lambda m: m[1] + f'"{channel}"')]
    edit('shared/OptiShadeVersion.h', replacements)
    def encode_json_consumer(path, value):
        before = path.read_bytes()
        rendered = json.dumps(value, indent=2) + '\n'
        if b'\r\n' in before:
            rendered = rendered.replace('\n', '\r\n')
        prefix = b'\xef\xbb\xbf' if before.startswith(b'\xef\xbb\xbf') else b''
        outputs[path] = prefix + rendered.encode('utf-8')

    resources_path = root / 'installer/versioninfo.json'
    resources = json.loads(resources_path.read_text(encoding='utf-8-sig'))
    for name in ('FileVersion', 'ProductVersion'):
        fields = resources['FixedFileInfo'][name]
        for key, value in zip(('Major', 'Minor', 'Patch', 'Build'), (major, minor, patch, revision)):
            if key not in fields:
                raise ValueError('Incomplete Windows version resource: ' + name + '.' + key)
            fields[key] = value
        resources['StringFileInfo'][name] = version
    encode_json_consumer(resources_path, resources)
    encode_json_consumer(definition_path, definition)
    return outputs


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--channel', choices=('stable', 'beta'))
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args(argv)
    try:
        outputs = render_outputs(args.root, args.channel)
        changes = []
        for path, content in outputs.items():
            before = path.read_bytes()
            if before != content:
                changes.append({'Path': str(path.relative_to(args.root.resolve())).replace('\\', '/'),
                                'Before': hashlib.sha256(before).hexdigest(), 'After': hashlib.sha256(content).hexdigest()})
        if args.check and changes:
            raise ValueError('Stale channel/version consumers: ' + ', '.join(change['Path'] for change in changes))
        if not args.check:
            for path, content in outputs.items():
                if path.read_bytes() != content:
                    path.write_bytes(content)
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(changes, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'channel_version': 'verified' if args.check else 'generated', 'changed_files': len(changes)}))
        return 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print('Channel/version validation failed: ' + str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
