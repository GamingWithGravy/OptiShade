"""One reviewed provider policy -> packaged installer data and native constants."""
import argparse, json, re
from pathlib import Path
root=Path(__file__).resolve().parents[1]
p=json.loads((root/'shared/provider-policy.json').read_text())
if p.get('schema')!=1 or set(p.get('channels',{}))!={'stable','beta'}:
 raise SystemExit('Invalid provider policy schema/channels')
lines=['// Generated from shared/provider-policy.json; do not edit.','#pragma once','#include <string_view>','namespace optishade::policy {','inline constexpr unsigned Version=1;','inline const char* Select(std::string_view channel,unsigned family,bool sourceReceipt,bool legacyReceipt,bool supportedGame,bool ambiguous,bool sourceAvailable,bool legacyAvailable,bool sm86Available=true,bool sm86Receipt=false){', 'if(!supportedGame)return "unsupported_game";','if(ambiguous)return "ambiguous_adapter";','if((sourceReceipt&&legacyReceipt)||(sm86Receipt&&(sourceReceipt||legacyReceipt)))return "conflicting_receipts";']
sm86_families='||'.join('family=='+str(n) for n in p['providers']['sm86']['families'])
lines+=['if(sm86Receipt)return ('+sm86_families+')?(sm86Available?"sm86":"payload_missing"):"receipt_adapter_mismatch";']
lines+=['if(legacyReceipt&&channel=="beta"&&family==40)return sourceAvailable?"source":"payload_missing";']
source_families='||'.join('family=='+str(n) for n in p['providers']['source']['families'])
lines+=['if(sourceReceipt){if(!('+source_families+'))return "receipt_adapter_mismatch";']
for channel,rules in p['channels'].items():
 for family,provider in rules.items():
  if provider=='sm86':lines+=['if(channel=="'+channel+'"&&family=='+family+')return sm86Available?"sm86":"payload_missing";']
lines+=['return sourceAvailable?"source":"payload_missing";}']
legacy_families='||'.join('family=='+str(n) for n in p['providers']['legacy']['families'])
lines+=['if(legacyReceipt)return ('+legacy_families+')?(legacyAvailable?"legacy":"payload_missing"):"receipt_adapter_mismatch";']
for channel,rules in p['channels'].items():
 lines+=['if(channel=="'+channel+'"){']
 for family,provider in rules.items():
  result='"'+provider+'"' if provider in ('none','native') else '('+provider+'Available?"'+provider+'":"payload_missing")'
  lines+=['if(family=='+family+')return '+result+';']
 lines+=['return "none";}']
lines+=['return "unsupported_channel";}', 'inline bool AllowsSourceFamily(unsigned family){return '+ '||'.join('family=='+str(n) for n in p['providers']['source']['families'])+';}', '}']
outputs={root/'shared/ProviderPolicy.generated.h':'\n'.join(lines)+'\n',root/'installer/provider-policy.json':json.dumps(p,indent=2)+'\n'}
outputs[root.parent/'Stable/installer/provider-policy.json']=outputs[root/'installer/provider-policy.json']
outputs[root.parent/'Stable/installer/provider-policy.ps1']=(root/'installer/provider-policy.ps1').read_text(encoding='utf-8-sig')
catalog=json.loads((root/'shared/neural-model-policy.json').read_text(encoding='utf-8'))
if catalog.get('schema')!=1 or not isinstance(catalog.get('models'),list) or not catalog['models']:
 raise SystemExit('Invalid neural model policy schema/models')
