# Output schema

The inspector writes four stable deliverables and optional evidence:

- `analysis-report.md`: findings, warnings, counts, candidates, and automation guidance.
- `main-window-controls.json`: executable metadata, UI Automation tree, Win32 controls, and secondary candidates.
- `secondary-windows.json`: opened top-level or modal windows and descendants; empty when not requested.
- `control-map.yaml`: parent HWND, control ID, class, text, state, suggested interface, and risk.
- `binary-string-clues.json`: optional static clues produced by `-DeepStrings`.

## Interpretation rules

- `hwnd` and `parent_hwnd` are run-specific evidence, not persistent locators.
- Prefer `(window title/class, parent/page ancestry, control_id, class_name)` as the locator tuple.
- IDs of `-1` are labels or group boxes and are not unique locators.
- Duplicate IDs are expected across tab child dialogs. Resolve the active page first.
- UI Automation patterns are preferable when present. Classic MFC applications may expose no patterns even when Win32 messages work.
- Suggested interfaces are inferred from class names and still require workflow validation.
- `risk: destructive` means the text suggests erase, program, flash, update, delete, reset, or write. Never invoke it during analysis.
- Static strings may reveal extensions or internal names but do not prove a public CLI or API.

