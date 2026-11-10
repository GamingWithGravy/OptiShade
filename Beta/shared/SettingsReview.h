// OptiShade additions, GPL-3.0-or-later.
#pragma once
#include <functional>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <type_traits>
#include <vector>

namespace optishade::editing {
struct Change { std::string label,before,after; bool conflict=false; };
template<class T,class=void> struct OptionalLike:std::false_type{};
template<class T> struct OptionalLike<T,std::void_t<decltype(std::declval<T>().has_value()),decltype(std::declval<T>().value())>>:std::true_type{};
template<class T> std::string Text(const T& value){
    if constexpr(OptionalLike<T>::value)return value.has_value()?Text(value.value()):"Inherited/default";
    else if constexpr(std::is_same_v<T,bool>)return value?"On":"Off";
    else if constexpr(std::is_enum_v<T>)return std::to_string(static_cast<int>(value));
    else {std::ostringstream out;out<<value;return out.str();}
}
template<class T> std::string Text(const std::optional<T>& value){return value?Text(*value):"Inherited/default";}
template<class T> bool Equal(const T& a,const T& b){
    if constexpr(OptionalLike<T>::value)return a.has_value()==b.has_value()&&(!a.has_value()||a.value()==b.value());
    else return a==b;
}
// UI-local draft only. Reads and commits use the existing setting owner; no file or renderer store.
class Review {
    struct Field {
        std::string label;
        virtual ~Field()=default;
        virtual void Sync()=0;
        virtual bool Dirty()const=0;
        virtual bool Conflict()const=0;
        virtual Change Describe()const=0;
        virtual void Discard()=0;
        virtual bool Commit()=0;
        virtual bool Preview()=0;
        virtual bool CanUndo()const=0;
        virtual bool HasUndo()const=0;
        virtual void StageUndo()=0;
        virtual void ForgetUndo()=0;
    };
    template<class T> struct Bound final:Field {
        std::function<T()> read;std::function<void(const T&)> write;
        T& draft;T base;std::optional<T> prior,applied,previewed;
        Bound(std::string name,T& d,std::function<T()> r,std::function<void(const T&)> w):read(r),write(w),draft(d),base(r()){this->label=std::move(name);draft=base;}
        void Sync()override{if(!Dirty()&&!previewed)draft=base=read();}
        bool Dirty()const override{return !Equal(draft,base);}
        bool Conflict()const override{return (Dirty()||previewed.has_value())&&!Equal(read(),previewed?*previewed:base);}
        Change Describe()const override{return {this->label,Text(base),Text(draft),Conflict()};}
        void Discard()override{
            if(previewed&&Equal(read(),*previewed))write(base);
            previewed.reset();draft=base=read();
        }
        bool Preview()override{
            if(!Dirty()&&!previewed)return true;
            if(Conflict())return false;
            if(Equal(read(),draft))return true;
            write(draft);const T accepted=read();
            if(!Equal(accepted,draft))return false;
            previewed=accepted;if(Equal(accepted,base))previewed.reset();return true;
        }
        bool Commit()override{
            if(!Dirty())return true;
            if(Conflict())return false;
            const T before=base,wanted=draft;if(!Equal(read(),wanted))write(wanted);
            const T accepted=read();
            if(!Equal(accepted,wanted))return false;
            prior=before;applied=accepted;draft=base=accepted;previewed.reset();return true;
        }
        bool HasUndo()const override{return prior.has_value();}
        bool CanUndo()const override{return prior&&applied&&!Dirty()&&Equal(read(),*applied);}
        void StageUndo()override{if(CanUndo())draft=*prior;}
        void ForgetUndo()override{prior.reset();applied.reset();}
    };
    std::vector<std::unique_ptr<Field>> fields;
public:
    template<class T,class Read,class Write> void Bind(std::string name,T& draft,Read read,Write write){fields.push_back(std::make_unique<Bound<T>>(std::move(name),draft,std::function<T()>(read),std::function<void(const T&)>(write)));}
    void Sync(){for(auto& f:fields)f->Sync();}
    std::vector<Change> Changes()const{std::vector<Change> result;for(auto& f:fields)if(f->Dirty())result.push_back(f->Describe());return result;}
    bool Dirty()const{for(auto& f:fields)if(f->Dirty())return true;return false;}
    bool Conflict()const{for(auto& f:fields)if(f->Conflict())return true;return false;}
    void Discard(){for(auto& f:fields)f->Discard();}
    void RefreshField(const std::string& label){for(auto& f:fields)if(f->label==label)f->Discard();}
    bool Preview(){if(Conflict())return false;bool accepted=true;for(auto& f:fields)accepted=f->Preview()&&accepted;return accepted;}
    bool Apply(){
        if(Conflict())return false; // Preflight all deltas; never overwrite an external edit.
        if(!Dirty())return true;
        for(auto& f:fields)f->ForgetUndo();
        bool accepted=true;for(auto& f:fields)if(!f->Commit())accepted=false;
        return accepted; // Configuration acknowledgement only, never output confirmation.
    }
    bool CanUndo()const{bool any=false;for(auto& f:fields)if(f->HasUndo()){any=true;if(!f->CanUndo())return false;}return any;}
    bool StageUndo(){if(!CanUndo())return false;for(auto& f:fields)f->StageUndo();return true;}
};
}
