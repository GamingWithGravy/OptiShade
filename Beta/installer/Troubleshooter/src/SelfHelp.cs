using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
namespace OptiShade.TesterKit {
// What a finding means to the player and what they can try, so Check my setup
// can help without a report. The developer-facing Finding (Area, Text) is
// unchanged; this is a second, plain-language reading of the same rules.
public sealed class Advice {
    public string Title, Why, TryThis;
    public bool UserCanFix;   // false: needs the developer, so a report is the next step
    public bool Good;         // a "working" finding, shown as reassurance
    public Finding Source;
}
public static class SelfHelp {
    const string Update="Update OptiShade in the manager (Check for updates), then try again.";
    const string Antivirus="Open Windows Security > Virus & threat protection > Protection history. Restore any OptiShade, OptiMFG, ReShade or dxgi.dll item, add the game's OptiShadeData folder as an exclusion, then run Repair in the OptiShade manager.";
    const string GpuReset="Remove any GPU or memory overclock or undervolt (for example in MSI Afterburner), check the GPU power cables are fully seated, and clean-install the latest NVIDIA driver. If it only happens with an OptiShade feature on, send a report.";
    sealed class Rule {
        public string Prefix, Title, Why, TryThis; public bool Fix=true, Good;
    }
    // Most specific prefixes first; the first match wins.
    static readonly Rule[] Rules={
        new Rule{Prefix="OLD BUILD",Title="Your OptiShade build is out of date",Why="Problems found in your logs are already fixed in a newer build.",TryThis=Update},
        new Rule{Prefix="WRONG GAME EXE",Title="OptiShade is installed next to the game's launcher",Why="The EXE you chose only starts the real game, which never loads OptiShade from that folder.",TryThis="In the OptiShade manager, choose Restore original game files for this game, then add it again and pick the game EXE named in the details below. Start the game as usual."},
        new Rule{Prefix="WINDOWS SECURITY DETECTION",Title="Windows Security recorded a related detection",Why="A detection is recorded for a selected-game or OptiShade-named file. The event alone does not establish current quarantine or the cause of a game problem.",TryThis="Open Windows Security > Protection history and check the affected path and current action. Verify the download source before restoring anything; do not disable protection or exclude unrelated files."},
        new Rule{Prefix="GPU DRIVER TIMEOUT",Title="Your graphics driver stopped responding and was reset",Why="Windows reset the GPU (a TDR). The event alone does not identify whether the cause was application GPU work, an add-on, the driver or hardware.",TryThis=GpuReset},
        new Rule{Prefix="GPU REMOVAL",Title="The graphics card was reset during the game",Why="The GPU stopped and the game lost its graphics device.",TryThis=GpuReset},
        new Rule{Prefix="GPU DEVICE LOST",Title="The game lost its graphics device",Why="The GPU or driver reset while the game was running.",TryThis=GpuReset},
        new Rule{Prefix="SWAPCHAIN RESIZE FAILED",Title="The game failed when its window changed size or mode",Fix=false,Why="Switching between windowed and fullscreen, or changing resolution, failed inside the graphics hooks.",TryThis="Avoid changing window mode or resolution while playing. If it keeps happening, send a report."},
        new Rule{Prefix="NR FLICKER",Title="NR skipped frames, which flickers",Why="On older builds NR skipped single frames, so the picture switched between NR and no NR.",TryThis=Update},
        new Rule{Prefix="NR RAN ON GENERATED FRAMES",Title="NR ran on generated frames",Why="On older builds NR also processed frame-generation frames, which costs frame rate and can flicker.",TryThis=Update},
        new Rule{Prefix="IMAGE EFFECTS DEPTH FLICKER",Title="Depth-based image effects flickered",Why="On older builds the depth buffer that effects read kept dropping out.",TryThis=Update},
        new Rule{Prefix="LOW SYSTEM MEMORY",Title="Windows was nearly out of memory",Why="When Windows runs out of memory to give the game, it crashes to desktop with no other warning.",TryThis="Let Windows manage the page file size (System > About > Advanced system settings > Performance > Advanced > Virtual memory), make sure the drive it uses has free space, and close browsers and other large apps while flying."},
        new Rule{Prefix="MEMORY GROWTH",Title="The game's memory kept growing during the session",Why="Memory climbed steadily the longer you played. The report cannot tell which part of the game, an add-on or OptiShade used it.",TryThis="Fly the same route once with OptiShade's features off (NR, image effects, OptiMFG) and once with them on, then send a report from each so they can be compared."},
        new Rule{Prefix="VIDEO MEMORY OVER BUDGET",Title="Video memory was over budget",Why="The game asked for more graphics memory than the card has, so Windows moved some to system memory. That causes stutter and can crash.",TryThis="Lower texture quality, resolution or render scaling. With NR on, lower its working resolution."},
        new Rule{Prefix="IMAGE EFFECTS NOT LOADED",Title="Image effects are switched off in OptiShade's settings file",Why="The settings file next to the game was reset, so ReShade (image effects) was never loaded and the effects page says it is not responding.",TryThis="Update OptiShade to R330 or later. On an older build, close the game, open OptiScaler.ini in the game folder and set LoadReShade=true under [Plugins], then start the game again."},
        new Rule{Prefix="IMAGE EFFECTS DEPTH STILL CHANGING",Title="Depth-based image effects may flicker",Why="The depth buffer used by fog, ambient occlusion, depth of field and depth-masked sharpening kept changing.",TryThis="Turn off depth-based effects one at a time to find the one that flickers, and keep it off. Note which one it was if you send a report."},
        new Rule{Prefix="NR MEMORY ON/OFF LOOP",Title="NR kept switching off and on near the memory limit",Why="Video memory was nearly full and older builds stopped and restarted NR repeatedly.",TryThis=Update+" Lowering texture quality also helps."},
        new Rule{Prefix="NR PAUSED FOR GPU MEMORY",Title="NR paused because video memory was full",Why="Pause NR when video memory is low is on and memory ran out.",TryThis="Lower texture quality or resolution, close other GPU-heavy apps, or turn off Pause NR when video memory is low."},
        new Rule{Prefix="NR LOW VIDEO MEMORY",Title="Video memory was nearly full",Why="NR kept running, but stutter is likely when memory is this tight.",TryThis="Lower texture quality or resolution, or close other GPU-heavy apps such as browsers and recorders."},
        new Rule{Prefix="NR PARKED-MODEL LIMIT",Title="NR could not rebuild after a size change",Why="On older builds NR got stuck after the game changed its frame size.",TryThis=Update},
        new Rule{Prefix="NR STUCK REBUILDING",Title="NR got stuck rebuilding",Fix=false,Why="NR stopped while rebuilding after a frame-size change.",TryThis="Restart the game. If it happens again, send a report."},
        new Rule{Prefix="NR BLOCKS THE GAME THREAD",Title="NR slowed the game down",Why="On older builds NR waited for the GPU on the game's thread.",TryThis=Update},
        new Rule{Prefix="NR GAME-THREAD COST HIGH",Title="NR is costing a lot of frame time",Why="NR's work per frame is high on this PC with these settings.",TryThis="Lower NR's quality passes or working resolution, or turn NR off to compare frame rate."},
        new Rule{Prefix="GAME FRAME RATE DROPPED WHILE NR ON",Title="Frame rate dropped with NR on",Why="The game's frame rate fell while NR was on; the logs do not prove NR's GPU work caused the drop.",TryThis="Compare the same scene with NR off and on once, keeping FG, focus, AA, and VSync unchanged. If the large drop repeats, leave NR off for that session and send diagnostics."},
        new Rule{Prefix="NR NOT COMPLETING FRAMES",Title="NR was on but did not finish frames",Why="NR was switched on, but its frames did not complete, so it had no effect.",TryThis="Open the OptiShade menu in game: the NR status says why it is waiting and what to try."},
        new Rule{Prefix="NR LAST FAILURE",Title="NR stopped with an error",Why="NR reported a failure in the last session; the reason is in the details.",TryThis="Restart the game. If the same reason comes back, send a report."},
        new Rule{Prefix="NR WAS SWITCHED OFF",Title="NR was switched off",Good=true,Why="NR was off at the end of the last session, so it did not run.",TryThis="Turn NR on in the OptiShade menu if you want it."},
        new Rule{Prefix="RUNTIME LOG MISSING",Title="OptiShade did not record the last game session",Why="No current OptiShade log was found, so either the game has not run with OptiShade since it was installed or the log path is wrong.",TryThis="Start the game once with OptiShade installed. If this stays, run Repair in the manager. Check the game EXE you chose is the one that actually renders."},
        new Rule{Prefix="RUNTIME LOG EMPTIED",Title="The OptiShade log was emptied",Fix=false,Why="Another program that loaded OptiShade restarted the game's log while you played, so this session is hidden.",TryThis="Update to R338 or later, play again, then send a new report."},
        new Rule{Prefix="RUNTIME LOG OVERWRITTEN",Title="The OptiShade log was overwritten",Fix=false,Why="A helper process overwrote the game's OptiShade log, so the last session is hidden.",TryThis="Send a report; this needs the developer."},
        new Rule{Prefix="MFG: OptiMFG applied",Title="Frame generation is off in the game",Why="OptiMFG had a multiplier ready, but the game's own DLSS Frame Generation was off.",TryThis="Turn on DLSS Frame Generation in the game's graphics settings, then load into a flight or scene."},
        new Rule{Prefix="MFG BACKEND SNAPSHOT",Title="OptiMFG loader needs a later connection check",Why="The log only checked loaded modules when Streamline initialized. That snapshot cannot tell whether the OptiMFG proxy loaded later.",TryThis="Keep other version.dll files in place. Close and relaunch the game with OptiMFG running, then export a fresh combined report so the controller and game module evidence can be matched to the same process."},
        new Rule{Prefix="MFG: the OptiMFG backend never loaded",Title="OptiMFG's backend did not load",Why="OptiMFG was running, but its backend never loaded into the game.",TryThis="Run Repair on OptiMFG in the manager. If antivirus is installed: "+Antivirus},
        new Rule{Prefix="MFG LOW-FRAME-COUNT WHILE UNFOCUSED",Title="A low MFG sample happened while the game was unfocused",Good=true,Why="This reports a low frame count since a provider query while another window had focus. It does not prove generation stopped.",TryThis="Keep the game focused during a controlled performance comparison."},
        new Rule{Prefix="MFG LOW-FRAME-COUNT INTERVAL",Title="OptiMFG reported a low frame count for part of the session",Fix=false,Why="The value counts frames since a DLSS-G state query, not frames per present. Low samples and FPS changes do not identify why output changed.",TryThis="Note what changed around the interval and send a diagnostic report if the game felt worse."},
        new Rule{Prefix="MFG LOW-FRAME-COUNT SAMPLE",Title="OptiMFG reported one low frame-count sample",Fix=false,Why="A single count since the previous DLSS-G state query does not prove that frame generation stopped.",TryThis="If you saw a sustained FPS or smoothness change, note the setting and send a diagnostic report."},
        new Rule{Prefix="MFG PRESENTATION ACTIVITY",Title="The MFG provider reported presentation activity",Good=true,Why="Frames were reported since the previous provider state query. This does not verify the displayed multiplier or cadence.",TryThis="If the game still feels jittery, compare measured FPS and send a report from the affected session."},
        new Rule{Prefix="MFG LOW-FRAME-COUNT",Title="OptiMFG reported a low frame count",Fix=false,Why="Streamline reports frames since its previous state query; this count alone cannot establish a generation failure.",TryThis="If output changed noticeably, send a diagnostic report."},
        new Rule{Prefix="MFG PAUSED IN BACKGROUND",Title="Frame generation paused while the game was in the background",Good=true,Why="This is expected: it resumes when the game window is focused.",TryThis="Click into the game window."},
        new Rule{Prefix="MFG NOT REQUESTED",Title="No OptiMFG multiplier was chosen",Good=true,Why="OptiMFG was connected but no multiplier was selected.",TryThis="Choose a multiplier on the Performance page of the OptiShade menu."},
        new Rule{Prefix="MFG WORKING",Title="OptiMFG frame generation worked",Good=true,Why="Generated frames were reported.",TryThis="Nothing to do."},
        new Rule{Prefix="MFG DROPPED OUT",Title="Reduced frame generation was sampled",Fix=false,Why="The backend reported fewer generated frames during part of the session. The samples do not identify the cause of jitter or a permanent failure.",TryThis="Note what you changed just before it stopped and send a report."},
        new Rule{Prefix="MFG NOT GENERATING",Title="OptiMFG was on but no frames were generated",Fix=false,Why="Settings were accepted, but no generated frames were presented.",TryThis="Check the game's frame generation is on and no frame-rate limit is set below your refresh rate. If it stays, send a report."},
        new Rule{Prefix="VIRTUAL DISPLAY ADAPTER",Title="A virtual display driver is installed",Why="Virtual displays (Parsec, Virtual Desktop, streaming tools) can take the game's output path.",TryThis="Disable the virtual display adapter in Device Manager or its app, then test again."},
        new Rule{Prefix="HYBRID GPU",Title="This PC has more than one GPU",Good=true,Why="The game must run on the NVIDIA GPU for NR and frame generation.",TryThis="In Windows Settings > System > Display > Graphics, set the game to High performance."},
        new Rule{Prefix="MANAGER",Title="The OptiShade manager reported an error",Why="An install, update or repair step failed; the details name it.",TryThis="Close and reopen the manager and try the step again. If it fails again, run Repair, then send a report."},
        new Rule{Prefix="SIMULATOR CRASH REPORT",Title="The game crashed",Fix=false,Why="The game wrote a crash report.",TryThis="Turn on crash dumps on this screen, reproduce the crash, then send a report."},
        new Rule{Prefix="OPTIMFG CRASHED",Title="OptiMFG crashed",Fix=false,Why="The OptiMFG app closed itself; Windows recorded the crash.",TryThis="Start OptiMFG again from the Start menu or the OptiShade manager, then send a report so the crash can be fixed."},
        new Rule{Prefix="PC RESTARTED UNEXPECTEDLY",Title="Your whole PC crashed or restarted",Fix=false,Why="Windows recorded an unexpected restart. A game or add-on cannot restart the whole PC by itself.",TryThis="Remove any GPU/CPU overclock or undervolt, check temperatures and the power supply, then update the graphics driver."},
        new Rule{Prefix="IMAGE EFFECTS IN THE VR HEADSET",Title="Image effects are running in your VR headset",Fix=true,Why="Your desktop effects preset also runs on the headset image, which is several times larger, so it uses far more GPU time and video memory.",TryThis="On the Image effects page turn off \"Link headset look to desktop\" and pick a light preset (or none) for the headset."},
        new Rule{Prefix="GLASS COCKPIT FIX NOT DRAWING",Title="Glass Cockpit correction did not receive usable DLSS frames",Fix=false,Why="The report checks the add-on's log and OptiShade's renderer log together. If both show the WinMM hook conflict, OptiScaler and the Glass Cockpit correction are intercepting DLSS through competing hooks; a later NVIDIA device can also mean the first adapter check was premature.",TryThis="Set Microsoft Flight Simulator to High performance in Windows Graphics settings and confirm its anti-aliasing is DLSS. If the report still shows a WinMM hook conflict, send it to OptiShade and the Glass Cockpit fix developer; do not delete renderer files manually."},
        new Rule{Prefix="ANOTHER RESHADE LOADED FIRST",Title="Another ReShade is installed in the game folder",Fix=true,Why="A separate ReShade starts before OptiShade's, so OptiShade's image effects do not run and both hook the game.",TryThis="Remove the other ReShade with its own installer (or move its DLL out of the game folder), then press Repair in OptiShade."},
        new Rule{Prefix="GAME FROZE IN A CRASH HANDLER",Title="The game crashed but froze instead of closing",Fix=false,Why="The game hit a fatal error and got stuck saving its own crash dump.",TryThis="Close it in Task Manager, then send a report straight away so the crash files are included."},
        new Rule{Prefix="CRASH DUMP",Title="The game crashed",Fix=false,Why="A crash dump from this session was found; the details name the modules near the fault.",TryThis="Note what you pressed or did just before the crash, then send a report."},
        new Rule{Prefix="CRASH in ",Title="The game crashed",Fix=false,Why="Windows recorded a crash; the details name the module.",TryThis="Turn on crash dumps on this screen, reproduce the crash, then send a report. If it started after an overclock or driver change, undo that first."},
    };
    public static Advice For(Finding f) {
        var rule=Rules.FirstOrDefault(x=>f.Text.StartsWith(x.Prefix,StringComparison.Ordinal));
        if(rule==null)return new Advice{Title="Something the developer needs to look at",Why=Shorten(f.Text),TryThis="Send a report so the developer can check it.",UserCanFix=false,Source=f};
        return new Advice{Title=rule.Title,Why=rule.Why,TryThis=rule.TryThis,UserCanFix=rule.Fix&&!rule.Good,Good=rule.Good,Source=f};
    }
    // Player order: things they can fix first (most severe first), then report-only
    // findings, then reassurance. Context-only findings (S4) are kept only when a
    // rule gives them a player meaning.
    public static List<Advice> Build(IEnumerable<Finding> findings) {
        var list=findings.Select(For).Where(a=>a.Source.Severity<4||a.Good||a.UserCanFix).ToList();
        return list.OrderBy(a=>a.Good?2:a.UserCanFix?0:1).ThenBy(a=>a.Source.Severity).ToList();
    }
    public static string Format(List<Advice> advice) {
        if(advice.Count==0)return "No known problem was found in your logs.\r\nIf something is still wrong, describe it and send a report.\r\n";
        var b=new StringBuilder();
        foreach(var a in advice) {
            b.Append(a.Good?"OK  ":a.UserCanFix?"FIX ":"REPORT ").Append(a.Title).Append("\r\n");
            b.Append("    Why: ").Append(a.Why).Append("\r\n");
            b.Append("    Try this: ").Append(a.TryThis).Append("\r\n");
        }
        return b.ToString();
    }
    static string Shorten(string text){int colon=text.IndexOf(':');string head=colon>0&&colon<60?text.Substring(0,colon):text;return head.Length>200?head.Substring(0,200)+"...":head;}
}
}
