# bin/

The native scoring helper lives here, one slot per platform. It is **not**
committed — build it with `lightroom/scripts/build-scorer.sh`, which produces a
universal (arm64 + x86_64) `macOS/featured-scorer` and ad-hoc signs it.

`windows/` is a placeholder. The scoring is Apple's Vision framework, so there is
no Windows build; the plug-in loads there and says so rather than failing partway
through a scan.
