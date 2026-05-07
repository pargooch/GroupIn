# GroupIn MagSafe Module

A standalone communication accessory that attaches to the iPhone via MagSafe
and gives the GroupIn app long-range, fully offline group communication —
voice, chat, position, and (eventually) media — without depending on cell
signal, Wi-Fi access points, or Apple's first-party radios.

The link between the module and the iPhone is not yet committed. BLE is
the leading candidate (lifecycle, range, power), but Wi-Fi peer-to-peer,
MFi-authenticated connections, or wired contacts inside the MagSafe
puck are all open. Section 4 below assumes BLE because that drives the
strongest background story; if a different link is chosen, the
lifecycle implications need to be re-evaluated.

**Status: exploratory / future product.** Hardware not yet prototyped. The
app architecture is being shaped so that this module becomes a drop-in
transport when it ships.

---

## 1. Concept

The MagSafe Module **is** the radio. It is not an antenna extension for
the iPhone, not a hack of the iPhone's built-in Wi-Fi, and not a passive
component. It is a self-contained device with its own transceiver, its
own antenna, its own battery, and its own firmware. It physically
attaches to the back of the iPhone via MagSafe magnets, charges via the
MagSafe coil, and pairs to the iPhone over BLE.

Two radio chains live inside the module:

- **Long-range link (module ↔ module).** Custom 2.4/5 GHz protocol over
  the unlicensed ISM bands. This is what carries group traffic between
  nearby members. Range varies by power, antenna design, and environment.
- **Local link (module ↔ iPhone).** Undecided. Candidates:
  - **BLE GATT** — standard, well-supported, strongest background
    lifecycle story, modest bandwidth.
  - **Wi-Fi peer-to-peer** (the iPhone joins a Wi-Fi network the module
    creates) — much higher bandwidth, but consumes the iPhone's main
    Wi-Fi radio and is harder to keep alive in the background.
  - **MFi-authenticated channel** — tighter integration with iOS,
    licensing cost and approval cycle, possible audio path improvements.
  - **Wired contacts inside the MagSafe puck** — best fidelity, but
    requires an MFi-class connector and limits compatibility.
  Decision deferred until prototype evaluation.

The architectural pattern is the same as Garmin inReach, goTenna,
Beartooth, and Apple's own AirPods: a phone-paired accessory that owns
the specialty radio while the phone provides the user interface.

---

## 2. Form factor

- MagSafe-attachable disc, sized similar to a MagSafe wallet.
- Thin enough to remain pocket-friendly when attached.
- Internal Li-Po battery; charges from the iPhone's MagSafe coil when
  the phone is docked at a charger, or directly from any Qi pad.
- Magnet array follows the standard MagSafe 15-magnet pattern for
  consistent attachment.
- Designed to be visible — a status object as much as a tool. Color
  options aligned with the app's group categories (festival pink, trip
  blue, nature green, etc.) are an option.

---

## 3. App integration

The app talks to the module via BLE GATT. A `RadioModuleTransport`
implements the same `PresenceAndMediaTransport` protocol that
`CloudKitTransport` and `iPhoneBLEAdvertTransport` implement. The
dashboard, member list, map, and message UI are unaware of which
transport is delivering data — they consume the merged peer state.

```
CloudKitTransport          online        unlimited range
iPhoneBLEAdvertTransport   offline       ~30m (built-in BLE only)
RadioModuleTransport       offline       hundreds of meters to km
```

When the module is paired and connected, the app gains:

- Position updates from peers in module-mesh range
- Incoming chat messages
- Push-to-talk audio frames
- Voice session control

When the module is absent, the app falls back to the other transports.

The protocol (defined in `Services/CloudKitServicing.swift` and to be
extended) declares per-transport **capabilities** so the UI knows which
features are available with which peer. Voice button is enabled when at
least one transport that reaches that peer can carry voice.

---

## 4. Background lifecycle — the unlock

This is the single biggest win the hardware delivers to the software.

iOS aggressively limits background BLE for arbitrary scanning and
advertising, but it treats **paired BLE peripherals with active
connections as first-class accessories**. Specifically:

- The `bluetooth-central` background mode allows the app to maintain a
  long-lived connection to a paired peripheral.
- State preservation/restoration relaunches the app from a terminated
  state when the paired peripheral has data.
- Subscribed GATT characteristics push notifications to the app on every
  inbound packet. iOS wakes the app, runs the handler, then suspends.

This is the same lifecycle Apple Watch, AirPods, fitness sensors, and
MFi accessories use. It is well-trodden, well-supported, and not subject
to the throttling that handicaps software-only offline approaches.

Effects:

- The user keeps the phone in their pocket all day. The module
  continues exchanging data with peers. The app receives updates and
  fires local notifications when warranted.
- No "dashboard must be open" caveat.
- No iBeacon-style 10-second wake windows.
- No MPC-style 30-second session timeouts after backgrounding.

