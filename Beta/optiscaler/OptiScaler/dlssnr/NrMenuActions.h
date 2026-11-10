// OptiShade additions, GPL-3.0-or-later.
#pragma once
namespace DlssNr {
bool MenuHasChanges();
bool MenuCanUndo();
void DiscardMenuChanges();
bool StageMenuUndo();
void DrawMenuReview(bool available);
bool SaveMenuChanges(bool available);
}