seen_ids=set();seen_hashes=set()
for model in catalog['models']:
 if set(model)!={'Id','Variant','Families','Family','ModelHash','Url','ArchiveHash','Entry','Signed'}:
  raise SystemExit('Invalid neural model policy fields')
 if not all(isinstance(model[key],str) for key in ('Id','Variant','Family','ModelHash','Url','ArchiveHash','Entry')):
  raise SystemExit('Invalid neural model policy text')
 if not re.fullmatch(r'[a-z0-9-]+',model['Id']) or model['Id'] in seen_ids:
  raise SystemExit('Invalid/duplicate neural model identity')
 if not re.fullmatch(r'[0-9A-F]{64}',model['ModelHash']) or model['ModelHash'] in seen_hashes:
  raise SystemExit('Invalid/duplicate neural model hash')
 if model['Variant'] not in ('auto','compat-3109','official-3109','v7-3109') or not isinstance(model['Signed'],bool):
  raise SystemExit('Invalid neural model variant/signature policy')
 families=model['Families']
 if not isinstance(families,list) or not families or any(type(f) is not int or f not in (20,30,40,50) for f in families) or len(set(families))!=len(families):
  raise SystemExit('Invalid neural model families')
 if bool(model['Url'])!=bool(model['ArchiveHash']) or (model['Url'] and (not model['Url'].startswith('https://github.com/') or not re.fullmatch(r'[0-9A-F]{64}',model['ArchiveHash']))):
  raise SystemExit('Invalid neural model download pin')
 if not model['Entry'] or '\\' in model['Entry'] or model['Entry'].startswith('/') or '..' in model['Entry'].split('/'):
  raise SystemExit('Invalid neural model archive entry')
 seen_ids.add(model['Id']);seen_hashes.add(model['ModelHash'])
neural=['// Generated from shared/neural-model-policy.json; do not edit.','#pragma once','#include <string_view>',
 'namespace optishade::neural_policy {',
 'struct Model { std::string_view id; std::string_view variant; std::string_view sha256; unsigned familyMask; };',
 'inline constexpr unsigned FamilyBit(unsigned family) { return family == 20 ? 1u : family == 30 ? 2u : family == 40 ? 4u : family == 50 ? 8u : 0u; }',
 'inline constexpr Model Models[] = {']
for model in catalog['models']:
 mask=sum({20:1,30:2,40:4,50:8}[f] for f in model['Families'])
 neural.append('    {'+', '.join(json.dumps(model[k]) for k in ('Id','Variant','ModelHash'))+', '+str(mask)+'u},')
neural+=['};',
 'inline constexpr bool AllowsFamily(const Model& model, unsigned family) { return (model.familyMask & FamilyBit(family)) != 0; }',
 'inline const Model* FindByHash(std::string_view hash) {',
 '    if (hash.size() != 64) return nullptr;',
 '    for (const auto& model : Models) {',
 '        bool match = true;',
 '        for (unsigned i = 0; i < 64; ++i) {',
 "            char ch = hash[i]; if (ch >= 'a' && ch <= 'f') ch = char(ch - 'a' + 'A');",
 '            if (ch != model.sha256[i]) { match = false; break; }',
 '        }',
 '        if (match) return &model;',
 '    }',
 '    return nullptr;',
 '}',
 '} // namespace optishade::neural_policy']
outputs[root/'shared/NeuralModelPolicy.generated.h']='\n'.join(neural)+'\n'
outputs[root/'installer/neural-model-policy.json']=json.dumps(catalog,indent=2)+'\n'
outputs[root.parent/'Stable/installer/neural-model-policy.json']=outputs[root/'installer/neural-model-policy.json']
for name in ('gpu-identity.ps1','GpuIdentityClient.cs'):
 outputs[root.parent/'Stable/installer'/name]=(root/'installer'/name).read_text(encoding='utf-8-sig')
# Ranking has one shared implementation. Preserve exact canonical bytes in both
# packaging consumers, including its encoding and qualification policy identity.
for name in ('qualified-plan-ranking.ps1','qualification-policy.json'):
 data=(root/'shared'/name).read_bytes()
 outputs[root/'installer'/name]=data
 outputs[root.parent/'Stable/installer'/name]=data
parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
for path,data in outputs.items():
 if args.check:
  actual=(path.read_bytes() if isinstance(data,bytes) else path.read_text(encoding='utf-8-sig')) if path.exists() else None
  # These shared PowerShell/JSON policy inputs are copied byte-for-byte into
  # installer trees. Git's core.autocrlf can materialize the canonical file as
  # LF and the generated Windows installer copy as CRLF (or vice versa).
  # Treat that transport-only newline conversion as current, while preserving
  # strict checks for every other byte and every semantic edit.
  if isinstance(actual,bytes) and isinstance(data,bytes):
   actual=actual.replace(b'\r\n',b'\n')
   data=data.replace(b'\r\n',b'\n')
  if actual!=data:raise SystemExit('Stale provider policy: '+str(path))
 else:
  path.parent.mkdir(parents=True,exist_ok=True)
  if isinstance(data,bytes):path.write_bytes(data)
  else:path.write_text(data,encoding='utf-8-sig' if path.suffix=='.ps1' else 'utf-8',newline='\n')
