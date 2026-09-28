# Plans

Numbered plans are the record of feature and design work: what was proposed, what was
decided, and why. `active-plans.md` is the index: what is being worked on now, what is
parked and where it stands, and what is done.

Plans 001-016 were imported from redfish_gl_zig on 2026-09-28. Each carries a note under
its title with its status in this repo; the body is kept as written, so file and API
references in it are to redfish_gl_zig unless noted. Plan 000 is the WebGPU port itself.

## Files

- `NNN-descriptive-title.md`: one plan per feature or design question, numbered in the
  order they were started.
- `active-plans.md`: the index (active, parked, completed) and session notes.
- `backlog.md`: future features grouped in clusters; ideas that aren't plans yet.
- `*_notes.md`: working notes that feed a plan (e.g. `animations_state_machine_notes.md`).
- Design notes for implemented work are in `../designs/`, reviews in `../reviews/`.

## Plan Format

- **Title** and, for imported plans, the note on their status here.
- **Status**, and dates.
- **Context / Overview**: what and why, with a bounded scope.
- **Design**: the approach, and alternatives considered.
- **Phases**: tasks as checkboxes.
- **Notes & Decisions**: dated entries; decisions with their reasons.

## Workflow

### Starting a session
1. Read `active-plans.md` for the current focus.
2. Open the active plan: next tasks and the latest notes.

### During work
1. Check off tasks: `- [x]`.
2. Add dated notes for discoveries and decisions, with the reason.
3. Out-of-scope ideas go to `backlog.md` or a new plan, not into the current one.

### Switching focus
Plans can be parked and resumed without losing context:
1. In the plan being parked, add a dated note: **where it stands** (what's done, what's in
   progress, anything half-finished) and **next step**.
2. In `active-plans.md`, move it to Parked with a one-line summary of the same.
3. Make the other plan active, or start a new numbered plan for a new idea.

Resuming is the reverse: read the parked note, move the plan back to Active.

### Finishing a plan
1. Tick the tasks and note the outcome.
2. Move it to Completed in `active-plans.md`.
3. A `CHANGELOG.md` entry and a commit, as for any change.

## Status Indicators

- 🔄 **Active**: being worked on.
- ⏸️ **Parked**: started or discussed, waiting; the plan says where it stands.
- 📋 **Planned**: ready to start.
- ✅ **Completed**
- ❌ **Cancelled**: no longer relevant or superseded (say by what).
