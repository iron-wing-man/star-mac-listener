# Code Review — star-mac-listener

**Reviewer:** Claude Opus 4.7
**Date:** 2026-10-01
**Scope:** macOS Swift menu-bar wake-word listener (AVFoundation + Sherpa-ONNX KWS), lifecycle scripts, model download, HTTP client to `star-service`.
**Tone:** Honest. This is the smallest project in the workspace and, interestingly, one of the better-documented. The design is good; the security surface is naive.

**Review Baseline (HEAD at review time):**
- Commit: `436244b5dfaeb87356980a5b192ba2a8c6d80161` (`436244b`)
- Author: Jasper <jasper.wkuk@gmail.com>
- Date:   2026-09-18 19:11:42 +0100
- Subject: `feat(kws): remove 星仔 and retain Stella as the exclusive wake word`
- Next reviewer: start the diff from this SHA (`git log 436244b..HEAD`) to see what has changed since.

> **Executive verdict:** The audio pipeline, documentation, and performance tuning are clearly the work of someone who knows what they're doing. The networking and distribution story is where this would get owned on a hostile WiFi: cleartext HTTP to the backend, `NSAllowsArbitraryLoads=true`, spoofable identity headers used in lieu of real auth, no model-download integrity check, and an `uninstall.sh` that is one unset variable away from `rm -rf /*`. None of this is hard to fix; all of it should be fixed before any machine outside a trusted LAN runs this.

---

## 1. Language & Framework

Swift 5 + AppKit + AVFoundation menu-bar daemon (`LSUIElement=true`) + external `sherpa-onnx` subprocess.

**Good:** Native Swift is the right tool for mic access, Core Audio semantics, and TCC permissions.
**Not good:**
- **No build system beyond `swiftc` in `scripts/build_app.sh:~25`.** No `Package.swift`, no Xcode project. Means no SwiftPM dependency management, no XCTest hookup, no CI reproducibility.
- Heavy reliance on shell tools (`stdbuf`, `codesign`, `ffmpeg`, `sherpa-onnx`) with no documented minimum versions.
- No test target *at all*. Not XCTest, not Quick/Nimble, not even a smoke test on a canned WAV.

**Fix direction:** Convert to a Swift Package with an app target and a test target. This single change unlocks DI-friendly refactors and CI.

---

## 2. Audio Pipeline & Performance

Headline: this part is well done. The RMS-based silence detector, tunable timeouts, and Zipformer KWS integration are solid choices and documented in `ARCHITECTURE.md`.

### 2.1 `stopRecording()` race against in-flight tap callback — MEDIUM
`src/AudioCaptureService.swift:~147`
```swift
if engine.isRunning {
    engine.inputNode.removeTap(onBus: 0)   // can race with the running tap
    engine.stop()
}
```
`[weak self]` in the tap block mitigates self-reference leaks but does not guarantee the audio HAL callback isn't mid-flight. Under contention you can get stale buffer references.
**Fix:** `engine.stop()` first (which quiesces the graph), *then* `removeTap`. Serialize both on a dedicated serial queue.

### 2.2 No handler for device change / configuration change — MEDIUM
`src/AudioCaptureService.swift:~28` reads `inputNode.outputFormat(forBus: 0)` once. Unplug/replug of a USB mic or default-input switch mid-session silently keeps the old format; records garbage frames.
**Fix:** Observe `AVAudioEngine.configurationChangeNotification` and restart the capture graph.

### 2.3 RMS can go NaN — LOW
`src/AudioCaptureService.swift:~79-84` has no `isfinite(rms)` check. A pathological `frameLength` or all-zero buffer with a bad conversion produces NaN, and `rms > threshold` is always false for NaN. Silence detector then never fires.
**Fix:** `let rms = isfinite(raw) ? raw : 0`.

### 2.4 No PTS / frame-number tracking — LOW
`src/AudioCaptureService.swift:~88` blind-appends captured PCM. If the audio callback stutters (laptop lid, display sleep), there's no record of a gap. Backend STT then sees a slightly-wrong duration.
**Fix:** Record `AVAudioTime` with each append; log if deltas exceed expected buffer size.

