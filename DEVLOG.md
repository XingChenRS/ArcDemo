# DEVLOG

## Scope Reset

The active tree was reset to a smaller sideload-only branch.

Kept:
- chart speed retime via `Gameplay.update`
- visual speed warp via `gettimeofday`
- basic music-player seek
- floating UI and plist config
- judgement parameter UI for future design work

Removed from the active tree:
- split build variants for privileged install modes
- main-binary payload insertion experiments
- runtime `__TEXT` patch attempts
- static judgement patch helper
- audio speed control and drift-correction experiments
- note replay / scorekeeper reset experiments
- duplicate legacy projects

Open research:
- judgement-window design that avoids runtime `__TEXT` patching and fragile
  main-binary surgery
- read-only call-chain analysis around `sub_100870FD0`
