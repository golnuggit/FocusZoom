#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn
CoordMode "Mouse", "Screen"

InitDpiAwareness()

; =======================
; FocusZoom (AHK v2) - POC
; =======================
; - Draw a Viewport (destination box).
; - Draw Zones (source rectangles).
; - Hotkeys 1..9 jump; ←/→ cycle; Esc/0 overview; F9 setup; Ctrl+Shift+P pause.
; - Overlay is an always-on-top, click-through window.
; - GDI capture/scale (StretchBlt) for a quick POC.

; --------------- Settings ---------------
global gTransition  := 300          ; ms for zone transition animation
global gFrameMs     := 33           ; ~30 fps while live (raise to 50–66 if CPU high)
global gPaused      := false
global gPresetPath  := A_AppData "\FocusZoom\preset.ini"

; --------------- State ------------------
global gViewport := Map("x", 200, "y", 200, "w", 600, "h", 400)
global gViewportSet := false        ; true when user has set viewport
global gZones := []                 ; each: {x,y,w,h}
global gCurIdx := 0                 ; current zone index (1-based), 0 = overview
global gCurSrc := Map("x", 0, "y", 0, "w", 300, "h", 200) ; current source rect
global gAnimSrcStart := Map("x", 0, "y", 0, "w", 300, "h", 200)
global gTgtSrc := Map("x", 0, "y", 0, "w", 300, "h", 200)
global gAnimStart := 0
global gAnimEnd := 0
global gOverlay := 0                ; GUI object (viewport window)
global gOverlayHwnd := 0
global gOverlayDC := 0
global gOverlayBmp := 0
global gOverlayBits := 0
global gOverlayOldBmp := 0
global gOverlaySizeW := 0
global gOverlaySizeH := 0
global gRenderOn := false
global gTimerFn := (*) => RenderTick()

; --------------- Visual Outlines --------
global gViewportOutline := 0
global gZoneOutlines := []

OnExit(ExitCleanup)

; --------------- Tray menu --------------
A_TrayMenu.Delete()
A_TrayMenu.Add("&Setup / Show (F9)", (*) => ShowSetup())
A_TrayMenu.Add("&Pause/Resume (Ctrl+Shift+P)", (*) => TogglePause())
A_TrayMenu.Add("Save Preset", (*) => SavePreset())
A_TrayMenu.Add("Load Preset", (*) => LoadPreset())
A_TrayMenu.Add()
A_TrayMenu.Add("E&xit (Ctrl+Shift+Q)", (*) => ExitApp())

; --------------- Hotkeys ----------------
; (Use explicit lambdas so v2 never treats names as uninitialized vars.)
Hotkey("F9", (*) => ToggleSetup())
Hotkey("^+p", (*) => TogglePause())
Hotkey("^+q", (*) => ExitApp())  ; Ctrl+Shift+Q to quit

; =============== UI: Setup Window =================
global gSetup, gZonesList, gTransEdit

MakeSetupUi() {
    global gSetup, gZonesList, gTransEdit

    if IsSet(gSetup) && IsObject(gSetup) {
        try gSetup.Destroy()
    }

    gSetup := Gui("+AlwaysOnTop", "FocusZoom - Setup")
    gSetup.MarginX := 10, gSetup.MarginY := 10

    gSetup.Add("Text",, "1) Click 'Set Viewport' and drag a box where the zoom will appear.")
    gSetup.Add("Button", "w130", "Set Viewport").OnEvent("Click", (*) => SetViewport())

    gSetup.Add("Text", "y+10", "2) Click 'Add Zone' and drag rectangles over areas you want to zoom.")
    gSetup.Add("Text", "y+5", "(Zones will auto-match viewport aspect ratio)")
    btnAdd := gSetup.Add("Button", "w130", "Add Zone")
    btnAdd.OnEvent("Click", (*) => AddZone())

    gSetup.Add("Text", "y+10", "Zones (press 1..9 to jump during Live):")
    gZonesList := gSetup.Add("ListBox", "w260 h160")

    rowBtns := gSetup.Add("GroupBox", "w260 h50", "Manage")
    bDel := gSetup.Add("Button", "x+10 yp+20 w80", "Delete")
    bClr := gSetup.Add("Button", "x+5 w80", "Clear All")
    bDel.OnEvent("Click", (*) => DelSelectedZone())
    bClr.OnEvent("Click", (*) => ClearZones())

    gSetup.Add("Text", "y+10", "Transition ms:")
    gTransEdit := gSetup.Add("Edit", "w80", gTransition)

    gSetup.Add("Button", "y+10 w120", "Save Preset").OnEvent("Click", (*) => SavePreset())
    gSetup.Add("Button", "x+10 w120", "Load Preset").OnEvent("Click", (*) => LoadPreset())

    gSetup.Add("Text", "y+10", "3) Click 'Go Live' to start overlay and hotkeys.")
    gSetup.Add("Button", "w120", "Go Live").OnEvent("Click", (*) => GoLive())

    gSetup.Add("Text", "y+10", "Hotkeys: F9=Setup | Ctrl+Shift+P=Pause | Ctrl+Shift+Q=Quit")

    gSetup.OnEvent("Close", (*) => gSetup.Hide())
}

