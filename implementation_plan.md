# Unified Implementation Plan: Source-Positioned Entity History (#131), Offline Prefetch Horizon (#133) & Spoiler-Free Text Extraction Guardrails (#150)

## User Review Required

> [!IMPORTANT]
> **Unified Architecture**: This plan unifies three complementary spoiler-prevention and pre-generation pillars:
> 1. **Issue #131 (Full Pre-generation & Source-Positioned History)**: Pre-generate entity states across the entire book, storing chronological deltas tied to exact chapters and XPointers so the UI only reveals what has occurred up to the reader's current location.
> 2. **Issue #133 (Offline Prefetch Horizon)**: Silently pre-generate $N$ chapters ahead (1–5) in the background so offline readers (e.g. commuting or airplane mode) always have up-to-date X-Ray data ready.
> 3. **Issue #150 (Spoiler-Free Text Extraction Guardrails & Choke Points)**: Enforce strict input-side boundaries in `ChapterAnalyzer` and `xray_fetch.lua` to guarantee that text extraction, annotations, mentions, and updates never pull text or knowledge from beyond the reader's current page/XPointer.
>
> All decisions from our `/grill-me` session and the four leaks identified in #150 have been synthesized:
> - **Entity Scope**: Full parity across Characters, Locations, and Terms/Worldbuilding with `visible_from` and `states`.
> - **Input Guardrails (#150)**:
>   - Bounded TOC chapter extraction via `getTextFromXPointers` (no unbounded DocFragment leaks in multi-chapter files).
>   - Filter annotations in `getAnnotationsForAnalysis` to those strictly before the reader's current position.
>   - Drop the `+ 5` overshoot in `scanMentionsAsync` so quotes/snippets never pass the reader.
>   - Layout-resilient checkpointing with XPointers (immune to font/margin pagination shifts).
>   - Guard manual updates after navigating backwards so later knowledge does not contaminate earlier descriptions.
>   - Long-press single-word lookup text capped at the selected word position.
> - **Output Shielding (#131 / #133)**: Hybrid chapter + `page_hint` gating in `isEntityVisibleAtCurrentPosition` and `resolveEntityState`. Ahead entities/states remain completely invisible.
> - **Extraction & Continuity**: Sequential prompts use a compact manifest containing the latest active description. The LLM returns delta-only state transitions as cumulative evolved summaries.
> - **Execution & Rate Limiting**: Silent background task with 3–5s inter-chapter cooldowns to prevent provider 429 rate limits, with milestone toast notifications.
> - **Queue Resilience**: Dynamic re-targeting on navigation jumps (active chapter finishes and checkpoints, obsolete pending chapters discarded).
> - **Resume Behavior**: Silently skips already-scanned chapters in cache.
> - **Card UI**: Clean active state presentation with an optional "Past Evolution" drawer showing historical progression up to the current chapter.
> - **Cache Compatibility**: Bumps cache version to `6.1` with full backwards compatibility for `6.0` caches. Default horizon setting is `Off (Current Only)`.

---

## Technical Architecture & Design Specification

### 1. Data Model (`xray_cachemanager.lua` & `xray_data.lua`)
Cache version bumped to `"6.1"` while supporting loading of `"6.0"`. The data model incorporates source positions with layout-resilient XPointers alongside chapter indices and page hints:

```lua
-- Character / Location / Term entity structure
{
    id = "char_alice_vance",
    name = "Alice Vance",
    aliases = { "Alice", "Agent Vance" },
    visible_from = {
        chapter_index = 2,
        chapter_title = "Chapter 2: Arrival",
        page_hint = 42,
        xpointer = "/6/4[chap2]!/4/2/1:0" -- Layout-resilient anchor (#150)
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
            xpointer = "/6/4[chap2]!/4/2/1:0",
            role = "Traveller",
            status = "alive",
            description = "A mysterious traveller arriving at the station.",
            evidence = "Arrived on the 4:15 express with luggage."
        },
        {
            chapter_index = 6,
            chapter_title = "Chapter 6: Revelations",
            page_hint = 110,
            xpointer = "/6/12[chap6]!/4/8/1:0",
            role = "Undercover Investigator",
            status = "alive",
            description = "An undercover operative investigating the disappearance, originally posing as a mysterious train traveller.",
            evidence = "Produced royal credentials to the inspector."
        }
    }
}
```

### 2. Input-Side Text Extraction Guardrails (#150 Choke Points in `xray_chapteranalyzer.lua` & `xray_fetch.lua`)
Prevent text leaks into LLM prompts before analysis starts:

1. **Bounded Chapter Extraction (`getDetailedChapterSamples` & sequential scan)**:
   - *Problem*: `getTextFromXPointer(chapter.xpointer)` returns the entire XHTML file. If multiple chapters share one file, samples pull text from later chapters past the reader.
   - *Fix*: Use `getTextFromXPointers(chapter.xpointer, next_chapter.xpointer)` to bound extraction strictly between TOC entries. When extracting the reader's current chapter, never extend beyond `current_page` / reader's XPointer.
2. **Annotation Filtering (`getAnnotationsForAnalysis`)**:
   - *Problem*: `ui.annotation.annotations` sends all highlights/notes in the book, including those past the reader.
   - *Fix*: Filter annotations so only those with `(annot.page or 0) <= current_page` (or position before reader's `pos1`/XPointer) are passed to LLM analysis.
3. **Strict Mention Scan Boundary (`scanMentionsAsync`)**:
   - *Problem*: `m.page > (max_page + 5)` overshoots by 5 pages, leaking future sentences in the mention list.
   - *Fix*: Remove the `+ 5` overscan buffer (`m.page > max_page`), ensuring no mentions past the reader are captured.
4. **Stale Position / Backward Update Guard (`xray_fetch.lua`)**:
   - *Problem*: Navigating backward and running an Update ignored `last_fetch_page` as stale and re-analyzed the chapter while sending future entity descriptions from later pages.
   - *Fix*: When `last_fetch_page >= current_page`, refuse redundant updates or merge solely with the historical snapshot valid at the current position.
5. **Single-Word Lookup Clamping (`xray_fetch.lua`)**:
   - *Problem*: Long-press dictionary/lookup sent the current and previous page whole, leaking upcoming text on the current page.
   - *Fix*: Truncate immediate page text at the selected word's `pos1` coordinate.
6. **XPointer Checkpointing**:
   - Store `last_fetch_xpointer` in `book_data` so pagination changes (font size, margin adjustments) do not invalidate progress or cause text skipping/repetition.

### 3. Runtime Dynamic Resolver & Output Shielding (`xray_ui.lua` & `xray_mentions.lua`)
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
- **Mention List Display Capping**:
  In `xray_mentions.lua:buildMentionsMenuItems`, filter mentions so `m.page <= current_page` whenever spoiler protection is active, preventing cached horizon mentions from leaking quote snippets.
- **Timeline Filtering**:
  Filter timeline events so `event.chapter_index <= current_chapter_idx` (or `event.page <= current_page`).

### 4. Sequential Chapter Pipeline (`xray_fetch.lua` & `xray_aihelper.lua`)
- `M:queueSequentialChapterScan(target_chapter_indices, is_manual, on_progress, on_done)`:
  1. For each chapter index:
     - Check if already fetched in `self.chapters_fetched[unique_id]`. If so, skip immediately.
     - Extract chapter text boundedly between `chapter.xpointer` and `next_chapter.xpointer` using `getTextFromXPointers` (or page ranges if page-based).
     - Build prompt injecting the compact manifest of known entities (`id`, `name`, `aliases`, `current_role`, `current_status`, `current_description`).
     - Query LLM asynchronously using existing non-blocking subprocesses.
     - Parse response: record new entities with `visible_from` and new states into `entity.states`.
     - Checkpoint immediately to `xray_cache.lua`.
     - Pacing cooldown: pause for 3–5 seconds between chapters to prevent provider 429 rate limit triggers.
  2. Dynamic Queue Re-targeting:
     - If reader jumps to a new position, the active in-flight chapter finishes and checkpoints, then obsolete queued chapters are cancelled and the new horizon $[C, C + N]$ is queued.
  3. When queue completes:
     - Trigger `runPostFetchDuplicateCheck` asynchronously to clean up any slight alias drifts.
     - Call `on_done(true)`.

### 5. Background Horizon Orchestrator (`main.lua`)
- Auto-fetch triggers:
  - Setting `prefetch_horizon_chapters`: default `Off (Current Only)` (values: 0, 1, 2, 3, 5).
  - When Wi-Fi is connected and `prefetch_horizon_chapters > 0`:
    - Determine `current_chapter_idx`.
    - Check if chapters $[current\_chapter\_idx + 1 \dots current\_chapter\_idx + N]$ are un-fetched.
    - Queue un-fetched chapters in the sequential background pipeline.
  - On `onNetworkConnected`:
    - Resume pending horizon chapters seamlessly.

### 6. UI Controls & Menus (`xray_ui.lua` & `xray_settings_card.lua`)
- **Settings Card**:
  - Add **Prefetch Horizon (Offline Readers)**:
    - Options: `Off (Current Only)` (Default), `1 Chapter Ahead`, `2 Chapters Ahead`, `3 Chapters Ahead`, `5 Chapters Ahead`.
- **Main Menu**:
  - Add action: **Pre-generate Entire Book...**:
    - Confirms background task start and estimated chapter count.
    - Launches background sequential scan.
    - Shows subtle milestone toast notifications (e.g. "Chapter 10/45 pre-generated").
- **Character Detail Card**:
  - Displays the active chapter's state (`role`, `status`, `description`).
  - Adds a "Past Evolution" button/drawer showing chronological progression through earlier chapters up to the reader's current location.

---

## Proposed File Changes

### [MODIFY] [xray_chapteranalyzer.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_chapteranalyzer.lua)
- **#150 Choke Point**:
  - Update `getDetailedChapterSamples` to use `getTextFromXPointers(chapter.xpointer, next_chapter.xpointer)` instead of unbounded `getTextFromXPointer`.
  - Update `getAnnotationsForAnalysis` to filter out annotations with `annot.page > current_page`.
  - Update `scanMentionsAsync` to remove the `+ 5` overscan buffer (`m.page > max_page`).
  - Add helper to extract bounded single-chapter text for `queueSequentialChapterScan`.

### [MODIFY] [xray_fetch.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_fetch.lua)
- **#150 Guards**:
  - Clamp single-word lookup text context at the highlighted word's `pos1`.
  - Prevent backward-navigation updates from sending later descriptions to LLM merge prompts.
  - Record `last_fetch_xpointer` in `book_data` for layout-resilient checkpointing.
- **#131 / #133 Pipeline**:
  - Implement `queueSequentialChapterScan` state machine with pacing cooldown.
  - Merge deltas into `entity.states` and set `visible_from` across characters, locations, and terms.
  - Checkpoint cache after every completed chapter.
  - Support dynamic re-targeting upon reader navigation jumps.

### [MODIFY] [xray_cachemanager.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_cachemanager.lua)
- Bump cache format version to `6.1`.
- Accept and auto-migrate `6.0` caches seamlessly without data loss.
- Support serialization of `visible_from` and `states` (including `xpointer` anchors) for characters, locations, and terms.

### [MODIFY] [xray_aihelper.lua](file:///c:/Users/Jimmy/Documents/ko/koreader-xray-plugin/xray.koplugin/xray_aihelper.lua)
- Add single-chapter delta extraction prompt template with compact manifest injection.
- Instruct LLM to generate cumulative evolved summaries for new state transitions and omit unchanged entities.

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
  6. **#150 Extraction Choke Points**:
     - Verify `getDetailedChapterSamples` does not extract text past `next_chapter.xpointer` in multi-chapter XHTML files.
     - Verify `getAnnotationsForAnalysis` omits annotations with `annot.page > current_page`.
     - Verify `scanMentionsAsync` drops mentions past `max_page` without a `+ 5` overscan.
- Run test runner via:
  ```powershell
  tools/run_tests.bat
  ```

### Manual Verification
1. Load test EPUB book in KOReader emulator or test environment.
2. Verify earlier chapter sampling in a multi-chapter file stops at the next TOC marker.
3. Add a highlight on page 50; read page 20 $\to$ verify page 50 highlight is never sent to the LLM.
4. Turn on Prefetch Horizon to `2 Chapters Ahead`.
5. Read Chapter 1 $\to$ verify Chapters 2 and 3 are fetched in the background with pacing cooldowns.
6. Verify Chapter 1 X-Ray views display only Chapter 1 characters, locations, terms, and mentions.
7. Disconnect Wi-Fi $\to$ advance to Chapter 2 and 3.
8. Verify newly introduced entities unlock offline with correct roles and descriptions.
9. Open character card $\to$ verify active state and open "Past Evolution" drawer to inspect progression.
10. Turn back to Chapter 1 $\to$ verify character states gracefully roll back to Chapter 1 state.
