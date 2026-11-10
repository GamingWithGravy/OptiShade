#include "SettingsReview.h"
#include <iostream>
#include <stdexcept>
#define CHECK(x) do{if(!(x))throw std::runtime_error(#x);}while(0)
int main(){try{
 using namespace optishade::editing;
 int liveA=1,liveB=2,draftA=0,draftB=0,writes=0;
 Review r;r.Bind<int>("Passes",draftA,[&]{return liveA;},[&](int v){liveA=v;++writes;});r.Bind<int>("Strength",draftB,[&]{return liveB;},[&](int v){liveB=v;++writes;});
 r.Sync();CHECK(writes==0&&draftA==1&&draftB==2);draftA=3;r.Sync();CHECK(draftA==3&&writes==0);CHECK(r.Changes().size()==1);CHECK(r.Changes()[0].before=="1"&&r.Changes()[0].after=="3");CHECK(r.Apply()&&liveA==3&&writes==1);
 draftB=9;CHECK(r.StageUndo());CHECK(draftA==1&&draftB==9);CHECK(r.Apply()&&liveA==1&&liveB==9);
 liveA=4;CHECK(!r.CanUndo());draftB=5;liveB=7;CHECK(r.Conflict());auto count=writes;CHECK(!r.Apply()&&writes==count&&liveA==4&&liveB==7);r.Discard();CHECK(!r.Dirty()&&draftB==7);
 draftA=8;liveB=10;r.Sync();CHECK(draftA==8&&draftB==10);CHECK(r.Apply()&&liveB==10);CHECK(r.StageUndo());CHECK(draftA==4);r.Discard();CHECK(draftA==8);
 // Immediate safety-off acknowledges only its own field and preserves a tuning draft.
 bool on=true,onDraft=true;int tune=1,tuneDraft=1;Review safety;
 safety.Bind<bool>("Enable",onDraft,[&]{return on;},[&](bool v){on=v;});
 safety.Bind<int>("Tuning",tuneDraft,[&]{return tune;},[&](int v){tune=v;});
 tuneDraft=3;on=false;safety.RefreshField("Enable");CHECK(!onDraft&&tuneDraft==3&&safety.Changes().size()==1&&!safety.Conflict());
 int refused=0,choice=0;Review failed;failed.Bind<int>("Rejected",choice,[&]{return refused;},[](int){});choice=1;CHECK(!failed.Apply()&&failed.Dirty());CHECK(!failed.CanUndo());
 std::optional<float> inherited,draft;Review opts;opts.Bind<std::optional<float>>("Inherited",draft,[&]{return inherited;},[&](auto v){inherited=v;});draft=.5f;CHECK(opts.Changes()[0].before=="Inherited/default");CHECK(opts.Apply());CHECK(opts.StageUndo());CHECK(!draft);CHECK(opts.Apply()&&!inherited);
 // Preview never persists files; it uses only the supplied live owner. Save retains the original undo point.
 int live=10,previewDraft=0,previewWrites=0;Review preview;
 preview.Bind<int>("Live tuning",previewDraft,[&]{return live;},[&](int v){live=v;++previewWrites;});
 previewDraft=20;CHECK(preview.Preview()&&live==20&&preview.Dirty());preview.Sync();CHECK(previewDraft==20);
 previewDraft=30;CHECK(preview.Preview()&&live==30);preview.Discard();CHECK(live==10&&!preview.Dirty());
 previewDraft=40;CHECK(preview.Preview());previewDraft=10;CHECK(preview.Preview()&&live==10&&!preview.Dirty());
 previewDraft=50;CHECK(preview.Preview()&&preview.Apply()&&live==50);CHECK(preview.StageUndo()&&previewDraft==10);CHECK(preview.Apply()&&live==10);
 previewDraft=60;CHECK(preview.Preview());live=70;CHECK(preview.Conflict()&&!preview.Preview()&&!preview.Apply());preview.Discard();CHECK(live==70&&previewDraft==70);
 live=80;auto unchanged=previewWrites;CHECK(preview.Preview()&&previewWrites==unchanged&&live==80);preview.Sync();CHECK(previewDraft==80);
 std::cout<<"Review/apply conflict, rejection, inheritance and scoped undo tests passed\n";
}catch(const std::exception&e){std::cerr<<e.what();return 1;}}