ShowSetup() {
    global
    MakeSetupUi()
    RefreshZonesList()
    UpdateVisualOutlines()
    gSetup.Show()
}

; =============== Selection helpers ================
SelectRect(prompt := "Drag to select a rectangle", aspectRatio := 0) {
    ToolTip(prompt)

    KeyWait("LButton", "D")
    MouseGetPos &sx, &sy
    screen := GetVirtualScreenRect()
    ClampPointToRect(&sx, &sy, screen)
    overlay := CreateSelectionOverlay()
    rect := {x: sx, y: sy, w: 1, h: 1}
    cancelled := false

    while GetKeyState("LButton", "P") {
        if GetKeyState("Esc", "P") {
            cancelled := true
            break
        }
        Sleep 10
        MouseGetPos &mx, &my
        ClampPointToRect(&mx, &my, screen)

        ; Calculate base rectangle from drag
        baseW := Abs(mx - sx)
        baseH := Abs(my - sy)

        ; If aspect ratio is specified, constrain the rectangle
        if (aspectRatio > 0) {
            ; Use the larger dimension and calculate the other
            if (baseW / aspectRatio > baseH) {
                ; Width is the constraining dimension
                rect.w := baseW
                rect.h := Floor(baseW / aspectRatio)
            } else {
                ; Height is the constraining dimension
                rect.h := baseH
                rect.w := Floor(baseH * aspectRatio)
            }
        } else {
            rect.w := baseW
            rect.h := baseH
        }

        rect.x := (mx < sx) ? mx : sx
        rect.y := (my < sy) ? my : sy

        if rect.w < 2
            rect.w := 2
        if rect.h < 2
            rect.h := 2
        UpdateSelectionOverlay(overlay, rect)
    }
    DestroySelectionOverlay(overlay)
    ToolTip()
    if cancelled
        return 0
    if rect.w < 2
        rect.w := 2
    if rect.h < 2
        rect.h := 2
    return rect
}

CreateSelectionOverlay(borderColor := 0xFF8800, thickness := 2) {
    bgColor := 0x010101
    selGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20")
    selGui.MarginX := 0
    selGui.MarginY := 0
    selGui.BackColor := Format("0x{:06X}", bgColor)

    opts := Format("Background0x{:06X} -Smooth", borderColor)
    top := selGui.Add("Progress", opts " x0 y0 w10 h" thickness)
    bottom := selGui.Add("Progress", opts " x0 y0 w10 h" thickness)
    left := selGui.Add("Progress", opts " x0 y0 w" thickness " h10")
    right := selGui.Add("Progress", opts " x0 y0 w" thickness " h10")
    top.Value := 100
    bottom.Value := 100
    left.Value := 100
    right.Value := 100

    selGui.Show("NA x0 y0 w1 h1")

    ApplyColorKey(selGui.Hwnd, bgColor)

    return Map(
        "gui", selGui
      , "thickness", thickness
      , "edges", Map("top", top, "bottom", bottom, "left", left, "right", right)
    )
}

UpdateSelectionOverlay(overlay, rect) {
    if !IsObject(overlay)
        return
    selGui := overlay["gui"]
    edges := overlay["edges"]
    thickness := overlay["thickness"]
    w := Max(rect.w, thickness)
    h := Max(rect.h, thickness)
    selGui.Show(Format("NA x{} y{} w{} h{}", rect.x, rect.y, w, h))
    edges["top"].Move(0, 0, w, thickness)
    edges["bottom"].Move(0, Max(0, h - thickness), w, thickness)
    edges["left"].Move(0, 0, thickness, h)
    edges["right"].Move(Max(0, w - thickness), 0, thickness, h)
}

