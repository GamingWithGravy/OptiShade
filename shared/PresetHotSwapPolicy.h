#pragma once
namespace optishade::hotswap {
// A release must belong to a fresh press in the focused game, not a held key
// inherited from key capture, a modifier chord, or a focus change.
struct PressGate {
 bool armed=false;
 bool update(bool pressed,bool released,bool allowed){
  if(!allowed){armed=false;return false;}
  if(pressed)armed=true;
  if(released&&armed){armed=false;return true;}
  return false;
 }
};
inline bool may_switch(bool connected,bool loading,bool dirty){return connected&&!loading&&!dirty;}
}