**Verdict:** CPU/memory are impressively low. Lifecycle correctness is the weak point, not throughput.

---

## 3. Model Handling

### 3.1 No checksum verification on downloaded binary or models — HIGH
`scripts/download_deps.sh:~18-24` pulls the Sherpa-ONNX macOS binary and KWS model via plain `curl -SL -O` from GitHub release URLs. No SHA256, no signature, no pinning by commit.
**Fix:** Store a signed manifest (`model_manifest.sig`) with SHA256 of every artifact; verify after download; refuse to proceed on mismatch.

### 3.2 Model/binary versions string-pinned in a shell script — MEDIUM
`v1.13.8` and a dated model name are hardcoded. If GitHub rotates releases, the script breaks silently. Mirror artifacts to your own R2/S3 bucket with versioned keys and keep GitHub as a secondary source.

### 3.3 No LICENSE file — LOW
Sherpa-ONNX is Apache 2.0, but the KWS model's provenance and license are undocumented. Add a `THIRD_PARTY_LICENSES.md`.

### 3.4 No runtime validation of the launched binary — MEDIUM
`src/main.swift:~467-480` checks the binary exists but not: executable bit, code signature, version string, model magic bytes. On a system where someone replaced the binary, you launch an unknown.
**Fix:** `codesign -v -R="…"` + ONNX magic-byte check at startup.

---

## 4. IPC / Network to Backend

This is the weakest area of the project. Three large issues, several smaller ones.

### 4.1 Cleartext HTTP — **CRITICAL** (on hostile networks)
`src/StarApiClient.swift:~21, ~62, ~82` — every URL is `http://`. Audio PCM (PII), transcription URLs, and session responses travel in cleartext. On a shared or ARP-spoofed WiFi: trivial MITM.
**Fix:** HTTPS end-to-end. For LAN-only backends, use a self-signed cert with pinning via `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`.

### 4.2 `NSAllowsArbitraryLoads=true` — **CRITICAL**
`scripts/build_app.sh:~53-55` embeds this in Info.plist. It disables App Transport Security globally — not just for the local backend. Even if §4.1 is fixed, this would still accept any self-signed cert on any domain.
**Fix:** Remove `NSAllowsArbitraryLoads`. Use `NSExceptionDomains` scoped to your actual backend hostname, with `NSIncludesSubdomains=false`, `NSExceptionAllowsInsecureHTTPLoads=false`, and `NSPinnedDomains` for cert pinning (macOS 14+).

### 4.3 Spoofable identity via custom headers — HIGH
`src/StarApiClient.swift:~27, ~67-68` sends:
```
X-Response-IP: mac-listener
X-Real-IP:    mac-listener
```
This is not authentication — it's a client-named label the server trusts. Anyone on the network sends the same headers and the backend treats them as the Mac listener.
**Fix:** Per-device HMAC-SHA256 request signing with a pre-shared key *or* mTLS. Include a nonce + timestamp to prevent replay. Rotate keys per device.

### 4.4 Fixed-interval polling, no backoff — MEDIUM
`src/StarApiClient.swift:~72-103` — fixed `250ms` interval × 180 attempts over 45s. No exponential backoff, no jitter, no circuit breaker. When the backend is sick, you hammer it.
**Fix:** Start at `250ms`, double per attempt up to `2s`, add ±20% jitter.

### 4.5 Response URL reconstructed by string concat — MEDIUM
`src/StarApiClient.swift:~81-82`
```swift
let voiceUrl = URL(string: "http://\(config.starHost):\(config.starPort)\(voiceUrlString)")
```
If `voiceUrlString` is an absolute URL (attacker-controlled or spec-drift), this produces a malformed URL *or* fetches from the wrong host.
**Fix:** Parse with `URLComponents`; reject if `voiceUrlString` has a scheme or `..` traversal; require it be a leading-slash path.

### 4.6 Loose response parsing — LOW
`src/StarApiClient.swift:~39-53` returns `badResponse` on any JSON hiccup with no logging. Switch to `Codable` with a strict struct; log the raw body (sanitized) on decode failure. Right now, "server returned something weird" is invisible.