DestroySelectionOverlay(overlay) {
    if !IsObject(overlay)
        return
    try overlay["gui"].Destroy()
}

; =============== Visual Outlines (persistent) ======
CreatePersistentOutline(rect, color := 0x00FF00, thickness := 3) {
    bgColor := 0x010101
    outlineGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 +E0x20")
    outlineGui.MarginX := 0
    outlineGui.MarginY := 0
    outlineGui.BackColor := Format("0x{:06X}", bgColor)

    opts := Format("Background0x{:06X} -Smooth", color)
    top := outlineGui.Add("Progress", opts " x0 y0 w10 h" thickness)
    bottom := outlineGui.Add("Progress", opts " x0 y0 w10 h" thickness)
    left := outlineGui.Add("Progress", opts " x0 y0 w" thickness " h10")
    right := outlineGui.Add("Progress", opts " x0 y0 w" thickness " h10")
    top.Value := 100
    bottom.Value := 100
    left.Value := 100
    right.Value := 100

    w := Max(rect["w"], thickness)
    h := Max(rect["h"], thickness)
    outlineGui.Show(Format("NA x{} y{} w{} h{}", rect["x"], rect["y"], w, h))

    ApplyColorKey(outlineGui.Hwnd, bgColor)

    ; Position the edges
    top.Move(0, 0, w, thickness)
    bottom.Move(0, Max(0, h - thickness), w, thickness)
    left.Move(0, 0, thickness, h)
    right.Move(Max(0, w - thickness), 0, thickness, h)

    return Map(
        "gui", outlineGui
      , "thickness", thickness
      , "edges", Map("top", top, "bottom", bottom, "left", left, "right", right)
    )
}

UpdateVisualOutlines() {
    global gViewport, gZones, gViewportOutline, gZoneOutlines, gRenderOn, gViewportSet

    ; Only show outlines when NOT in live mode
    if gRenderOn {
        HideVisualOutlines()
        return
    }

    ; Update viewport outline (blue) - only if user has set it
    if IsObject(gViewportOutline) {
        try gViewportOutline["gui"].Destroy()
        gViewportOutline := 0
    }
    if gViewportSet {
        gViewportOutline := CreatePersistentOutline(gViewport, 0x0000FF, 3)
    }

    ; Clear old zone outlines
    for outline in gZoneOutlines {
        try outline["gui"].Destroy()
    }
    gZoneOutlines := []

    ; Create zone outlines (green)
    for z in gZones {
        outline := CreatePersistentOutline(z, 0x00FF00, 2)
        gZoneOutlines.Push(outline)
    }
}

HideVisualOutlines() {
    global gViewportOutline, gZoneOutlines

    if IsObject(gViewportOutline) {
        try gViewportOutline["gui"].Destroy()
        gViewportOutline := 0
    }

    for outline in gZoneOutlines {
        try outline["gui"].Destroy()
    }
    gZoneOutlines := []
}

; =============== Setup actions ====================
SetViewport() {
    global gViewport, gViewportSet, gOverlayHwnd, gRenderOn, gPaused
    r := SelectRect("Drag to set the VIEWPORT (destination box)")
    if !IsObject(r)
        return
    gViewport := Map("x", r.x, "y", r.y, "w", r.w, "h", r.h)
    gViewportSet := true
    MsgBox "Viewport set to: " RectStr(gViewport)
    UpdateVisualOutlines()
    if gOverlayHwnd {
        wasRendering := gRenderOn
        if wasRendering
            StopRendering()
        EnsureOverlayResources(gViewport["w"], gViewport["h"])
        PositionOverlay()
        if wasRendering && !gPaused
            StartRendering()
    }
}

AddZone() {
    global gZones, gViewport, gViewportSet
    if !gViewportSet {
        MsgBox "Please set the viewport first before adding zones."
        return
    }
    ; Calculate viewport aspect ratio
    aspectRatio := gViewport["w"] / Max(gViewport["h"], 1)
    r := SelectRect("Drag to set a ZONE (will match viewport aspect ratio)", aspectRatio)
    if !IsObject(r)
        return
    gZones.Push(Map("x", r.x, "y", r.y, "w", r.w, "h", r.h))
    OnZonesChanged()
}

