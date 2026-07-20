# PeaversRaidTimings

[![AddonSentry](https://addonsentry.io/api/public/repos/peavers-warcraft/PeaversRaidTimings/badge.svg)](https://addonsentry.io/dashboard/peavers-warcraft/PeaversRaidTimings)

A World of Warcraft addon that replays one top-ranked player's actual cast timeline for your boss and spec, and calls it out as the fight runs. It is the ghost car from an arcade racer: their run, on your screen, ticking against your pull. Import and use — there is nothing to write and nothing to edit.

Two addons already own half of this each: Northern Sky Raid Tools announces cooldowns but doesn't know which spell the note means, and Method Raid Tools tracks the note but doesn't announce it. This is the small single-purpose intersection.

## Status

**Skeleton.** Structure and wiring are in place and the addon loads, but it is not feature-complete and there is no released data addon publishing ghosts yet. The addon requires the ghost API (`GetGhost`/`GetCasts`) and stands down with a message against an older data addon.

## Features

<!-- peavers:features -->
- Replays ONE named top-ranked player's real cast timeline for your boss, difficulty and spec — not an average of many
- Names who you are following, with their rank and score, above the list: "Following: Awaken - rank 1 - 252k HPS"
- Shows how far ahead or behind that player you are on every cast you match, and across the run so far
- A spoken lead-in warning a few seconds ahead, then the cast call, via text-to-speech with a sound fallback
- Marks each cast hit or missed against the run you are following
- `/prt test <encounterID>` replays a whole fight against a synthetic clock, out of combat
- Works for dps, healers and tanks alike
- Display and audio settings only; the run you are following is read-only by design
<!-- /peavers:features -->

## Usage

<!-- peavers:usage -->
1. Install PeaversRaidTimings together with PeaversRaidTimingsData
2. Position the cast list with a drag, and size it under `/prt config`
3. Pull the boss — the list starts on `ENCOUNTER_START` and clears on `ENCOUNTER_END`
4. Race the ghost: the header names who you are following, and each cast you press shows your delta against them
5. `/prt test 2905` replays that encounter out of combat so you can check the list, the timing and the audio solo
6. `/prt status` reports who is being followed, where their log came from, and how you are doing against it
<!-- /peavers:usage -->

<!-- peavers:custom -->
## Commands

| Command | What it does |
|---|---|
| `/prt` | Toggle the cast list |
| `/prt test <encounterID> [difficultyID] [speed]` | Replay a ghost against a synthetic clock, out of combat |
| `/prt stop` | End a replay |
| `/prt status` | Data, spec, clock, ghost attribution and cast-tracking diagnostics |
| `/prt config` | Open settings |

## How it works, and what it cannot do

**It is one person's run, not a consensus.** For each boss, difficulty and spec, the data addon ships a single ranked log: who it was, which report and fight it came from, their rank, metric and score, and their casts in order with a time from the pull. That is deliberate. Top players do not converge on cast times — measured across ~50 healer logs, a given "consensus" time was hit within ±3s only about 30% of the time — so a median timeline describes a performance nobody actually gave. A ghost has no agreement problem to solve, so there is no confidence score, no spread and no quality filter anywhere in this addon. Don't add one.

**Because it is a named person's run, their name travels with it.** The list header, `/prt status` and the replay banner all carry the attribution. That is both courteous and useful: knowing you are chasing rank 1 at 252k HPS is context for why the timings look the way they do.

**Cast times are absolute from the pull.** On 12.0+ an addon can no longer detect a boss phase transition: `COMBAT_LOG_EVENT_UNFILTERED` raises `ADDON_ACTION_FORBIDDEN` on registration, boss unit events are blocked during encounters, `C_EncounterTimeline`'s `spellID` is secret, and `UnitHealth("boss1")` no longer reports usefully. BigWigs and DBM cope by fingerprinting abilities from rounded timer durations with per-boss state machines — real, but disproportionate here.

**So the ghost drifts on an off-pace pull.** A fight that runs long desyncs, exactly like every hand-written note does. What survives and works is `ENCOUNTER_START`/`ENCOUNTER_END` for the clock, and `UNIT_SPELLCAST_SUCCEEDED` filtered to the player for what you actually pressed — which is also what makes the delta possible.

**Timings are read-only.** There is no in-game editing surface and nothing timing-shaped is written to SavedVariables — `PeaversRaidTimingsDB` holds display preferences only. That is not tamper-proofing: anyone can edit the Lua on disk, and it would be dishonest to imply otherwise.

**Where the data comes from.** Ghosts are transcribed from top-ranked logs on lorrgs.io and shipped in [PeaversRaidTimingsData](https://github.com/peavers-warcraft/PeaversRaidTimingsData), refreshed weekly. Only spell IDs are shipped; names and icons resolve client-side, so the list is correct in every locale.

## Development

`/prt test` is the primary development loop, not a debug afterthought. It drives the production code path end to end — same `Timeline`, same `Announcer`, same `CueList`, same `CastWatch` — with the clock supplied by a ticker instead of the pull. Iterating on the announcer without it means organising a raid.

Validation (three tiers: luacheck, LuaLS, frame names):

```sh
cd PeaversRaidTimings
../wow-api/scripts/lint.sh      # luacheck alone
../wow-api/ci/run-validation.sh # all three tiers
./local_deploy.sh               # copy into the live client
```

`src/Core/Timeline.lua` touches no WoW API and is the unit-testable core. Keep it that way — if a change there needs `GetTime()`, `C_Spell` or a frame, it belongs in `Encounter`, `CastWatch` or `CueList` instead.
<!-- /peavers:custom -->

## Installation

### Recommended: PeaversUpdater

Download and install [PeaversUpdater](https://github.com/peavers-warcraft/PeaversUpdater/releases/latest), the desktop updater for the whole Peavers collection. It installs PeaversRaidTimings together with its required dependencies and delivers updates before they reach CurseForge.

### Alternative: CurseForge

Not yet published — the CurseForge project is created in a later staging step.

### Manual

1. Download the latest release
2. Extract into `World of Warcraft/_retail_/Interface/AddOns/`
3. Ensure `PeaversRaidTimingsData`, `PeaversCommons` and `PeaversConfig` are installed alongside it

## Support

- [Discord](https://discord.gg/5BWCMB2e4W)
- [Issues](https://github.com/peavers-warcraft/PeaversRaidTimings/issues)
