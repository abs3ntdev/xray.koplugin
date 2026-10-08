# Unified Implementation Plan: Source-Positioned Entity History (#131) & Offline Prefetch Horizon (#133)

## User Review Required

> [!IMPORTANT]
> **Unified Architecture**: Both Issue #131 (Full Pre-generation) and Issue #133 (Offline Prefetch Horizon) share the same underlying sequential chapter-state machine. Issue #133 specifies a horizon of $N$ chapters (1–5), while Issue #131 specifies a horizon to the end of the book.
>
> All design decisions from our `/grill-me` session have been incorporated:
> - **Entity Scope**: Full parity across Characters, Locations, and Terms/Worldbuilding with `visible_from` and `states`. Mentions are strictly capped to the reader's current position to shield quote spoilers.
> - **Granularity**: Hybrid chapter & page granularity. Primary unlock is by `chapter_index`, with `page_hint` gating if the reader is currently inside that introductory chapter. TOC chapters first, ~30-page virtual chapters for books lacking TOC.
> - **Extraction & Continuity**: Sequential prompts use a compact manifest containing the latest active description. The LLM returns delta-only state transitions as cumulative evolved summaries.
> - **Rate Limiting & Execution**: Background execution with inter-chapter cooldown/throttling to prevent API rate limits (429s). "Pre-generate Entire Book..." runs as a background task with milestone toast notifications.
> - **Dynamic Queueing & Jump Resilience**: If the reader skips across the book, the active in-flight chapter finishes and checkpoints, and obsolete pending chapters are discarded in favor of the new horizon.
> - **Resume Behavior**: Silently resumes remaining un-fetched chapters without re-scanning or overwriting existing cached chapters.
> - **Card UI**: Displays the clean active state with an optional "Past Evolution" drawer showing historical progression up to the current chapter.
> - **Cache Compatibility**: Bumps cache version to `6.1` with full backwards compatibility for `6.0` caches. Default horizon is `Off (Current Only)`.

---

## Technical Architecture & Design Specification

### 1. Data Model (`xray_cachemanager.lua` & `xray_data.lua`)
Cache version bumped to `"6.1"` while supporting loading of `"6.0"`. The data model is extended across all entity types:

```lua
-- Character / Location / Term entity structure
{
    id = "char_alice_vance",
    name = "Alice Vance",
    aliases = { "Alice", "Agent Vance" },
    visible_from = {
        chapter_index = 2,
        chapter_title = "Chapter 2: Arrival",
        page_hint = 42
    },
    -- Default / fallback fields for legacy views
    role = "Traveller",
    description = "A mysterious traveller arriving at the station.",
    
    -- Chronological state transitions (Cumulative Evolved Summaries)
    states = {
        {
            chapter_index = 2,
            chapter_title = "Chapter 2: Arrival",
            page_hint = 42,
            role = "Traveller",
            status = "alive",
            description = "A mysterious traveller arriving at the station.",
            evidence = "Arrived on the 4:15 express with luggage."
        },
        {
            chapter_index = 6,
            chapter_title = "Chapter 6: Revelations",
            page_hint = 110,
            role = "Undercover Investigator",
            status = "alive",
            description = "An undercover operative investigating the disappearance, originally posing as a mysterious train traveller.",
            evidence = "Produced royal credentials to the inspector."
        }
    }
}
```

### 2. Runtime Dynamic Resolver (`xray_ui.lua` & `xray_mentions.lua`)
Upgrade `resolveDescriptionForPage()` to full entity state resolution with hybrid gating:
- **Visibility check**:
  ```lua
  function M:isEntityVisibleAtCurrentPosition(entity, current_chapter_idx, current_page)
      if not entity.visible_from then return true end -- legacy entities are always visible
      local v_chap = entity.visible_from.chapter_index or 1
      if current_chapter_idx < v_chap then
          return false
      elseif current_chapter_idx == v_chap then
          if entity.visible_from.page_hint and current_page then
              return current_page >= entity.visible_from.page_hint
          end
          return true
      else
          return true
      end
  end
  ```
- **State resolution**:
  ```lua
  function M:resolveEntityState(entity, current_chapter_idx, current_page)
      if not entity.states or #entity.states == 0 then
          return entity.role, entity.status or "alive", entity.description
      end
      local best_state = nil
      for _, s in ipairs(entity.states) do
          local applies = false
          if s.chapter_index < current_chapter_idx then
              applies = true
          elseif s.chapter_index == current_chapter_idx then
              if s.page_hint and current_page then
                  applies = (current_page >= s.page_hint)
              else
                  applies = true
              end
          end
          if applies then
              if not best_state or s.chapter_index > best_state.chapter_index or
                 (s.chapter_index == best_state.chapter_index and (s.page_hint or 0) >= (best_state.page_hint or 0)) then
                  best_state = s
              end
          end
      end
      if best_state then
          return best_state.role or entity.role, best_state.status or "alive", best_state.description
      end
      return entity.role, entity.status or "alive", entity.description
  end
  ```
- **Mention Capping**:
  In `xray_mentions.lua:buildMentionsMenuItems`, filter mentions so `m.page <= current_page` whenever spoiler protection is active, preventing future horizon occurrences from leaking in quotes.
- **Timeline Filtering**:
  Filter timeline events so `event.chapter_index <= current_chapter_idx` (or `event.page <= current_page`).

