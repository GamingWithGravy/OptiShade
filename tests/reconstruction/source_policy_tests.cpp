#define SI_NO_CONVERSION
#include "SimpleIni.h"
#include "NrSourcePolicy.h"
#include <iostream>
#include <stdexcept>
#ifdef _WIN32
#include "AtomicConfigWrite.h"
#include <fstream>
#endif
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){try{
 using namespace optishade::nr_source;
 CSimpleIniA ini;
 CHECK(ini.LoadData("[Other]\nValue=untouched\n[DlssNr]\nTaaFallback=false\nPasses=3\n")>=0);
 auto value=Read(ini);CHECK(value.migrated&&Decode(value.version,value.name)==Policy::Auto);
 Write(ini,value);CHECK(!ini.GetValue("DlssNr","TaaFallback",nullptr));
 CHECK(std::string(ini.GetValue("Other","Value"))=="untouched");CHECK(std::string(ini.GetValue("DlssNr","Passes"))=="3");
 for(const char* name:{"auto","require-native","allow-compatibility"}){
  Write(ini,{1,name,false});std::string bytes;CHECK(ini.Save(bytes)>=0);CSimpleIniA copy;CHECK(copy.LoadData(bytes.c_str())>=0);
  auto round=Read(copy);CHECK(!round.migrated&&round.version==1&&round.name==name);
 }
 CHECK(AllowsEstimated(Policy::Auto)&&AllowsEstimated(Policy::AllowCompatibility));
 CHECK(!AllowsEstimated(Policy::RequireNative)&&AllowsTemporal(Policy::RequireNative));
 CHECK(!AllowsEstimated(Policy::Unknown)&&!AllowsTemporal(Policy::Unknown));
 // Future versions, malformed/partial records and unknown values do not guess.
 for(const char* version:{"2","","-1","1junk","4294967296"}){
  ini.SetValue("DlssNr","SourcePolicySchema",version);ini.SetValue("DlssNr","SourcePolicy","auto");
  auto unknown=Read(ini);CHECK(Decode(unknown.version,unknown.name)==Policy::Unknown);
  Write(ini,unknown);CHECK(std::string(ini.GetValue("DlssNr","SourcePolicySchema"))==version);
 }
 ini.SetValue("DlssNr","SourcePolicySchema","1");ini.SetValue("DlssNr","SourcePolicy","new-policy");
 CHECK(Decode(Read(ini).version,Read(ini).name)==Policy::Unknown);
 // Same case-insensitive key in repeated sections resolves to the last entry,
 // and saving writes one canonical key while preserving unrelated settings.
 CSimpleIniA duplicate;CHECK(duplicate.LoadData("[DlssNr]\nSourcePolicySchema=1\nSourcePolicy=require-native\n[dlssnr]\nsourcepolicy=auto\n[Other]\nProfile=game-a\n")>=0);
 CHECK(Read(duplicate).name=="auto");Write(duplicate,Read(duplicate));
 CHECK(std::string(duplicate.GetValue("Other","Profile"))=="game-a");
 CSimpleIniA independent;independent.LoadData("[DlssNr]\nSourcePolicySchema=1\nSourcePolicy=require-native\n");
 CHECK(Read(independent).name=="require-native"&&Read(duplicate).name=="auto");
#ifdef _WIN32
 auto dir=std::filesystem::temp_directory_path()/("optishade-source-policy-"+std::to_string(GetCurrentProcessId()));
 CHECK(std::filesystem::create_directory(dir));auto file=dir/"OptiScaler.ini";
 const std::string original="[DlssNr]\nTaaFallback=false\n[Other]\nKeep=original\n";
 CHECK(optishade::AtomicConfigWrite(file,original));
 CHECK(optishade::AtomicConfigWrite(file,"[DlssNr]\nSourcePolicySchema=1\nSourcePolicy=auto\n",true));
 unsigned backups=0;for(const auto& entry:std::filesystem::directory_iterator(dir))if(entry.path().extension()==L".bak"){
  std::ifstream stream(entry.path(),std::ios::binary);std::string bytes((std::istreambuf_iterator<char>(stream)),{});CHECK(bytes==original);++backups;
 }
 CHECK(backups==1);CHECK(SetFileAttributesW(file.c_str(),FILE_ATTRIBUTE_READONLY));
 CHECK(!optishade::AtomicConfigWrite(file,"should not replace",true));
 CHECK(SetFileAttributesW(file.c_str(),FILE_ATTRIBUTE_NORMAL));std::filesystem::remove_all(dir);
#endif
 std::cout<<"Source-policy v1 migration, roundtrip, strict/compatibility admission, unknown schemas, duplicate keys, per-game isolation and recoverable atomic save passed\n";
}catch(const std::exception& e){std::cerr<<e.what()<<'\n';return 1;}}