DelSelectedZone() {
    global gZones, gZonesList, gCurIdx
    idx := gZonesList.Value
    if !idx
        return
    gZones.RemoveAt(idx)
    if (gCurIdx = idx)
        gCurIdx := Min(idx, gZones.Length)
    else if (gCurIdx > idx)
        gCurIdx -= 1
    if (gCurIdx > gZones.Length)
        gCurIdx := gZones.Length
    OnZonesChanged()
}

ClearZones() {
    global gZones, gCurIdx
    gZones := []
    gCurIdx := 0
    OnZonesChanged()
}

RefreshZonesList() {
    global gZones, gZonesList, gCurIdx
    if !IsObject(gZonesList)
        return

    ; Clear existing entries safely by deleting items one by one
    loop 99 {
        try {
            gZonesList.Delete(1)
        } catch {
            break
        }
    }

    ; Add items one by one (not using spread operator)
    for idx, z in gZones {
        gZonesList.Add([Format("{:d}) {}", idx, RectStr(z))])
    }

    if (gCurIdx >= 1 && gCurIdx <= gZones.Length)
        gZonesList.Value := gCurIdx
    else
        gZonesList.Value := 0
}

OnZonesChanged() {
    global gZones, gCurIdx, gRenderOn, gPaused, gOverlay
    RefreshZonesList()
    UpdateVisualOutlines()
    if (gZones.Length = 0) {
        if gCurIdx != 0
            gCurIdx := 0
        if gRenderOn
            Overview()
        else if IsObject(gOverlay)
            gOverlay.Hide()
        ResetAnimationToCurrentZone()
        return
    }
    if (gCurIdx < 1)
        gCurIdx := 1
    else if (gCurIdx > gZones.Length)
        gCurIdx := gZones.Length
    if gRenderOn && !gPaused
        JumpToZone(gCurIdx, false)
    else if (gPaused && IsObject(gOverlay) && gOverlay.Visible)
        ResetAnimationToCurrentZone(true)
    else
        ResetAnimationToCurrentZone()
}

RectStr(r) {
    return Format("x{}, y{}, w{}, h{}", r["x"], r["y"], r["w"], r["h"])
}

; =============== Presets ==========================
EnsurePresetDir() {
    SplitPath gPresetPath,, &dir
    DirCreate dir
}
SavePreset() {
    global gViewport, gZones, gTransition, gPresetPath, gTransEdit
    EnsurePresetDir()
    SyncSettingsFromInputs()
    IniWrite gViewport["x"], gPresetPath, "Viewport", "x"
    IniWrite gViewport["y"], gPresetPath, "Viewport", "y"
    IniWrite gViewport["w"], gPresetPath, "Viewport", "w"
    IniWrite gViewport["h"], gPresetPath, "Viewport", "h"
    IniWrite gTransition, gPresetPath, "Settings", "TransitionMs"
    IniWrite gZones.Length, gPresetPath, "Settings", "ZoneCount"
    for idx, z in gZones {
        sec := "Zone" idx
        IniWrite z["x"], gPresetPath, sec, "x"
        IniWrite z["y"], gPresetPath, sec, "y"
        IniWrite z["w"], gPresetPath, sec, "w"
        IniWrite z["h"], gPresetPath, sec, "h"
    }
    MsgBox "Preset saved to:`n" gPresetPath
}

