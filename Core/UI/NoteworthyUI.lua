local LA = select(2, ...)

function btnNWIClose_OnClick()
    LA.Debug.Log("Closing NW-UI")
    NoteworthyUI:Hide()
end

function NoteworthyUI_OnLoad()
    if not NoteworthyUI.SetBackdrop and BackdropTemplateMixin then
        Mixin(NoteworthyUI, BackdropTemplateMixin)
    end
end
