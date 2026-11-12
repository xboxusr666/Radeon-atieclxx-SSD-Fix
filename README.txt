Radeon-atieclxx-SSD-Fix 2.1 – Radeon driver continuously writes to the SSD
==========================================================================

WHAT IS THIS ABOUT?
On 2026-11-09, ComputerBase reported that the "AMD External Events Utility" service
of the AMD driver continuously writes to the system drive on many systems:
https://www.computerbase.de/news/grafikkarten/schnelle-ssd-alterung-radeon-treiber-schreibt-fortwaehrend-daten-auf-die-ssd.100237/
AMD has confirmed the bug; a fixed driver version is not yet available.

WHAT EXACTLY HAPPENS?
Measured using Event Tracing for Windows (ETW): on affected drivers,
atieclxx.exe copies itself EVERY SECOND from the driver folder to
  C:\Windows\System32\config\systemprofile\AppData\Local\AMD\atieclxx.exe
The file is around 660 KB in size, which amounts to roughly 56 GB per day of continuous operation.
Afterward, the service looks for installation files of the filter driver amdkmpfd (Smart Access
Memory). This explains why disabling Resizable BAR helps for some users.

THE PROGRAM (START.cmd)
START.cmd opens a window (confirm the Windows prompt for administrator privileges with "Yes").
It
  - measures whether and how heavily atieclxx.exe is writing, and shows which variant is present:
    self-copy to the known location, writing to another location, or not affected,
  - estimates how much data has already been written unnecessarily to the SSD (write rate times
    operating hours since the AMD graphics card was installed; an estimate, not an exact value),
  - provides buttons for the desired fix.
The measurement runs in the background while the window remains responsive.

THE FIX BUTTONS
1) Targeted protection (recommended)
   Denies only the SYSTEM account permission to overwrite or delete the copy mentioned above.
   The copy attempt fails immediately, so nothing is written anymore. The service keeps
   running; FreeSync, frame pacing, and hotkeys remain untouched. It also sets up the scheduled
   task "Radeon-atieclxx-SSD-Fix" (Task Scheduler, runs as SYSTEM 3 minutes after startup and
   every 30 minutes): it re-applies the protection after driver updates and automatically checks
   after a driver change whether AMD has fixed the bug. If so, it lifts the protection on its own.
2) Disable service
   The workaround from the article: stops the service and sets its startup type to "Disabled".
   Always works, but may affect FreeSync and frame pacing.
3) Undo all changes
   Reverts protection, automatic task, and service disabling. The program folder is kept.
The "What is Resizable BAR?" button explains the third option from the article. Because it can
only be changed in the BIOS, there is no button to toggle it here.

No files are downloaded, no internet connection is required, and the driver itself is not
modified. The entire source code is openly available in the "Script" folder.

ADDITIONAL FILES
  CHECK.cmd    quick status check, measures for 10 seconds (without admin rights)
  REMOVE.cmd   reverts all changes and also deletes the program folder
  LICENSE.txt  license (MIT)
After applying "Targeted protection", START.cmd, CHECK.cmd, REMOVE.cmd, and the log are also
located in
  C:\Program Files\Radeon-atieclxx-SSD-Fix

NOTES
- If Windows shows a SmartScreen warning at startup ("Windows protected your PC"):
  click "More info" -> "Run anyway". Alternatively, before extracting, right-click the ZIP file
  -> Properties -> check "Unblock".
- On corporate PCs where group policy only allows signed PowerShell scripts, the program will
  not start. On those systems, please disable the service manually via services.msc.
- On Windows Home, pop-up notifications from the background task are unavailable (msg.exe is not
  included in Windows Home); everything is still recorded in the log file.
- Other driver versions may behave differently. The program therefore measures first and only
  intervenes if the fix is effective.

ALTERNATIVE WITHOUT THIS PROGRAM (suggestion from the article)
  Win+R -> services.msc -> "AMD External Events Utility" -> Stop, Startup type "Disabled".

DISCLAIMER
Unofficial workaround, not affiliated with AMD and not reviewed or endorsed by AMD. Use at your
own risk, without warranty or liability of any kind (see LICENSE.txt). AMD, Radeon, and Smart
Access Memory are trademarks of Advanced Micro Devices, Inc. Once AMD releases a fixed driver,
the scheduled task lifts the protection automatically; everything can then be removed using
REMOVE.cmd.
