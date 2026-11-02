# AI interaction UX — macOS & Android (proposed)

## Entry points

- Ask AI about this page  
- Explain my handwritten notes  
- Analyze this document  
- Understand this diagram / selected region  
- Convert notes to documentation  
- Send context to Claude / Cursor  

## Shared panel contents

Provider selector · model selector · context selection · question input ·
streaming response (Markdown, code, tables) · stop/retry · Save Answer ·
history · usage details · references to pages/regions.

## macOS

Resizable side panel or contextual window; keep reading/writing while answer
streams; deep-link chips to page/stroke regions; match existing toolbar density.

## Android / BOOX (e-ink)

Independent of Mac (tablet can call cloud directly once credentials exist).

- Minimal animation; batch UI invalidation  
- High-contrast typography; compact chrome  
- Preserve writing space — collapsible panel / sheet  
- Done/back dismisses without destroying saved threads  

## Response destination

Default: current device. Optional “also show on paired Mac/tablet” only after
session sync is specified. Closing a panel hides UI; does not delete drafts.