### 3. Sequential Chapter Pipeline (`xray_fetch.lua` & `xray_aihelper.lua`)
- `M:queueSequentialChapterScan(target_chapter_indices, is_manual, on_progress, on_done)`:
  1. For each chapter index:
     - Check if already fetched in `self.chapters_fetched[unique_id]`. If so, skip immediately.
     - Extract that chapter's text via `getTextFromPageRange` or `getTextFromXPointer`.
     - Build prompt injecting the compact manifest of known entities (`id`, `name`, `aliases`, `current_role`, `current_status`, `current_description`).
     - Query LLM asynchronously using existing non-blocking subprocesses.
     - Parse response: record new entities with `visible_from` and new states into `entity.states`.
     - Immediately save to `xray_cache.lua` (resilient checkpointing).
     - Pacing cooldown: pause for 3–5 seconds between chapters to prevent provider 429 rate limit triggers.
  2. Dynamic Queue Re-targeting:
     - If reader jumps to a new position, the active in-flight chapter finishes and checkpoints, then obsolete queued chapters are cancelled and the new horizon $[C, C + N]$ is queued.
  3. When queue completes:
     - Trigger `runPostFetchDuplicateCheck` asynchronously to clean up any slight alias drifts.
     - Call `on_done(true)`.

### 4. Background Horizon Orchestrator (`main.lua`)
- Auto-fetch triggers:
  - Setting `prefetch_horizon_chapters`: default `Off (Current Only)` (values: 0, 1, 2, 3, 5).
  - When Wi-Fi is connected and `prefetch_horizon_chapters > 0`:
    - Determine `current_chapter_idx`.
    - Check if chapters $[current\_chapter\_idx + 1 \dots current\_chapter\_idx + N]$ are un-fetched.
    - Queue un-fetched chapters in the sequential background pipeline.
  - On `onNetworkConnected`:
    - Resume pending horizon chapters seamlessly.

### 5. UI Controls & Menus (`xray_ui.lua` & `xray_settings_card.lua`)
- **Settings Card**:
  - Add **Prefetch Horizon (Offline Readers)**:
    - Options: `Off (Current Only)` (Default), `1 Chapter Ahead`, `2 Chapters Ahead`, `3 Chapters Ahead`, `5 Chapters Ahead`.
- **Main Menu**:
  - Add action: **Pre-generate Entire Book...**:
    - Confirms background job start and estimated chapter count.
    - Launches background sequential task.
    - Shows subtle milestone toast notifications (e.g. "Chapter 10/45 pre-generated").
- **Character Detail Card**:
  - Displays the active chapter's state (`role`, `status`, `description`).
  - Adds a "Past Evolution" button/drawer showing chronological progression through earlier chapters up to the reader's current location.

---

## Proposed File Changes

### [MODIFY] [xray_cachemanager.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_cachemanager.lua)
- Bump cache format version to `6.1`.
- Accept and auto-migrate `6.0` caches seamlessly without data loss.
- Support serialization of `visible_from` and `states` for characters, locations, and terms.

### [MODIFY] [xray_aihelper.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_aihelper.lua)
- Add single-chapter delta extraction prompt template with compact manifest injection.
- Instruct LLM to generate cumulative evolved summaries for new state transitions and omit unchanged entities.

### [MODIFY] [xray_fetch.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_fetch.lua)
- Implement `queueSequentialChapterScan` state machine with pacing cooldown.
- Merge deltas into `entity.states` and set `visible_from` across characters, locations, and terms.
- Checkpoint cache after every completed chapter.
- Support dynamic re-targeting upon reader navigation jumps.

### [MODIFY] [xray_ui.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_ui.lua) & [xray_entity_list.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_entity_list.lua)
- Filter entity lists with `isEntityVisibleAtCurrentPosition`.
- Resolve active state via `resolveEntityState` using hybrid chapter and page gating.
- Add "Past Evolution" drawer to detail cards.
- Add menu item for "Pre-generate Entire Book...".

### [MODIFY] [xray_mentions.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_mentions.lua)
- Enforce `m.page <= current_page` filtering on displayed mentions when spoiler protection is active.

### [MODIFY] [xray_settings_card.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_settings_card.lua)
- Add setting selector for `prefetch_horizon_chapters` defaulting to `Off`.

### [MODIFY] [main.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/main.lua)
- Connect reader position changes and network events to trigger background horizon prefetching.

---

## Verification Plan

### Automated Tests
- Create a new spec `spec/xray_horizon_spec.lua` to test:
  1. `isEntityVisibleAtCurrentPosition`: verifies hybrid chapter + page gating for characters, locations, and terms.
  2. `resolveEntityState`: verifies cumulative summary progression when navigating forward/backward.
  3. `mergeSequentialChapterDelta`: verifies delta merging and state transitions without duplicating entities.
  4. Cache version migration: `6.0` caches load and upgrade to `6.1` cleanly.
  5. Mention capping: future mentions beyond `current_page` are suppressed.
- Run test runner via:
  ```powershell
  tools/run_tests.bat
  ```

### Manual Verification
1. Load test EPUB book in KOReader emulator or test environment.
2. Turn on Prefetch Horizon to `2 Chapters Ahead`.
3. Read Chapter 1 $\to$ verify Chapters 2 and 3 are fetched in the background with pacing cooldowns.
4. Verify Chapter 1 X-Ray views display only Chapter 1 characters, locations, terms, and mentions.
5. Disconnect Wi-Fi $\to$ advance to Chapter 2 and 3.
6. Verify newly introduced entities unlock offline with correct roles and descriptions.
7. Open character card $\to$ verify active state and open "Past Evolution" drawer to inspect progression.
8. Turn back to Chapter 1 $\to$ verify character states gracefully roll back to Chapter 1 state.