LoadPreset() {
    global gViewport, gViewportSet, gZones, gTransition, gPresetPath, gSetup, gOverlayHwnd, gRenderOn, gPaused, gTransEdit
    if !FileExist(gPresetPath) {
        MsgBox "No preset found at:`n" gPresetPath
        return
    }
    gViewport["x"] := Integer(IniRead(gPresetPath, "Viewport", "x", gViewport["x"]))
    gViewport["y"] := Integer(IniRead(gPresetPath, "Viewport", "y", gViewport["y"]))
    gViewport["w"] := Integer(IniRead(gPresetPath, "Viewport", "w", gViewport["w"]))
    gViewport["h"] := Integer(IniRead(gPresetPath, "Viewport", "h", gViewport["h"]))
    gViewportSet := true
    gTransition := Integer(IniRead(gPresetPath, "Settings", "TransitionMs", gTransition))
    if (gTransition < 0)
        gTransition := 0
    cnt := Integer(IniRead(gPresetPath, "Settings", "ZoneCount", 0))
    gZones := []
    loop cnt {
        idx := A_Index
        sec := "Zone" idx
        z := Map("x", Integer(IniRead(gPresetPath, sec, "x", 0))
               , "y", Integer(IniRead(gPresetPath, sec, "y", 0))
               , "w", Integer(IniRead(gPresetPath, sec, "w", 0))
               , "h", Integer(IniRead(gPresetPath, sec, "h", 0)))
        gZones.Push(z)
    }
    if IsSet(gSetup) && IsObject(gSetup)
        RefreshZonesList()
    if IsObject(gTransEdit)
        gTransEdit.Value := gTransition
    UpdateVisualOutlines()
    if gOverlayHwnd {
        wasRendering := gRenderOn
        if wasRendering
            StopRendering()
        EnsureOverlayResources(gViewport["w"], gViewport["h"])
        PositionOverlay()
        if wasRendering && !gPaused
            StartRendering()
    }
    MsgBox "Preset loaded."
}

; =============== Live mode ========================
ToggleSetup() {
    global gSetup
    if (IsSet(gSetup) && IsObject(gSetup) && gSetup.Visible)
        gSetup.Hide()
    else
        ShowSetup()
}

GoLive() {
    global gOverlay, gOverlayHwnd, gRenderOn, gCurIdx, gViewport, gViewportSet, gZones, gPaused, gCurSrc, gTgtSrc, gAnimSrcStart

    if !gViewportSet {
        MsgBox "Please set the viewport first by clicking 'Set Viewport' and dragging a box."
        return
    }
    if (gViewport["w"] < 10 || gViewport["h"] < 10) {
        MsgBox "Please set a valid viewport first."
        return
    }
    if (gZones.Length = 0) {
        MsgBox "Please add at least one zone."
        return
    }

    HideVisualOutlines()
    EnsureOverlayGui()
    EnsureOverlayResources(gViewport["w"], gViewport["h"])
    PositionOverlay()

    ; Initialize current source to the full viewport (overview state)
    gCurSrc := CloneRect(gViewport)
    gTgtSrc := CloneRect(gViewport)
    gAnimSrcStart := CloneRect(gViewport)

    EnableLiveHotkeys(true)
    gPaused := false
    gCurIdx := 0  ; Start in overview mode
    StartRendering()
    if IsSet(gSetup) && IsObject(gSetup)
        gSetup.Hide()
}

EnsureOverlayGui() {
    global gOverlay, gOverlayHwnd
    if IsObject(gOverlay) {
        gOverlay.Show("NA")
        gOverlayHwnd := gOverlay.Hwnd
        return
    }
    gOverlay := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x80000")
    gOverlay.MarginX := 0
    gOverlay.MarginY := 0
    gOverlay.BackColor := "000000"
    gOverlayHwnd := gOverlay.Hwnd
    gOverlay.Show("NA")
    WinSetAlwaysOnTop true, "ahk_id " gOverlayHwnd
    SetClickThrough(gOverlayHwnd, true)
}

EnsureOverlayResources(width, height) {
    global gOverlayDC, gOverlayBmp, gOverlayBits, gOverlayOldBmp, gOverlaySizeW, gOverlaySizeH
    if (width <= 0 || height <= 0)
        return false
    if (width = gOverlaySizeW && height = gOverlaySizeH && gOverlayDC)
        return true
    DestroyOverlayResources()
    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    gOverlayDC := DllCall("gdi32\CreateCompatibleDC", "ptr", hdcScreen, "ptr")
    if !gOverlayDC {
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)
        return false
    }
    bmi := Buffer(40, 0)
    NumPut("uint", 40, bmi, 0)              ; biSize
    NumPut("int", width, bmi, 4)             ; biWidth
    NumPut("int", -height, bmi, 8)           ; biHeight (top-down)
    NumPut("ushort", 1, bmi, 12)             ; biPlanes
    NumPut("ushort", 32, bmi, 14)            ; biBitCount
    NumPut("uint", 0, bmi, 16)               ; biCompression = BI_RGB
    bits := 0
    gOverlayBmp := DllCall("gdi32\CreateDIBSection", "ptr", gOverlayDC, "ptr", bmi.Ptr, "uint", 0, "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
    if !gOverlayBmp {
        DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)
        DestroyOverlayResources()
        return false
    }
    gOverlayOldBmp := DllCall("gdi32\SelectObject", "ptr", gOverlayDC, "ptr", gOverlayBmp, "ptr")
    gOverlayBits := bits
    gOverlaySizeW := width
    gOverlaySizeH := height
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)
    return true
}

