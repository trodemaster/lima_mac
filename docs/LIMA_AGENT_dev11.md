# Lima Agent Task: dev.11 — Add `cliclick-accessibility` preset

## Background

Through dev.6–dev.10, every approach to pre-seeding `kTCCServiceAppleEvents` via disk patching has failed — tccd unconditionally deletes these entries at first boot. The new approach uses `cliclick` (installed via MacPorts) with `kTCCServiceAccessibility` (which DOES survive disk patching) to auto-approve the TCC consent dialog by simulating a Return keypress when it appears.

## What needs to change in Lima source

**File:** `pkg/guestpatch/macos/tcc_darwin.go`

Add one new entry to the `tccPresets` map:

```go
// cliclick-accessibility: grants the cliclick CLI tool Accessibility permission so it
// can send synthetic keyboard events to the GUI session. Used in configure.sh to
// auto-approve the TCC consent dialog ("sshd-keygen-wrapper wants to control Finder")
// by pressing Return (the Allow button default) when UserNotificationCenter appears.
// csreq is nil because cliclick is not Apple-signed; path-based entries with nil csreq
// skip code-signing validation (same pattern as lima-guestagent-full-disk-access).
"cliclick-accessibility": {
    {
        service:     "kTCCServiceAccessibility",
        client:      "/opt/local/bin/cliclick",
        clientType:  1,   // path-based (MacPorts installs to /opt/local/bin/)
        authValue:   2,   // allow
        authVersion: 1,
        csreq:       nil, // NULL — not Apple-signed; binary changes on port updates
    },
},
```

## Version bump

Bump to `2.1.0-dev.11` in the Portfile. Push to trodemaster/lima.

## Why this works

- `kTCCServiceAccessibility` entries in the system DB survive first boot — confirmed by dev.9 (Terminal's Accessibility entry persisted while AppleEvents was deleted)
- cliclick uses CGEvent to post keyboard events to the frontmost application; when running in gui/501 context via `launchctl asuser 501`, events target the TCC dialog
- The consent dialog for AppleEvents is hosted by `UserNotificationCenter`; when dismissed via Return (the Allow default button), tccd records a genuine `auth_reason=3` user-consent entry that persists permanently

## Critical: remove AppleEvents presets from YAML files

The `terminal-apple-events` and `sshd-apple-events-finder` presets must be **removed** from all YAML files. This was discovered during dev.11 testing:

When tccd processes a pre-seeded AppleEvents entry in the system DB at first boot, it writes a **deny record** (auth_value=0, auth_reason=9) to the user DB, regardless of whether it keeps or deletes the system DB entry. That deny record silently blocks future requests without showing any dialog — so cliclick never gets a dialog to approve.

Without the pre-seeded AppleEvents entry, tccd has nothing to process at first boot and writes no deny. The first time osascript triggers the AppleEvents request, tccd shows the consent dialog. cliclick detects `UserNotificationCenter` and presses Return to approve it. tccd writes a genuine `auth_reason=3` allow entry that persists permanently.

**The YAML files have already been updated** to remove `terminal-apple-events` and `sshd-apple-events-finder`. The Lima binary does not need changes to the tccPresets map for this (those presets can stay in the code for potential future use), but the YAML configs must not reference them.
