#include "pch.h"

#include <Config.h>
#include <Logger.h>
#include <resource.h>
#include <Util.h>

#include "menu_common.h"
#include "menu_dx_base.h"
#include "input/input_system.h"

#include <imgui/imgui_impl_win32.h>

static thread_local std::uint64_t menuDrawOwner = 0;

bool MenuDxBase::RenderMenu()
{
    if (Config::Instance()->OverlayMenu.value_or_default())
        return false;

    menuDrawOwner = OptiInput::BeginMenuDrawOwner();
    if (MenuCommon::RenderMenu())
    {
        ImGui::Render();
        const ImDrawData* drawData = ImGui::GetDrawData();
        if (drawData != nullptr && drawData->CmdListsCount > 0 && drawData->TotalVtxCount > 0)
            return true;

        ReportMenuDrawResult(false, "DirectX menu produced no draw vertices");
        return false;
    }

    ReportMenuDrawResult(false, "DirectX menu frame was not rendered");
    return false;
}

void MenuDxBase::ReportMenuDrawResult(bool submitted, const char* reason)
{
    if (menuDrawOwner == 0)
        return;
    OptiInput::ReportMenuDrawSubmission(submitted, menuDrawOwner, reason);
    menuDrawOwner = 0;
}

bool MenuDxBase::IsHandleDifferent()
{
    if (Config::Instance()->OverlayMenu.value_or_default())
        return false;

    HWND frontWindow = Util::GetProcessWindow();

    if (frontWindow != nullptr && frontWindow == _handle)
        return false;

    _handle = frontWindow;

    return true;
}

void MenuDxBase::Dx11Ready() { MenuCommon::Dx11Inited(); }

void MenuDxBase::Dx12Ready() { MenuCommon::Dx12Inited(); }

MenuDxBase::MenuDxBase(HWND handle) : _handle(handle)
{
    if (Config::Instance()->OverlayMenu.value_or_default())
        return;

    MenuCommon::Init(handle, false);

    _baseInit = MenuCommon::IsInited();
}

MenuDxBase::~MenuDxBase()
{
    if (!_baseInit)
        return;

    OptiInput::SetMenuVisible(false);
    OptiInput::RequireMenuDrawSubmission(false);
    MenuCommon::Shutdown();
}

bool MenuDxBase::IsVisible() { return MenuCommon::IsVisible(); }