DestroyOverlayResources() {
    global gOverlayDC, gOverlayBmp, gOverlayBits, gOverlayOldBmp, gOverlaySizeW, gOverlaySizeH
    if gOverlayDC {
        if gOverlayOldBmp
            DllCall("gdi32\SelectObject", "ptr", gOverlayDC, "ptr", gOverlayOldBmp)
        if gOverlayBmp
            DllCall("gdi32\DeleteObject", "ptr", gOverlayBmp)
        DllCall("gdi32\DeleteDC", "ptr", gOverlayDC)
    }
    gOverlayDC := 0
    gOverlayBmp := 0
    gOverlayBits := 0
    gOverlayOldBmp := 0
    gOverlaySizeW := 0
    gOverlaySizeH := 0
}

PositionOverlay() {
    global gOverlay, gViewport
    if !IsObject(gOverlay)
        return
    gOverlay.Show(Format("NA x{} y{} w{} h{}", gViewport["x"], gViewport["y"], gViewport["w"], gViewport["h"]))
}

PresentFrame(srcRect, vpRect) {
    global gOverlayHwnd, gOverlayDC, gOverlayBits
    if !gOverlayHwnd
        return
    if !EnsureOverlayResources(vpRect["w"], vpRect["h"])
        return

    ; Temporarily hide the overlay to avoid capturing itself
    WinHide("ahk_id " gOverlayHwnd)
    Sleep 5  ; Brief pause to ensure window is hidden

    hdcScreen := DllCall("user32\GetDC", "ptr", 0, "ptr")
    if !hdcScreen {
        WinShow("ahk_id " gOverlayHwnd)
        return
    }
    DllCall("gdi32\SetStretchBltMode", "ptr", gOverlayDC, "int", 4) ; HALFTONE
    DllCall("gdi32\StretchBlt"
        , "ptr", gOverlayDC
        , "int", 0, "int", 0, "int", vpRect["w"], "int", vpRect["h"]
        , "ptr", hdcScreen
        , "int", srcRect["x"], "int", srcRect["y"], "int", srcRect["w"], "int", srcRect["h"]
        , "uint", 0x00CC0020)
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcScreen)

    FillAlphaChannel(vpRect["w"], vpRect["h"])

    blend := Buffer(4, 0)
    NumPut("uchar", 0, blend, 0)      ; AC_SRC_OVER
    NumPut("uchar", 0, blend, 1)
    NumPut("uchar", 255, blend, 2)    ; fully opaque
    NumPut("uchar", 1, blend, 3)      ; per-pixel alpha

    size := Buffer(8, 0)
    NumPut("int", vpRect["w"], size, 0)
    NumPut("int", vpRect["h"], size, 4)

    ptDst := Buffer(8, 0)
    NumPut("int", vpRect["x"], ptDst, 0)
    NumPut("int", vpRect["y"], ptDst, 4)

    ptSrc := Buffer(8, 0)

    DllCall("user32\UpdateLayeredWindow"
        , "ptr", gOverlayHwnd
        , "ptr", 0
        , "ptr", ptDst.Ptr
        , "ptr", size.Ptr
        , "ptr", gOverlayDC
        , "ptr", ptSrc.Ptr
        , "uint", 0
        , "ptr", blend.Ptr
        , "uint", 2) ; ULW_ALPHA

    ; Show the overlay again
    WinShow("ahk_id " gOverlayHwnd)
}

FillAlphaChannel(width, height) {
    global gOverlayBits
    if !gOverlayBits
        return
    total := width * height
    addr := Integer(gOverlayBits)
    loop total {
        offset := (A_Index - 1) * 4 + 3
        NumPut("uchar", 255, addr + offset)
    }
}

