#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn
CoordMode "Mouse", "Screen"

; =======================
; FocusZoom (AHK v2) - POC
; =======================
; - Draw a Viewport (destination box).
; - Draw Zones (source rectangles).
; - Hotkeys 1..9 jump; ←/→ cycle; Esc/0 overview; F9 setup; Ctrl+Shift+P pause.
; - Overlay is an always-on-top, click-through window.
; - GDI capture/scale (StretchBlt) for a quick POC.

; --------------- Settings ---------------
global gZoom        := 2.0          ; default zoom (2.0x)
global gTransition  := 300          ; ms for zone transition animation
global gFrameMs     := 33           ; ~30 fps while live (raise to 50–66 if CPU high)
global gPaused      := false
global gPresetPath  := A_AppData "\FocusZoom\preset.ini"

; --------------- State ------------------
global gViewport := Map("x", 200, "y", 200, "w", 600, "h", 400)
global gZones := []                 ; each: {x,y,w,h}
global gCurIdx := 0                 ; current zone index (1-based), 0 = overview
global gCurSrc := Map("x", 0, "y", 0, "w", 300, "h", 200) ; current source rect
global gTgtSrc := Map("x", 0, "y", 0, "w", 300, "h", 200)
global gAnimStart := 0
global gAnimEnd := 0
global gOverlay := 0                ; GUI object (viewport window)
global gOverlayHwnd := 0
global gRenderOn := false
global gTimerFn := (*) => RenderTick()

; --------------- Tray menu --------------
A_TrayMenu.Delete()
A_TrayMenu.Add("&Setup / Show", (*) => ShowSetup())
A_TrayMenu.Add("&Pause/Resume (Ctrl+Shift+P)", (*) => TogglePause())
A_TrayMenu.Add("Save Preset", (*) => SavePreset())
A_TrayMenu.Add("Load Preset", (*) => LoadPreset())
A_TrayMenu.Add()
A_TrayMenu.Add("E&xit", (*) => ExitApp())

; --------------- Hotkeys ----------------
; (Use explicit lambdas so v2 never treats names as uninitialized vars.)
Hotkey("F9", (*) => ToggleSetup())
Hotkey("^+p", (*) => TogglePause())

; =============== UI: Setup Window =================
global gSetup, gZonesList, gZoomEdit, gTransEdit

MakeSetupUi() {
    global gSetup, gZonesList, gZoomEdit, gTransEdit

    if IsSet(gSetup) && IsObject(gSetup) {
        try gSetup.Destroy()
    }

    gSetup := Gui("+AlwaysOnTop", "FocusZoom - Setup")
    gSetup.MarginX := 10, gSetup.MarginY := 10

    gSetup.Add("Text",, "1) Click 'Set Viewport' and drag a box where the zoom will appear.")
    gSetup.Add("Button", "w130", "Set Viewport").OnEvent("Click", (*) => SetViewport())

    gSetup.Add("Text", "y+10", "2) Click 'Add Zone' and drag rectangles over areas you want to zoom.")
    btnAdd := gSetup.Add("Button", "w130", "Add Zone")
    btnAdd.OnEvent("Click", (*) => AddZone())

    gSetup.Add("Text", "y+10", "Zones (press 1..9 to jump during Live):")
    gZonesList := gSetup.Add("ListBox", "w260 h160")

    rowBtns := gSetup.Add("GroupBox", "w260 h50", "Manage")
    bDel := gSetup.Add("Button", "x+10 yp+20 w80", "Delete")
    bClr := gSetup.Add("Button", "x+5 w80", "Clear All")
    bDel.OnEvent("Click", (*) => DelSelectedZone())
    bClr.OnEvent("Click", (*) => ClearZones())

    gSetup.Add("Text", "y+10", "Zoom (e.g., 2.0):")
    gZoomEdit := gSetup.Add("Edit", "w80", gZoom)
    gSetup.Add("Text", "x+10", "Transition ms:")
    gTransEdit := gSetup.Add("Edit", "w80", gTransition)

    gSetup.Add("Button", "y+10 w120", "Save Preset").OnEvent("Click", (*) => SavePreset())
    gSetup.Add("Button", "x+10 w120", "Load Preset").OnEvent("Click", (*) => LoadPreset())

    gSetup.Add("Text", "y+10", "3) Click 'Go Live' to start overlay and hotkeys.")
    gSetup.Add("Button", "w120", "Go Live").OnEvent("Click", (*) => GoLive())

    gSetup.OnEvent("Close", (*) => gSetup.Hide())
}

ShowSetup() {
    global
    MakeSetupUi()
    RefreshZonesList()
    gSetup.Show()
}

