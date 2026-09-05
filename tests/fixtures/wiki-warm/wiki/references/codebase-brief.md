---
title: greet codebase brief
category: reference
verified-against: {{HEAD}}
covers:
  - src/
  - tests/
volatility: hot
updated: 2026-09-01
tags: [greet, brief]
summary: One greeting script and one proof script.
---

# greet codebase brief

## Entry points & module map

- `src/greet.ps1` is the whole application: a `-Name` parameter and one `Write-Output`.

## Data flow

Arguments in, one line out. There is no state.

## Build / run / test

- Run: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File src/greet.ps1 -Name loop`
- Test: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/greet.tests.ps1`

## Invariants & gotchas

- The test harness compares trimmed output case-sensitively.

## Hot files

- `src/greet.ps1` the greeting
- `tests/greet.tests.ps1` the proof

## Pointers

- [decisions](../decisions.md)
