---
name: windows-ui-inspector
description: Analyze authorized Windows desktop applications by inventorying executable metadata, UI Automation elements, Win32 controls, and optional child or modal dialogs, then produce reusable control maps for later workflow automation. Use for native Windows GUI inspection; do not use for browser DOM automation or to execute destructive application actions.
---

# Windows UI Inspector

Build an evidence-based interface map for an authorized Windows desktop application. Prefer stable window ancestry, control IDs, class names, and automation properties over screen coordinates.

## Workflow

1. Resolve the exact executable and output directory. If omitted, use `outputs/<executable-name>-ui-analysis` in the current task.
2. Run `scripts/inspect-app.ps1` for the main window. Launching a GUI may require host approval.
3. Treat an absent signature or changed hash as a warning, not automatic failure.
4. Review `secondary_candidates`. Before passing `-SecondaryControlId`, obtain explicit approval to activate that control.
5. For approved secondary scans, pass `-SecondaryControlId <id> -ConfirmSecondaryOpen`. The script closes discovered secondary windows without accepting settings and closes only a process it started.
6. Use `-DeepStrings` only when file formats, configuration files, update endpoints, or possible CLI behavior matter. Treat strings as clues, not verified interfaces.
7. Deliver the report and maps. Explain that HWND values change between launches and IDs can repeat under different parent dialogs or tab pages.

## Required safety behavior

- Main-window inventory is read-only.
- Never set text, select a device, accept settings, erase, program, flash, update firmware, or execute another domain action during analysis.
- Opening a secondary window is the only permitted click-like action and requires approval immediately before execution.
- Prefer a visible `Cancel`/`取消` button with ID `2` when closing a secondary dialog; otherwise send `WM_CLOSE`.
- On failure, stop only the exact PID started by the scan. Never terminate by process name.
- Scope every secondary control by its parent HWND or page ancestry. Never assume a control ID is globally unique.

## Commands

Main scan:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/inspect-app.ps1 `
  -ExecutablePath 'C:\Path\Application.exe' `
  -OutputDirectory 'C:\Path\outputs\Application-ui-analysis'
```

Approved secondary scan:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/inspect-app.ps1 `
  -ExecutablePath 'C:\Path\Application.exe' `
  -OutputDirectory 'C:\Path\outputs\Application-ui-analysis' `
  -SecondaryControlId 1000 -ConfirmSecondaryOpen
```

For output fields and interpretation, read [references/output-schema.md](references/output-schema.md).