; =============== Selection helpers ================
SelectRect(prompt := "Drag to select a rectangle") {
    ToolTip(prompt)
    sel := Gui("+AlwaysOnTop -Caption +ToolWindow +Border")
    sel.Show("NA x0 y0 w1 h1")

    KeyWait("LButton", "D")
    MouseGetPos &sx, &sy
    rect := {x: sx, y: sy, w: 1, h: 1}

    while GetKeyState("LButton", "P") {
        Sleep 10
        MouseGetPos &mx, &my
        rect.x := (mx < sx) ? mx : sx
        rect.y := (my < sy) ? my : sy
        rect.w := Abs(mx - sx)
        rect.h := Abs(my - sy)
        if rect.w < 2
            rect.w := 2
        if rect.h < 2
            rect.h := 2
        sel.Show(Format("NA x{} y{} w{} h{}", rect.x, rect.y, rect.w, rect.h))
    }
    sel.Destroy()
    ToolTip()
    return rect
}

; =============== Setup actions ====================
SetViewport() {
    global gViewport
    r := SelectRect("Drag to set the VIEWPORT (destination box)")
    gViewport := Map("x", r.x, "y", r.y, "w", r.w, "h", r.h)
    MsgBox "Viewport set to: " RectStr(gViewport)
}

AddZone() {
    global gZones
    r := SelectRect("Drag to set a ZONE (source area)")
    gZones.Push(Map("x", r.x, "y", r.y, "w", r.w, "h", r.h))
    RefreshZonesList()
}

DelSelectedZone() {
    global gZones, gZonesList
    idx := gZonesList.Value
    if !idx
        return
    gZones.RemoveAt(idx)
    RefreshZonesList()
}

ClearZones() {
    global gZones
    gZones := []
    RefreshZonesList()
}

RefreshZonesList() {
    global gZones, gZonesList
    if !IsObject(gZonesList)
        return
    items := []
    for idx, z in gZones
        items.Push(Format("{:d}) {}", idx, RectStr(z)))
    gZonesList.Delete()
    if items.Length  ; avoid "too few parameters" when empty
        gZonesList.Add(items*)
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
    global gViewport, gZones, gZoom, gTransition, gPresetPath, gZoomEdit, gTransEdit
    EnsurePresetDir()
    Try gZoom := Number(gZoomEdit.Value)
    Try gTransition := Integer(gTransEdit.Value)
    IniWrite gViewport["x"], gPresetPath, "Viewport", "x"
    IniWrite gViewport["y"], gPresetPath, "Viewport", "y"
    IniWrite gViewport["w"], gPresetPath, "Viewport", "w"
    IniWrite gViewport["h"], gPresetPath, "Viewport", "h"
    IniWrite gZoom, gPresetPath, "Settings", "Zoom"
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
    global gViewport, gZones, gZoom, gTransition, gPresetPath, gSetup
    if !FileExist(gPresetPath) {
        MsgBox "No preset found at:`n" gPresetPath
        return
    }
    gViewport["x"] := Integer(IniRead(gPresetPath, "Viewport", "x", gViewport["x"]))
    gViewport["y"] := Integer(IniRead(gPresetPath, "Viewport", "y", gViewport["y"]))
    gViewport["w"] := Integer(IniRead(gPresetPath, "Viewport", "w", gViewport["w"]))
    gViewport["h"] := Integer(IniRead(gPresetPath, "Viewport", "h", gViewport["h"]))
    gZoom := Number(IniRead(gPresetPath, "Settings", "Zoom", gZoom))
    gTransition := Integer(IniRead(gPresetPath, "Settings", "TransitionMs", gTransition))
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
    global gOverlay, gOverlayHwnd, gRenderOn, gCurIdx, gViewport, gZones

    if (gViewport["w"] < 10 || gViewport["h"] < 10) {
        MsgBox "Please set a valid viewport first."
        return
    }
    if (gZones.Length = 0) {
        MsgBox "Please add at least one zone."
        return
    }

    if !IsObject(gOverlay) {
        gOverlay := Gui("+AlwaysOnTop -Caption +ToolWindow")
        gOverlay.BackColor := "Black"
        gOverlay.Show(Format("NA x{} y{} w{} h{}", gViewport["x"], gViewport["y"], gViewport["w"], gViewport["h"]))
        gOverlayHwnd := gOverlay.Hwnd
        WinSetAlwaysOnTop true, "ahk_id " gOverlayHwnd
        SetClickThrough(gOverlayHwnd, true)
    } else {
        gOverlay.Show(Format("NA x{} y{} w{} h{}", gViewport["x"], gViewport["y"], gViewport["w"], gViewport["h"]))
    }

    EnableLiveHotkeys(true)
    gCurIdx := 1
    JumpToZone(gCurIdx, false)
    StartRendering()
    if IsSet(gSetup) && IsObject(gSetup)
        gSetup.Hide()
}

