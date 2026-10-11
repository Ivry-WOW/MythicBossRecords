' Runs MBR-Tools.ps1 (combat log import + update check) without a window. Used by the hourly task.
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\MBR-Tools.ps1"" -Action auto", 0, True