The module's BLE link is the lifecycle hook that makes long-running
offline operation practical on iOS.

---

## 5. Capabilities

| Capability | Notes |
|---|---|
| Position broadcast | 1 Hz per peer trivially supported |
| Push-to-talk audio | Opus 16–32 kbps, ~50–100 ms latency |
| Continuous voice (call mode) | 1:1 reliable; 4–6 way feasible with mesh routing |
| Text chat | Trivial bandwidth |
| Image attachments | Slow but works — seconds for tens of KB |
| Video | Stretch goal; low fidelity only |

Voice and chat are the headline capabilities that built-in iPhone radios
can't deliver offline at the same range.

---

## 6. Range and adaptive power

User-adjustable power within firmware-enforced regional legal limits.
The paired iPhone provides location; the module looks up the legal
ceiling for that jurisdiction (FCC Part 15, CE/ETSI, IC, etc.) and
exposes a slider that maxes out at the regional cap.

Realistic ranges with optimized hardware:

| Configuration | Range |
|---|---|
| Omnidirectional, low power (interference-friendly) | 200–500 m LOS |
| Omnidirectional, max legal power | 500 m – 1 km LOS |
| Mesh-forwarded (5–10 nodes) | 1.5 – 5 km network span |

Use cases by range:

- Festival site, large concert: covered comfortably by direct link plus
  modest mesh.
- University campus, museum complex: direct link is enough.
- Long hike with the group spread over a trail: mesh forwarding extends
  the network across the natural chain.
- Cross-city coverage: not in scope. That's a sub-GHz product (LoRa
  variant — see section 9).

---

## 7. Mesh networking

The module's firmware handles mesh routing autonomously. The app never
sees routing details — it sees a peer list with associated capabilities
and freshness indicators.

Mesh design choices to commit to during firmware development:

- Each module has a stable per-group address derived from the membership
  UUID.
- Encryption keys per group, derived from the invite code (HKDF or
  similar). Modules ignore traffic from other groups at the radio layer.
- Routing protocol: source routing or distance-vector, kept lightweight
  to fit constrained microcontroller resources.
- Audio path: route through fewest-hops; voice has hard latency budget
  so excess hops drop the call back to PTT mode.
- Position updates: relaxed routing constraints, OK to take longer paths.

---

## 8. Identity, encryption, provisioning

The app provisions the module at pairing time and on group join:

- "You're a GroupIn module bound to this phone."
- "Join group X: here's the channel ID, here's the encryption key,
  here's your member ID."
- Module derives its own short address from the member ID.

After provisioning, the module operates autonomously. The phone never
sees plaintext traffic from other groups — encryption is enforced at
the radio layer, not in the app.

When the user leaves a group, the app sends a "leave" command and the
module purges that group's keys from its memory.

When the module is unpaired or wiped, all keys go.

---

## 9. Distribution strategy

Three viable paths, ranked by capital risk:

**Option A — Open the GATT spec, ecosystem builds the hardware.** Publish
the module's protocol as an open specification. Anyone (a hobbyist with
ESP32-C6 hardware, a partner ODM, a downstream company) can build a
module that the GroupIn app recognizes. Lowest risk, lowest direct
revenue, preserves all optionality.

**Option B — Partner with an ODM, brand the result.** Specify the design;
contract a Chinese/Taiwanese ODM to manufacture; sell under the GroupIn
brand. Medium risk, medium reward. Capital required for inventory and
certification but no in-house factory.

**Option C — Vertical hardware company.** Design and manufacture in-house.
Highest margin if it works; goTenna and Beartooth are warnings that
even good execution doesn't guarantee a market in this category. High
risk.

**Recommended: A first, with the option to escalate to B if the open
ecosystem demonstrates demand.** The architectural prep is the same for
all three paths — protocol layer, GATT spec, capability negotiation —
so the decision can be deferred until the app has shipped and the user
base has indicated whether they'd buy the hardware.

A possible variant: a sub-GHz **long-range edition** of the module
using LoRa or similar in the 868/915 MHz bands. Sacrifices voice and
high-bandwidth for kilometers of single-hop range. Same app, same
protocol, different physical layer. Would address the wilderness /
expedition use cases that 2.4/5 GHz doesn't reach.

---

## 10. Cost target and manufacturing approach

**Stated build target: ~$3–4 per unit at 100 units, with all engineering
done in-house.**

Sourcing assumption: Chinese / Taiwanese / Korean component supply, hand
or low-volume PCBA, owner-supplied design and firmware.

This target is aggressive and depends on:

- Self-sourced or surplus components for the core radio SoC, battery,
  PCB, and magnets.
- Self-printed or self-machined enclosures (no tooling).
- Hand assembly of the first batch.
- No third-party engineering, ID, or firmware contracting.
- No certification fees in the per-unit number (those are NRE, separate).
- No retail packaging, no marketing photography, no fulfillment
  logistics.

