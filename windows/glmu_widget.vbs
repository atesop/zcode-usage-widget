' GLM usage widget launcher - hides the console window
' Usage: double-click this file, Desktop shortcut, or Startup shortcut
' Note: WSL must be running (the widget queries data through wsl.exe anyway).
'       At Windows logon WSL may start later, so wait for it (max ~60s).
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
' The ps1 sits next to this launcher; derive its path from this script's own
' location so the repo can live under any WSL distro/user/path without edits.
target = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "glmu_widget.ps1")
For i = 1 To 30
  If fso.FileExists(target) Then Exit For
  WScript.Sleep 2000
Next
If Not fso.FileExists(target) Then
  MsgBox "glmu_widget.ps1 not found next to this launcher: " & target, vbCritical, "glmu-widget"
  WScript.Quit 1
End If
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & target & """", 0, False