### 4.7 Timeouts hardcoded in code — LOW
45s overall timeout, 250ms poll interval, retry counts — all literals in `.swift`, not in `config.json`. Pull into config.

---

## 5. Security

### 5.1 ATS disabled — see §4.2. CRITICAL.
### 5.2 Spoofable headers — see §4.3. HIGH.

### 5.3 Keywords file shipped in plaintext — LOW
`config/keywords.txt` contains the phonetic wake words. Reverse engineers can tune acoustic adversarial examples against them. Not a show-stopper (nothing really is for a wake-word phrase in a bundle), but worth noting in the threat model.

### 5.4 Permissions handled, but failures invisible — MEDIUM
`LSUIElement=true` + mic/local-network permission denied = app runs silently with no audio and no network. No UI alert.
**Fix:** On startup, call `AVAudioSession.recordPermission()` (iOS pattern; on macOS use `AVCaptureDevice.authorizationStatus(for: .audio)`) and present an `NSAlert` with instructions if denied. Same for local-network.

### 5.5 Ad-hoc code signing — MEDIUM for distribution
`scripts/build_app.sh:~68` runs `codesign --force --deep -s -`. Fine for local dev; Gatekeeper will chew on it anywhere else. For distribution, use a Developer ID cert and notarize.

### 5.6 No sandbox entitlements — MEDIUM
App has unrestricted filesystem + network + subprocess spawn. If compromised (e.g. buffer overflow in the Sherpa-ONNX binary), blast radius is the user's entire account.
**Fix:** Enable sandbox; grant `com.apple.security.network.client`, `com.apple.security.device.audio-input`, and the specific subprocess inheritance you need. Expect this to be a day of work to fix the resulting failures.