EnableLiveHotkeys(on := true) {
    global
    loop 9 {
        idx := A_Index
        Hotkey(Format("{}", idx), MakeZoneHotkey(idx), on ? "On" : "Off")
    }
    Hotkey("Left", (*) => PrevZone(), on ? "On" : "Off")
    Hotkey("Right", (*) => NextZone(), on ? "On" : "Off")
    Hotkey("Esc", (*) => Overview(), on ? "On" : "Off")
    Hotkey("0", (*) => Overview(), on ? "On" : "Off")
}

Overview(*) {
    global gCurIdx, gOverlay, gCurSrc, gTgtSrc, gAnimSrcStart, gViewport, gAnimStart, gAnimEnd
    gCurIdx := 0
    ; Reset to showing full viewport
    gCurSrc := CloneRect(gViewport)
    gTgtSrc := CloneRect(gViewport)
    gAnimSrcStart := CloneRect(gViewport)
    gAnimStart := 0
    gAnimEnd := 0
    ; Keep rendering to show the full viewport
    ; Don't stop rendering or hide overlay - just show full viewport
}

PrevZone(*) {
    global gCurIdx, gZones
    if (gZones.Length = 0)
        return
    gCurIdx := (gCurIdx <= 1) ? gZones.Length : (gCurIdx - 1)
    JumpToZone(gCurIdx)
}

NextZone(*) {
    global gCurIdx, gZones
    if (gZones.Length = 0)
        return
    gCurIdx := (gCurIdx >= gZones.Length) ? 1 : (gCurIdx + 1)
    JumpToZone(gCurIdx)
}

JumpToZone(idx, animate := true) {
    global gZones, gTgtSrc, gCurSrc, gAnimSrcStart, gAnimStart, gAnimEnd, gTransition, gPaused, gCurIdx
    if (idx < 1 || idx > gZones.Length)
        return
    EnsureOverlayGui()
    PositionOverlay()
    if !gPaused
        StartRendering()
    z := gZones[idx]
    tgt := ComputeSourceRect(z)
    gTgtSrc := tgt
    gCurIdx := idx
    if !animate {
        gCurSrc := CloneRect(tgt)
        gAnimSrcStart := CloneRect(tgt)
        gAnimStart := 0
        gAnimEnd := 0
        return
    }
    gAnimSrcStart := CloneRect(gCurSrc)
    gAnimStart := A_TickCount
    gAnimEnd := gAnimStart + gTransition
}

ComputeSourceRect(zone) {
    ; Since zones now match viewport aspect ratio, just use the zone directly
    return Map("x", zone["x"], "y", zone["y"], "w", zone["w"], "h", zone["h"])
}

StartRendering() {
    global gRenderOn, gTimerFn, gFrameMs
    if gRenderOn
        return
    gRenderOn := true
    SetTimer(gTimerFn, gFrameMs)
}

StopRendering() {
    global gRenderOn, gTimerFn
    if !gRenderOn
        return
    gRenderOn := false
    SetTimer(gTimerFn, 0)
}

TogglePause(*) {
    global gPaused, gCurIdx
    gPaused := !gPaused
    if gPaused
        StopRendering()
    else if (gCurIdx != 0)
        StartRendering()
}

; ================ Render loop =====================
RenderTick() {
    global gOverlayHwnd, gViewport, gCurSrc, gTgtSrc, gAnimSrcStart, gAnimStart, gAnimEnd
    if (gAnimEnd > gAnimStart) {
        now := A_TickCount
        if (now >= gAnimEnd) {
            gCurSrc := CloneRect(gTgtSrc)
            gAnimStart := 0, gAnimEnd := 0
        } else {
            t := (now - gAnimStart) / (gAnimEnd - gAnimStart)
            t := EaseInOutCubic(t)
            gCurSrc := LerpRect(gAnimSrcStart, gTgtSrc, t)
        }
    }
    if gOverlayHwnd
        PresentFrame(gCurSrc, gViewport)
}

EaseInOutCubic(t) {
    return (t < 0.5) ? 4 * t * t * t : 1 - ((-2 * t + 2) ** 3) / 2
}

LerpRect(a, b, t) {
    lerp := (x1, x2, tt) => x1 + (x2 - x1) * tt
    return Map(
        "x", Floor(lerp(a["x"], b["x"], t))
      , "y", Floor(lerp(a["y"], b["y"], t))
      , "w", Floor(lerp(a["w"], b["w"], t))
      , "h", Floor(lerp(a["h"], b["h"], t))
    )
}

