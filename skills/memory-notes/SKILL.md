---
name: memory-notes
description: Frontmatter schema, relation vocabulary, and provenance rules for writing knowledge-vault notes with Basic Memory. Use before write_note/edit_note.
---

# Memory notes conventions

## Before writing

1. `search_notes` first. Never create a note that duplicates an existing one.
2. Check existing tags before adding a new one. Reuse an existing tag if it
   already covers the concept.

## Frontmatter (fixed schema - no other fields)

- `title` - required.
- `type` - required. Always `summary`.
- `permalink` - required.
- `tags` - required. Reuse existing tags where possible.
- `date` - required. Note creation date. Immutable - never update on edit.
- `source_path` - repo-relative path, when the source is a file in the vault
  directory. Mutually exclusive with `source_url`.
- `source_url` - the source's URL: a web article, or a file in approved
  external storage (company OneDrive/SharePoint, personal cloud storage) that
  isn't in this repo. A share link counts as a URL. Mutually exclusive with
  `source_path`.
- `source_published_date` - optional. Only if already exposed by the source
  (Open Graph `article:published_time`, JSON-LD `datePublished`, PDF
  `CreationDate`, visible byline). Do not do extra lookups to find it.
- `source_updated_date` - optional. Same rule, for
  `article:modified_time` / `dateModified` / PDF `ModDate` / a visible "last
  updated" note. Capture alongside `source_published_date` when both exist.

## Relations (fixed vocabulary - no other types)

- `relates_to` - neutral connection.
- `extends` - builds on the target.
- `contradicts` - disagrees with the target; both remain valid.
- `supersedes` - replaces the target as current understanding. Use instead of
  `contradicts` when the target is an earlier, weaker pass at the same topic,
  not something in genuine tension with this note.

Never write inverse relations (`extended_by`, `superseded_by`, etc.) -
backlinks are automatic.

## Large source files

If a source file to drop in the vault is large (>50MB, or anything that
would make `git push` noticeably slow): stop, flag it to the user, do not
commit it automatically. Do not suggest a raw blob store (S3 or similar).
Acceptable options, ask the user to choose: reference via `source_url`
pointing at already-approved storage, or git-lfs for that one file.