EnableLiveHotkeys(on := true) {
    global
    loop 9 {
        idx := A_Index
        Hotkey(Format("{}", idx), (*) => JumpToZone(idx), on ? "On" : "Off")
    }
    Hotkey("Left", (*) => PrevZone(), on ? "On" : "Off")
    Hotkey("Right", (*) => NextZone(), on ? "On" : "Off")
    Hotkey("Esc", (*) => Overview(), on ? "On" : "Off")
    Hotkey("0", (*) => Overview(), on ? "On" : "Off")
}

Overview(*) {
    global gCurIdx, gOverlay
    gCurIdx := 0
    StopRendering()
    if IsObject(gOverlay)
        gOverlay.Hide()
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
    global gZones, gTgtSrc, gCurSrc, gAnimStart, gAnimEnd, gTransition, gZoom
    if (idx < 1 || idx > gZones.Length)
        return
    z := gZones[idx]
    tgt := ComputeSourceRect(z, gZoom)
    gTgtSrc := tgt
    if !animate {
        gCurSrc := Map("x", tgt["x"], "y", tgt["y"], "w", tgt["w"], "h", tgt["h"])
        return
    }
    gAnimStart := A_TickCount
    gAnimEnd := gAnimStart + gTransition
}

ComputeSourceRect(zone, zoom) {
    global gViewport
    minZoomW := gViewport["w"] / Max(zone["w"], 1)
    minZoomH := gViewport["h"] / Max(zone["h"], 1)
    effZoom := Max(zoom, Max(minZoomW, minZoomH))
    sw := Floor(gViewport["w"] / effZoom)
    sh := Floor(gViewport["h"] / effZoom)
    sx := zone["x"] + Floor((zone["w"] - sw) / 2)
    sy := zone["y"] + Floor((zone["h"] - sh) / 2)
    return Map("x", sx, "y", sy, "w", sw, "h", sh)
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
    global gPaused
    gPaused := !gPaused
    if gPaused
        StopRendering()
    else
        StartRendering()
}

; ================ Render loop =====================
RenderTick() {
    global gOverlayHwnd, gViewport, gCurSrc, gTgtSrc, gAnimStart, gAnimEnd
    if (gAnimEnd > gAnimStart) {
        now := A_TickCount
        if (now >= gAnimEnd) {
            gCurSrc := Map("x", gTgtSrc["x"], "y", gTgtSrc["y"], "w", gTgtSrc["w"], "h", gTgtSrc["h"])
            gAnimStart := 0, gAnimEnd := 0
        } else {
            t := (now - gAnimStart) / (gAnimEnd - gAnimStart)
            t := EaseInOutCubic(t)
            gCurSrc := LerpRect(gCurSrc, gTgtSrc, t)
        }
    }
    if gOverlayHwnd
        BlitToOverlay(gOverlayHwnd, gCurSrc, gViewport)
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

BlitToOverlay(hwnd, srcRect, vpRect) {
    hdcSrc := DllCall("user32\GetDC", "ptr", 0, "ptr")
    hdcDst := DllCall("user32\GetDC", "ptr", hwnd, "ptr")
    DllCall("gdi32\SetStretchBltMode", "ptr", hdcDst, "int", 4) ; HALFTONE
    DllCall("gdi32\StretchBlt"
        , "ptr", hdcDst
        , "int", 0, "int", 0, "int", vpRect["w"], "int", vpRect["h"]
        , "ptr", hdcSrc
        , "int", srcRect["x"], "int", srcRect["y"], "int", srcRect["w"], "int", srcRect["h"]
        , "uint", 0x00CC0020) ; SRCCOPY
    DllCall("user32\ReleaseDC", "ptr", 0, "ptr", hdcSrc)
    DllCall("user32\ReleaseDC", "ptr", hwnd, "ptr", hdcDst)
}

SetClickThrough(hwnd, enable := true) {
    ex := DllCall("user32\GetWindowLongPtr", "ptr", hwnd, "int", -20, "ptr")
    if enable
        ex |= 0x20 ; WS_EX_TRANSPARENT
    else
        ex &= ~0x20
    DllCall("user32\SetWindowLongPtr", "ptr", hwnd, "int", -20, "ptr", ex, "ptr")
}

; =============== Launch setup on start ===============
ShowSetup()
return