### 5.7 Global hotkey registration unchecked — LOW
`src/GlobalHotKey.swift:~20-29` passes `config.hotKeyCode` straight to `RegisterEventHotKey` with no range check and no return-value check (`eventHotKeyAlreadyRegistered` is a real error you'll hit if two apps fight).
**Fix:** Validate key range (0–127 for US keyboard virtual key codes), log on registration failure.

### 5.8 Subprocess args — ACCEPTABLE
`src/main.swift:~471` uses `Process.arguments` (argv), so shell injection via `baseDir` is not a direct risk. Still, validate `baseDir` is under `Bundle.main.bundlePath` at startup.

---

## 6. Lifecycle Scripts

**`start.sh`** — safe, idempotent, correct quoting. ✅
**`stop.sh`** — safe, idempotent. Could add `pkill -P` for child cleanup. ✅

### 6.1 `uninstall.sh` has an `rm -rf` footgun — HIGH
`uninstall.sh:~11-12`
```bash
rm -rf "${BASE_DIR}/bin"/*
rm -rf "${BASE_DIR}/model"/*
```
If `BASE_DIR` is unset or empty (and `set -u` isn't on), this becomes `rm -rf /bin/*` or similar. User's day ruined.
**Fix:** Pick one:
- `rm -rf "${BASE_DIR:?BASE_DIR must be set}"/bin "${BASE_DIR:?}"/model`
- Add `set -euo pipefail` at the top of every lifecycle script.

### 6.2 No `set -euo pipefail` anywhere — MEDIUM
All three scripts and the download script are vulnerable to silent failures (e.g., curl 404, `tar` on a half-downloaded file). Add it unconditionally.

---

## 7. Config

`config/config.json` holds all tunables. Clean.

### 7.1 No validation of numeric ranges — MEDIUM
`src/StarConfig.swift:~18-21` — on decode failure, silently falls back to defaults. `starPort=-1` or `minRecordSec=0` happily accepted.
**Fix:** Validate after decode. If invalid, log *loudly* (not just `print`) and either fail or use defaults with a visible warning.

### 7.2 No hot reload — LOW
Config change requires app restart. Low value for a tool that restarts in <1s, but if you add remote-config later, you'll want this.

### 7.3 File permissions — LOW
`config/config.json` is likely world-readable. If `clientId` ever becomes a secret, store it in Keychain, not JSON. Document this in README.

---

## 8. Error Handling & Observability

### 8.1 Unstructured logging — MEDIUM
`print(...)` + append to `listener.log` with no timestamp or level. Emoji-rich. Easy to read, impossible to grep.
**Fix:** Use `os.Logger` (Apple's unified logging) with subsystem + category + level. Keeps the UI output pretty while giving you queryable logs.

### 8.2 Fixed 1s retry on follow-up turn — LOW
`src/main.swift:~418-430`. Exponential backoff capped at 30s; add jitter.

### 8.3 Generic network error messages — LOW
`throw StarError.networkError("Server returned \(code)")` tells the user nothing actionable. Enrich with `URLError.Code` details (DNS, timeout, cert, host unreachable).

### 8.4 No crash reporting — LOW
If Sherpa-ONNX segfaults, the user has no idea. At minimum, install an `NSUncaughtException` handler that writes a last-breath log line.

---

## 9. Testing

- **Zero tests.** No XCTest target, no mocks, no CI.
- `scripts/record_sample.sh` exists for manual verification — useful but not automation.

Minimum viable test plan:
1. `StarApiClientTests` — mock `URLSession` via `URLProtocol`; cover: URL construction, header set, 200/202/401/5xx handling, malformed JSON.
2. `AudioCaptureServiceTests` — inject the audio engine via protocol; cover RMS calculation on known buffers, silence detection timing, NaN handling.
3. `StarConfigTests` — invalid JSON falls back correctly, range validation (once added).
4. GitHub Actions `.github/workflows/ci.yml` running `swift test` on each push.

---

## 10. Docs vs Reality

**`ARCHITECTURE.md`** — genuinely excellent. The six invariants (stderr routing, max-active-paths, Cantonese phoneme alignment, TCC, code signing) are enforced in code at `src/main.swift:~491-495`. This is one of the better architecture documents I've seen for a project this size.

**`README.md`** — honest about CPU numbers (2–3% vs 103.7% for traditional ASR). Matches reality.

**`TROUBLESHOOTING.md`** — maps symptoms to actual code paths. Good.

**One discrepancy:** docs explain the macOS 15 Local Network permission dance in detail, but the app doesn't check for it or alert the user when denied. The docs are a workaround for a missing UI feature. Fix the code, not the docs.

---

## 11. Top 5 to Fix First

| # | Change | Effort | Why first |
|---|---|---|---|
| 1 | Enable HTTPS + remove `NSAllowsArbitraryLoads` + add cert pinning (§4.1, §4.2) | 4–6h | Audio PII is in cleartext today. Single highest severity. |
| 2 | Replace spoofable headers with HMAC-signed requests (§4.3) | 6–8h | "Identity" is currently a string label. Any LAN host can impersonate the Mac. |
| 3 | Fix `uninstall.sh` `rm -rf` + add `set -euo pipefail` to all shell (§6.1, §6.2) | 10m | Catastrophic footgun; trivial fix. |
| 4 | Checksum-verify downloaded binary + models (§3.1) | 1–2h | Supply-chain defense. GitHub releases can and do get repoints. |
| 5 | Add XCTest + CI (§9) | 1–2d | Nothing above is safely refactorable without tests. Pay this debt before paying any other. |

**Bonus quick wins:** NaN check in RMS (§2.3), hotkey range validation (§5.7), `os.Logger` migration (§8.1).

---

## Closing

This project has the opposite problem of most hobby code: the **architecture, performance, and documentation are strong**, and the **security + distribution** are the weak points. That's a much more fixable position to be in. Fix §4 and §5 and this becomes something you could put on a stranger's Mac with a clear conscience. Don't ship it on a trusted LAN assumption — "trusted LAN" is a convenient lie 100% of the time until it isn't.

The one thing I would protect fiercely during cleanup: don't rewrite the audio pipeline. The silence detector, the Zipformer tuning, the TCC understanding — these were earned. Change the perimeter, keep the heart.