The number reflects **direct component spend for an internally-built
prototype run**, not "fully loaded retail-ready cost." Items deliberately
not included in the per-unit target:

- FCC, CE, IC certification fees (~$10K–30K combined, one-time)
- Bluetooth SIG qualification (~$4K–10K, one-time)
- Battery transport and safety certs (~$3K–10K, one-time)
- Tooling (skipped at 100 units; required at scale)
- Engineering labor (the owner's time, valued at zero in this scope)

When the module moves toward sellable production (post-prototype), the
per-unit cost rises with certification, packaging, and proper assembly.
Realistic production-run costs at low thousands of units are in the
$30–80 per-unit range fully loaded.

The $3–4 prototype target is therefore **valid for an internal-batch
proof-of-concept** — units to put in friends' hands and validate the
radio + firmware + app integration. It is not the right number to plan
a retail product around. Both numbers are real; they describe different
stages.

---

## 11. Architectural prep — what the app commits to now

To keep the module path open without committing to building it, the
following commitments are baked into the BLE phase of app development:

1. **`PresenceAndMediaTransport` protocol** with capability negotiation.
   Each transport declares what it can carry: position, chat, voice,
   video. Per-transport timing constraints (slow lane vs. fast lane).
2. **Compact binary wire format for member updates**, not Codable JSON.
   Small enough to fit a future radio's airtime budget — ~16–32 bytes
   per location update via varint encoding.
3. **Capability-aware UI** on the dashboard. Voice button greys out
   when no available transport supports voice for that peer. The "via
   X" indicator surfaces which transport carried each peer's last
   update.
4. **Module discovery hook.** App scans for known service UUIDs at
   launch; if a paired module is present, instantiate the
   `RadioModuleTransport` automatically. Hot-pluggable.
5. **Per-transport publish throttling.** Each transport advertises its
   preferred update interval. The publishing layer respects the
   slowest transport's budget when broadcasting.
6. **Draft GATT service specification.** A living document describing
   the GATT services, characteristics, and packet formats the module
   exposes. Even unimplemented, this is the contract the eventual
   hardware (own, partner, or third-party) implements.

None of these expand the BLE-phase work meaningfully. They are mostly
matters of being deliberate about protocol shape during work that's
already on the roadmap.

---

## 12. Open questions / things to validate

Items to resolve before the module moves from exploratory to planned:

- **Radio chipset choice.** Custom 2.4/5 GHz protocol on commodity
  Wi-Fi silicon (ESP32-C6, nRF7002, similar) vs. proprietary RF MCU vs.
  dual-band module. Affects cost, certification, and firmware effort.
- **Phone link transport.** BLE GATT vs. Wi-Fi peer-to-peer vs. MFi
  authenticated channel vs. wired-contacts. Driven by bandwidth needs
  (voice/video) and background lifecycle requirements. Each has
  trade-offs in cost, complexity, and iOS integration depth. To be
  decided during prototype evaluation.
- **MFi vs. non-MFi.** MFi gives authenticated MagSafe handshakes and
  tighter iOS integration but adds licensing cost and approval cycle.
  Default: non-MFi for prototype, re-evaluate once the product is real.
- **Antenna design.** PCB trace antenna vs. external chip antenna vs.
  flexible printed antenna. Driven by enclosure ID and target range.
- **Voice codec.** Opus is the obvious pick. Tune for latency over
  fidelity; PTT is the primary modality.
- **Mesh routing protocol.** Pick something proven (BATMAN-adv,
  802.11s-derived, custom source-routing). Latency-aware.
- **Power budget at adaptive max.** Does max-legal TX power blow the
  thermal budget of a thin enclosure? If yes, throttle in firmware.
- **Sub-GHz "long-range edition".** Same app, different module. Plan a
  Phase 2 product or skip entirely?
- **Certification path.** FCC self-certify route vs. third-party test
  lab. Cost and timeline differ significantly.
- **Cost validation.** The $3–4 prototype target assumes specific
  component sourcing. Confirm with a real BOM line-item review before
  ordering parts.

---

## 13. Roadmap fit

This module is **not** in the v1 GroupIn release. The architectural
prep above is. The order:

1. Ship the app with CloudKit transport (current state).
2. Add the iPhone-native BLE advertisement transport (Phase 1 of the
   offline plan in TECH.md).
3. Add the gradient-compass and iBeacon wake (Phases 2–3).
4. Watch Over Me mode (continuous backgrounded CloudKit publishing).
5. **Optional:** Build a small batch of MagSafe Modules. App
   automatically picks them up via the discovery hook.
6. **Optional:** Decide between the open-spec, ODM, or in-house paths
   based on demand signal from app users.

The prep work in section 11 is on the path regardless of whether the
module ships. The app gets cleaner architecture; the module becomes a
drop-in option if it ever happens.

---

*This document captures the design as discussed. It is forward-looking;
the hardware does not exist yet, and the cost target reflects an
internal prototype scope rather than a sellable product.*