SetClickThrough(hwnd, enable := true) {
    ex := DllCall("user32\GetWindowLongPtr", "ptr", hwnd, "int", -20, "ptr")
    if enable {
        ex |= 0x20 ; WS_EX_TRANSPARENT
        ex |= 0x80000 ; WS_EX_LAYERED
    } else
        ex &= ~0x20
    DllCall("user32\SetWindowLongPtr", "ptr", hwnd, "int", -20, "ptr", ex, "ptr")
}

; =============== Launch setup on start ===============
ShowSetup()
return

ExitCleanup(*) {
    HideVisualOutlines()
    DestroyOverlayResources()
}

; ================= Utility Helpers =================
InitDpiAwareness() {
    static init := false
    if init
        return
    ; Try per-monitor v2 awareness first, fall back to system awareness for older OSes.
    if DllCall("shcore\SetProcessDpiAwareness", "int", 2, "uint") != 0
        DllCall("user32\SetProcessDPIAware")
    init := true
}

CloneRect(src) {
    return Map("x", src["x"], "y", src["y"], "w", src["w"], "h", src["h"])
}

Clamp(val, minVal, maxVal) {
    if val < minVal
        return minVal
    if val > maxVal
        return maxVal
    return val
}

MakeZoneHotkey(idx) {
    return (*) => ToggleZone(idx)
}

ToggleZone(idx) {
    global gCurIdx
    ; If already viewing this zone, zoom out to overview
    if (gCurIdx = idx) {
        Overview()
    } else {
        JumpToZone(idx)
    }
}

GetVirtualScreenRect() {
    ; Get the virtual screen coordinates (all monitors combined)
    x := DllCall("user32\GetSystemMetrics", "int", 76, "int")  ; SM_XVIRTUALSCREEN
    y := DllCall("user32\GetSystemMetrics", "int", 77, "int")  ; SM_YVIRTUALSCREEN
    w := DllCall("user32\GetSystemMetrics", "int", 78, "int")  ; SM_CXVIRTUALSCREEN
    h := DllCall("user32\GetSystemMetrics", "int", 79, "int")  ; SM_CYVIRTUALSCREEN
    return Map("x", x, "y", y, "w", w, "h", h)
}

ClampPointToRect(&x, &y, rect) {
    ; Clamp a point to be within a rectangle
    if x < rect["x"]
        x := rect["x"]
    if x > rect["x"] + rect["w"] - 1
        x := rect["x"] + rect["w"] - 1
    if y < rect["y"]
        y := rect["y"]
    if y > rect["y"] + rect["h"] - 1
        y := rect["y"] + rect["h"] - 1
}

ApplyColorKey(hwnd, color) {
    ; Make a specific color transparent using WS_EX_LAYERED
    ex := DllCall("user32\GetWindowLongPtr", "ptr", hwnd, "int", -20, "ptr")
    ex |= 0x80000  ; WS_EX_LAYERED
    DllCall("user32\SetWindowLongPtr", "ptr", hwnd, "int", -20, "ptr", ex, "ptr")
    DllCall("user32\SetLayeredWindowAttributes", "ptr", hwnd, "uint", color, "uchar", 0, "uint", 1)
}

SyncSettingsFromInputs() {
    global gTransition, gTransEdit
    if IsObject(gTransEdit) && gTransEdit.Value != ""
        gTransition := Integer(gTransEdit.Value)
    if (gTransition < 0)
        gTransition := 0
}

ResetAnimationToCurrentZone(instant := true) {
    global gCurIdx, gZones, gCurSrc, gTgtSrc, gAnimSrcStart, gAnimStart, gAnimEnd, gViewport
    if (gCurIdx < 1 || gCurIdx > gZones.Length) {
        ; No valid zone, show full viewport
        gCurSrc := CloneRect(gViewport)
        gTgtSrc := CloneRect(gViewport)
        gAnimSrcStart := CloneRect(gViewport)
        gAnimStart := 0
        gAnimEnd := 0
        return
    }
    z := gZones[gCurIdx]
    tgt := ComputeSourceRect(z)
    gTgtSrc := tgt
    if instant {
        gCurSrc := CloneRect(tgt)
        gAnimSrcStart := CloneRect(tgt)
        gAnimStart := 0
        gAnimEnd := 0
    }
}
