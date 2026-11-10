from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[2]
installer = ROOT / "Beta/installer"
ui = (installer / "manager.xaml").read_text(encoding="utf-8")
manager = (installer / "manager.ps1").read_text(encoding="utf-8")
owner = (installer / "ownership.ps1").read_text(encoding="utf-8")
repair = (installer / "neural-download.ps1").read_text(encoding="utf-8")
update = (installer / "update-install.ps1").read_text(encoding="utf-8")
compat = (installer / "compatibility.ps1").read_text(encoding="utf-8")
menu = (ROOT / "Beta/optiscaler/OptiScaler/dlssnr/reconstruction/NRPasses.inl").read_text(encoding="utf-8")

pins = {
    "E16BCF15E16E13F527491CDF7845B2FE6521A738D8F7C9C721866A8496E1FC8E",  # NVIDIA 310.8
    "E67DEE209320CDAFE0E93E45675D7AA34323A53ACC57A72B2E40A181581C989A",  # 310.8 compatibility
    "CDFA6C1EC784867182164C7836F324F087B5C9F374D0C9FE46F54999FEABF3ED",  # OpenNR 310.9.16
    "2BC19BC09A7B89DD44F73E2AC0108FCC586E2154BDD0830F242F4F040E28789F",  # NVIDIA signed 310.9.16
    "30B6B599DBC593E5F9A8A0DDB2EDAC6F2F15AD0EAA967CD6BB0AB6BB224825C3",  # user-provided V7 pin
}
catalog = json.loads((ROOT / 'Beta/shared/neural-model-policy.json').read_text())
assert catalog['schema'] == 1 and {model['ModelHash'] for model in catalog['models']} == pins
assert json.loads((installer / 'neural-model-policy.json').read_text()) == catalog
assert 'GetOptiShadeNeuralModelByHash' in owner and 'GetOptiShadeNeuralModelByHash' in compat
assert 'GetOptiShadeNeuralModelCatalog' in repair
assert 'x:Name="NrRuntimeVariant"' in ui and all(f'Tag="{tag}"' in ui for tag in ("auto", "compat-3109", "official-3109", "v7-3109"))
assert "ImportNrRuntime $mp $model $variant" in manager
assert "Selected local NR version and owned preparation identity verified; automatic model replacement skipped." in repair
assert "NeuralRuntimeVariant" in update and "NeuralRuntimeHash" in update
assert "Select the matching NR runtime variant" in owner
assert 'ResolveOptiShadeNeuralAdapter' in owner and 'candidate.Adapter.Family -notin $model.Families' in owner
assert all(30 in model['Families'] for model in catalog['models'] if model['Id'] in ('compat-3108','compat-3109','v7-3109'))
official = next(model for model in catalog['models'] if model['Id'] == 'official-3109')
assert official['Families'] == [50] and official['Signed'] is True and official['Variant'] == 'official-3109'
assert official['Url'] == official['ArchiveHash'] == '' and official['ModelHash'] == '2BC19BC09A7B89DD44F73E2AC0108FCC586E2154BDD0830F242F4F040E28789F'
assert "official-3109" in repair and "Get-AuthenticodeSignature" in owner
assert 'unsupported_hardware' not in compat
assert 'RTX 20, 30, 40 and 50 series' in manager
assert '"Auto (runtime default; B on 310.9.16)"' in menu
assert '"Preset 1 (A / standard on 310.9.16)"' in menu
assert '"Preset 2 (B / lightweight on 310.9.16)"' in menu
print("NR version selection pins, GPU gates, repair retention and 310.9.16 A/B labels passed.")



