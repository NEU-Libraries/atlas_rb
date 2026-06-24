# Changelog

## 1.8.0

### Added — `Work.set_full_text` (full-text search seam)

`Work.set_full_text(id, text:)` → `PATCH /works/:id/full_text`. Hands Atlas the
Work-level aggregate of Cerberus-extracted document text; Atlas stores it as the
Work's derived `full_text` and projects it onto the Work's Solr doc
(`all_text_timv`) for body-text search and the "Full Text Match" snippet. Same
"machine-set derived metadata" family as `set_thumbnails` / `set_image_derivatives`
— a regenerable search aid re-sent on any re-ingest, not user-authored content.

## 1.7.0

### Added — binary version read surface (`Blob.versions` / `version_content` / `rollback`)

The binary counterpart to `Resource.mods_versions` / `mods_version`. Replacing a
file (`Blob.update`) already retains prior bytes in OCFL; these bindings make the
retained versions addressable:

- `Blob.versions(id)` → `GET /files/:id/versions` — reverse-chronological
  envelope (`{ "blob_id", "versions" }`), one descriptor per retained content
  revision (`version_id`, `file_identifier`, `created`, `digest`, `size`,
  `original_filename`, plus correlated `actor_nuid` / `on_behalf_of_nuid`).
  Admin-gated by the server.
- `Blob.version_content(id, version_id, &chunk_handler)` →
  `GET /files/:id/versions/:version_id/content` — streams a prior version's
  bytes through a block, exactly like `Blob.content`.
- `Blob.rollback(id, version_id)` → `POST /files/:id/rollback` — reinstates a
  prior version by appending its bytes as a new revision (non-destructive; NOID
  preserved).

### Added — `Blob.update` accepts `idempotency_key:`

`Blob.update` (`PATCH /files/:id`) now takes an optional `idempotency_key:`,
threaded as the `Idempotency-Key` header (same semantics as `Blob.create` /
`FileSet.create`). A double-submitted replace sharing a key returns the existing
Blob instead of minting a second OCFL version.

## 1.5.0

### Added — optional auth for `Reset.clean`

`AtlasRb::Reset.clean` now uses **optional auth**: it signs an assertion when a
credential is available and sends no `Authorization` header otherwise, instead
of raising `AtlasRb::ConfigurationError`. Atlas serves `GET /reset` with
`require_auth` skipped (env-gated), so the call no longer needs an acting nuid
or a configured signer just to satisfy the client-side header builder — fixing
test `before(:suite)` resets that run before any acting principal is set.

`FaradayHelper#connection` gains an `auth:` keyword (`:required` default,
`:optional`) to support this; every other endpoint stays strict and still
raises on a missing credential.

## 1.4.0

### Removed — legacy `ATLAS_TOKEN` relay

The shared-secret relay (`ATLAS_TOKEN` bearer + `User: NUID` / `On-Behalf-Of`
headers) has been removed. **Relay-signing is now the only relay path:** set
`AtlasRb.config.assertion_signing_key` / `assertion_signing_kid` and the
transport signs a short-lived ES256 assertion (`sub` = acting NUID; acting-as
rides a signed `obo` claim). `ATLAS_JWT` (BYO-JWT) still takes precedence.

With neither a signing key nor `ATLAS_JWT` configured, `connection` /
`multipart` now raise the new `AtlasRb::ConfigurationError` rather than falling
back to `ATLAS_TOKEN`. The `ATLAS_TOKEN` environment variable is no longer read.

**Migration:** hosts must configure a signing key (Cerberus already does via its
`atlas_rb` initializer). This is a breaking change for any caller still relying
on `ATLAS_TOKEN`.

## 1.3.5

### Added — `Compilation.list(q:)` title filter

`Compilation.list` accepts `q:`, a case-insensitive title substring
filter (Atlas v0.6.60, `GET /compilations?q=<term>`). The filter applies
before pagination, so the returned `"pagination"` block describes the
filtered result. Backs the Cerberus Add-to-set typeahead.

```ruby
AtlasRb::Compilation.list(q: "course", nuid: "000000002")
```

## 1.3.4

### Added — Compilation (DRS "Sets") bindings

Bindings for Atlas's Compilation surface (Atlas v0.6.57) — personal,
curated, recipe-based groupings of Works and Collections, the persistence
behind the Cerberus Sets UI.

```ruby
set = AtlasRb::Compilation.create("Course readings", nuid: "000000002")

# Recipe lines — each mutation returns the full updated compilation
AtlasRb::Compilation.add_included_collection(set["id"], "col-456", nuid: "000000002")
AtlasRb::Compilation.add_included_work(set["id"], "w-789", nuid: "000000002")
AtlasRb::Compilation.add_exclusion(set["id"], "w-790", nuid: "000000002")   # set aside
AtlasRb::Compilation.remove_exclusion(set["id"], "w-790", nuid: "000000002") # put back

# Make public, resolve the recipe
AtlasRb::Compilation.update(set["id"],
                            permissions: { read: ["public"], edit: [], edit_users: [] },
                            nuid: "000000002")
AtlasRb::Compilation.contents(set["id"]).contents.map(&:noid)
```

- `Compilation.create / find / update / destroy / list` — owner-scoped
  CRUD. The depositor is stamped server-side from the acting NUID and is
  immutable; `list(owner:)` (cross-owner) is admin-only. `update` takes
  `title:` / `description:` / `permissions:` (the ACL hash replaces all
  three grant lists; ACL changes are audited server-side, no-ops
  suppressed).
- Six membership calls (`add/remove_included_collection`,
  `add/remove_included_work`, `add/remove_exclusion`) — each returns the
  updated `"compilation"` object so chip counts refresh without a
  follow-up `find`. Adds and removes are idempotent; the type rules
  (Works and Collections only, no Communities) are enforced by Atlas.
- `Compilation.contents` wraps `GET /compilations/<id>/contents` — the
  recipe resolved to `find_many`-style digests with Solr-side pagination
  (`{ total, page, per_page, pages }`). Included for completeness; CERES
  hits the endpoint directly and Cerberus resolves contents via its own
  Blacklight query.
- New `AtlasRb::CompilationError` (422 — blank title, wrong-type or
  unknown membership noid), the Compilation sibling of
  `LinkedMemberError`. `AtlasRb::ForbiddenError` now also covers 403s on
  the Compilation surface, so a non-grantee reading a private Set gets a
  typed refusal instead of a swallowed `nil`.

## 1.3.3

### Added — multipage bindings (FileSet ordinality)

Bindings for Atlas's FileSet-ordinality surface (Atlas v0.6.53) — the
primitive behind multipage Works (postcards, scanned books, photo albums):
one Work, N ordered page FileSets.

```ruby
# Ordered create — one FileSet per page
page = AtlasRb::FileSet.create("w-789", "image", position: 1)
AtlasRb::FileSet.update(page["id"], "/tmp/page-001.tiff")

# Ordered listing — the read a IIIF manifest assembler needs
AtlasRb::Work.file_sets("w-789")
# => [{ "noid" => ..., "position" => 1, "assets" => [...] }, ...]

# Preservation-record view — the Work-level METS physical structMap
AtlasRb::Work.mets("w-789").mets.pages.map(&:order)
# => [1, 2, 3]
```

- `FileSet.create` gains an optional `position:` kwarg — 1-based page
  order, set at create time only; omitted = unordered (every existing
  call is unaffected). Sequence validation (contiguity, uniqueness) stays
  the caller's job — Atlas stores what it is given.
- `Work.file_sets` wraps `GET /works/<id>/file_sets`: one entry per
  page-bearing FileSet, `position` ascending with unordered FileSets
  last, each nesting its downloadable assets (content Blobs + per-page
  IIIF Delegates). **Unpaginated** by design — the whole page sequence
  arrives in one call. Grouped sibling of `.assets`, which flattens.
- `Work.mets` wraps `GET /works/<id>/mets`: the Work-level METS JSON
  projection; `mets.pages` carries the preserved page order. Atlas builds
  the document at `Work.complete`, so a never-completed Work has no METS
  yet — the binding returns `nil` on the 404, matching
  `User.find_by_nuid`'s convention.

## 1.3.2

### Added — `AtlasRb::User` (read-only user directory)

A user-context binding for Atlas's user directory endpoints — recipient
typeahead and NUID → name resolution for any surface that today renders a
bare NUID (User Inbox sender display, Audit History chips, Rights history).

```ruby
AtlasRb::User.search("jan", nuid: "000000002")
# => [{ "nuid" => "001234567", "name" => "Doe, Jane" }, ...]

AtlasRb::User.find_by_nuid("001234567")
# => { "nuid" => "001234567", "name" => "Doe, Jane" }

AtlasRb::User.resolve(["001234567", "007654321"])
# => one entry per resolvable NUID, ordered by name
```

- `search` is the typeahead: case-insensitive match on name, prefix match
  on NUID. Atlas caps the list at 10 and orders by name.
- `resolve` batch-resolves up to 100 NUIDs in one round-trip (an inbox
  page of senders in one call). Unresolvable NUIDs are dropped — callers
  index by `nuid`.
- `find_by_nuid` resolves a single NUID; returns `nil` on Atlas's 404
  (unknown NUID, or one held by an excluded role — indistinguishable on
  the wire by design).
- Minimal disclosure is enforced server-side: entries carry `nuid` +
  `name` only, and `anonymous` / `guest` / `system` rows never appear.
- Deliberately **not** under `AtlasRb::System` — this is an acting-user
  capability on the ordinary `ATLAS_TOKEN` + `User:` header pairing; the
  `System` namespace stays reserved for system-token calls.

## 1.3.1

### Added — `AtlasRb::Resource.mods_versions` / `mods_version` (MODS version history)

Two bindings for Atlas's MODS version-history endpoints. `mods_versions`
lists the retained versions of a resource's descriptive metadata;
`mods_version` fetches the raw MODS XML as of a specific version — together
enough to drive a line-diff between any two MODS states.

```ruby
history = AtlasRb::Resource.mods_versions("w-789")
history["versions"].first["version_id"]  # => "v5"   (newest)
history["versions"].first["actor_nuid"]   # => "000000002"

old_xml = AtlasRb::Resource.mods_version("w-789", "v3")
new_xml = AtlasRb::Resource.mods_version("w-789", "v5")
```

- `mods_versions` returns the full envelope (`resource_id` + a
  reverse-chronological `versions` array) as an `AtlasRb::Mash`. Each
  descriptor mirrors the audit-event shape (`version_id`, `created`,
  `actor_nuid`, `on_behalf_of_nuid`, `source`, `note`); actor fields are
  correlated from the audit log and may be `null`. Admin-gated server-side.
- `mods_version` returns the **raw XML body** (mirroring `Work.mods`). Only
  XML is version-recoverable — the JSON access copy is overwritten in place
  — so `kind:` is accepted for parity but XML is the only retained format.
- Version labels are opaque, sortable OCFL `vN` strings (a Blob's
  preservation envelope occupies earlier versions, so the first MODS
  version is typically `v3`). Treat them as identifiers to feed back into
  `mods_version`, not as ordinals.
- Both are type-agnostic (Community / Collection / Work) and live on
  `Resource` beside `history` / `permissions`. A resource with no MODS
  returns `{ "versions" => [] }`.

## 1.3.0

### Added — `AtlasRb::Resource.find_many` (batch resolve by NOID)

A binding for Atlas's `POST /resources/find_many`. Resolves a set of NOIDs
to lightweight digests in **one** round-trip, replacing the `find`-per-id
fan-out that several Cerberus surfaces (breadcrumbs, linked-member lists,
load-destination pickers) paid on every render.

```ruby
nodes   = AtlasRb::Resource.find_many(["col-456", "col-457", "missing"])
by_noid = nodes.index_by { |n| n["noid"] }
by_noid["col-456"].title   # => "Some Collection"
```

- Each digest is `{ "id", "noid", "klass", "title", "thumbnail",
  "tombstoned" }` — not the full typed payload. `title` / `thumbnail` are
  `null` for resources off the Modsable backbone (FileSet/Blob).
- The ids ride in the request **body**, so the list isn't bounded by URL
  length. Returns one `AtlasRb::Mash` per resolved resource.
- The result is **unordered** and **may be shorter than the input**:
  unresolvable ids are dropped, tombstoned ones come back flagged
  (`"tombstoned" => true`). Index by `"noid"` — don't assume positional
  correspondence with the input.
- Resolves NOIDs (alternate ids) only; raw Valkyrie ids are not a supported
  input.

## 1.2.2

### Added — `AtlasRb::AuditEvent.emit` (session-scoped audit events)

A new binding for Atlas's `POST /audit_events` endpoint, which records an
AuditEvent with a **null `resource_id`** — an event not tied to any
resource write. This is the gem's half of the impersonation audit trail
(acting-as / view-as): the session lifecycle lives entirely in the calling
application, and a view-as session performs no writes, so neither leaves a
per-resource event for `Resource.history` to surface.

```ruby
AtlasRb::AuditEvent.emit(
  action:            "impersonation_started",  # or "impersonation_ended"
  actor_nuid:        admin_nuid,
  on_behalf_of_nuid: target_nuid,
  mode:              "acting_as"               # or "view_as"
)
```

- The recorded principals (`actor_nuid`, `on_behalf_of_nuid`), `mode`, and
  an optional free-form `payload:` travel in the request **body**, not in
  ambient headers — so the call is self-describing even when fired as a
  session is being torn down (e.g. `impersonation_ended`).
- The request authenticates via the standard `connection` (system token),
  with the `User: NUID` header pinned to `actor_nuid` so the server-side
  admin gate holds regardless of ambient `Current` state.
- `on_behalf_of_nuid`, `mode`, and `payload` are omitted from the body when
  blank, leaving room for future, mode-less session events. Atlas stamps
  `occurred_at` server-side.
- Authorization errors (`401` / `403`) surface as raw Faraday responses,
  matching `Resource.history`.

Depends on the matching Atlas-side `POST /audit_events` emit endpoint
(nullable resource scope, admin-gated); see the impersonation gap report.

## 1.2.1

### Added — typed errors for re-parent / linked-member rejections

The re-parent and linked-member bindings no longer swallow Atlas's `4xx`
error envelope. Previously a `422`/`403` parsed fine but lacked the
success key (`"collection"` / `"work"` / `"community"`), so the binding
returned `nil` and discarded Atlas's machine-readable `error` / `message`
— callers could not tell an invalid move from a not-found from a
forbidden one.

- **`AtlasRb::ReparentError`** — raised on a `422` to a `.../parent` path
  (`Collection`/`Community`/`Work.reparent`). Carries the envelope's
  `error` discriminator as `#code` (`cycle`, `invalid_parent_type`,
  `tombstoned_node`, `tombstoned_parent`, `parent_required`,
  `parent_not_found`) plus `#resource_id` and `#message`.
- **`AtlasRb::LinkedMemberError`** — raised on a `422` to a
  `.../linked_members` path (`Work.add_linked_member` /
  `remove_linked_member`). Same shape (`#code`, `#resource_id`, `#message`).
- **`AtlasRb::ForbiddenError`** — raised on a `403` to either path.
  Carries `#code`, `#action`, and `#subject` from the envelope.

All three subclass `AtlasRb::Error`. A new
`AtlasRb::Middleware::RaiseOnResourceError` (registered alongside
`RaiseOnStaleResource`) performs the translation, keyed on the request
**path + status** so it stays narrow: only the re-parent and linked-member
write paths are affected, and only `403`/`422` bodies carrying an `error`
discriminator. Other endpoints, other statuses, and the `tombstone`
endpoint's `code: "has_live_children"` body are untouched, and the `409`
optimistic-lock conflict still surfaces as `StaleResourceError`. Rescue is
opt-in — callers that don't discriminate see the success payload exactly as
before.

## 1.2.0

### Added — Tree/DAG foundation bindings

Thin Faraday mirrors for the two membership mutations Atlas shipped as
part of the DRS "Tree/DAG foundation" (re-parenting and linked members).
No client-side logic — the gem mirrors Atlas's wire and never queries
Solr.

- **`AtlasRb::Collection.reparent(id, new_parent_id, nuid: nil, on_behalf_of: nil)`**
- **`AtlasRb::Community.reparent(id, new_parent_id, nuid: nil, on_behalf_of: nil)`**
- **`AtlasRb::Work.reparent(id, new_collection_id, nuid: nil, on_behalf_of: nil)`**

  Bind `PATCH /<type>/:id/parent` with a `{ parent_id }` body, moving a
  resource to a new structural parent. Mirrors `create`'s single-parent-id
  shape and returns the updated resource (same shape as `find`), reflecting
  the new `a_member_of`. `Community.reparent` accepts `new_parent_id: nil`
  to promote a Community to the top of the tree — the same way
  `Community.create(nil)` makes a top-level Community; a `nil` destination
  is rejected by Atlas for Works and Collections. Atlas enforces the
  structural rules (type, cycle, tombstone) server-side and synchronously
  cascades the ancestry index over descendants, surfacing violations as
  `422`. The Work re-parent endpoint is included — Atlas shipped it (the
  plan had flagged it as optional). All three endpoints use the shared
  `parent_id` body key, including the Work one (not `collection_id`).

- **`AtlasRb::Work.linked_members(id, nuid: nil, on_behalf_of: nil)`** —
  `GET /works/:id/linked_members`.
- **`AtlasRb::Work.add_linked_member(work_id, collection_id, nuid: nil, on_behalf_of: nil)`** —
  `POST /works/:id/linked_members` with a `{ collection_id }` body.
- **`AtlasRb::Work.remove_linked_member(work_id, collection_id, nuid: nil, on_behalf_of: nil)`** —
  `DELETE /works/:id/linked_members/:collection_id` (Collection as a path
  segment).

  The DAG overlay: a Work has one structural parent (`a_member_of`) but
  may additionally be a *linked* member of any number of other Collections
  (`a_linked_member_of`). These manage that overlay without moving the
  Work. All three return the Work's current linked Collection noids as a
  bare array (mirroring `Collection.children`); the two mutations return
  the list *after* the change, so no follow-up GET is needed.

  Cerberus consumes these from the re-parent and "add to collection" UI.

## 1.1.1

### Added

- **`depositor:` kwarg on `AtlasRb::Work.create`** — optional NUID
  forwarded as the `depositor` query param on `POST /works`. When
  omitted, behaviour is unchanged: Atlas defaults the depositor to the
  acting user. When provided, Atlas stamps the named NUID as the Work's
  `depositor` and records the acting user as the `proxy_uploader`.

  Motivation: proxy deposit. Librarians and bulk-deposit jobs frequently
  upload Works on behalf of a researcher who is the rightful credited
  depositor. Until now there was no way to express that split through
  the gem — callers had to choose between misattributing the deposit to
  the librarian or dropping to a raw Faraday call. The depositor is
  immutable post-create; there is no corresponding setter on the update
  surface.

## 1.1.0

### Added

- **`AtlasRb::Resource.history(id, nuid: nil, on_behalf_of: nil)`** —
  wraps Atlas's `GET /resources/:id/history` endpoint. Returns the full
  envelope (`resource_id` + reverse-chronological `events` array) as an
  `AtlasRb::Mash`, matching the gem's convention for cross-resource
  bindings. Authorization errors (`401` / `403`) surface as raw Faraday
  responses for the caller's rescue layer. Pagination is not yet
  supported by the server; a TODO is in place for when it lands.

  Cerberus consumes this binding for the "History" tab on resource show
  pages.

## 1.0.0 — major restructure: namespace gradient + ambient identity

This release reshapes the gem's API surface. Downstream consumers
(Cerberus) need to update call sites — see the migration section
below.

### Added

- **`AtlasRb.configure { |c| ... }`** — configurable defaults for
  ambient identity:
  - `config.default_nuid` — callable invoked when a resource method
    is called without an explicit `nuid:` kwarg. Lets host apps
    register `-> { Current.nuid }` once instead of threading
    `nuid: Current.nuid` at every call site.
  - `config.default_on_behalf_of` — callable for the
    `On-Behalf-Of:` header, used by acting-as / view-as flows.
- **`on_behalf_of:` kwarg** on every resource method that already
  took `nuid:`. Sent as the `On-Behalf-Of: NUID <nuid>` header when
  set. Falls through to `config.default_on_behalf_of` when omitted.
- **`AtlasRb::Admin::*` namespace** — destructive lifecycle ops:
  - `AtlasRb::Admin::Work.destroy` / `.restore`
  - `AtlasRb::Admin::Collection.destroy` / `.restore`
  - `AtlasRb::Admin::Community.destroy` / `.restore`

  Every `destroy` requires `confirm: :i_understand`. Missing or
  wrong value raises `ArgumentError` before any wire request.
- **`AtlasRb::System::*` namespace** — system-context calls:
  - `AtlasRb::System::User.find_or_create` (moved from
    `AtlasRb::User.find_or_create`).
  - `AtlasRb::System::NUID` constant — the seeded `:system` fixture's
    NUID (`"000000000"`).
- **`FaradayHelper#system_connection`** — Faraday factory that
  authenticates with `Rails.application.credentials.atlas_system_token`
  and the system NUID. Never consults the configured defaults. Used
  exclusively by `AtlasRb::System::*`.

### Removed (breaking)

- `AtlasRb::Work.destroy`, `AtlasRb::Work.restore` → move to
  `AtlasRb::Admin::Work`.
- `AtlasRb::Collection.destroy`, `AtlasRb::Collection.restore` →
  move to `AtlasRb::Admin::Collection`.
- `AtlasRb::Community.destroy`, `AtlasRb::Community.restore` →
  move to `AtlasRb::Admin::Community`.
- `AtlasRb::User.find_or_create` → moves to
  `AtlasRb::System::User.find_or_create`. The class
  `AtlasRb::User` is gone.

### Changed

- `Work.tombstone`, `Collection.tombstone`, `Community.tombstone`
  relax `nuid:` from required-kwarg to `nuid: nil`. The fall-through
  resolution in `FaradayHelper#connection` handles the lookup. Atlas
  still requires a real NUID on the wire for tombstone audit; if
  neither the call site nor the configured default supplies one, the
  request will hit Atlas without a `User:` header and Atlas will
  reject it.

### Migration

For consumers (Cerberus piece 6):

1. Register the ambient defaults in `config/initializers/atlas_rb.rb`:

   ```ruby
   AtlasRb.configure do |config|
     config.default_nuid         = -> { Current.nuid }
     config.default_on_behalf_of = -> { Current.on_behalf_of }
   end
   ```

2. Drop `nuid: Current.nuid` from regular call sites:

   ```ruby
   # Before
   AtlasRb::Work.find(id, nuid: Current.nuid)
   AtlasRb::Blob.create(work_id, path, name, nuid: Current.nuid)

   # After
   AtlasRb::Work.find(id)
   AtlasRb::Blob.create(work_id, path, name)
   ```

   Sites that need a *different* NUID than `Current.nuid` keep their
   explicit kwarg — caller value always wins.

3. Rewrite destructive call sites:

   ```ruby
   # Before
   AtlasRb::Work.destroy(id, nuid: Current.nuid)
   AtlasRb::Work.restore(id, nuid: Current.nuid)

   # After
   AtlasRb::Admin::Work.destroy(id, confirm: :i_understand)
   AtlasRb::Admin::Work.restore(id)
   ```

4. Rewrite the SSO callback's user-provisioning call:

   ```ruby
   # Before
   AtlasRb::User.find_or_create(nuid: ..., groups: ...)

   # After
   AtlasRb::System::User.find_or_create(nuid: ..., groups: ...)
   ```

5. Add the system token to encrypted credentials:

   ```yaml
   # config/credentials.yml.enc
   atlas_system_token: <value Atlas's require_auth recognises as :system>
   ```

   This is paired on the Atlas side with
   `Rails.application.credentials.system_token` (Atlas 0.6.20+).

## 0.0.101

- Threaded `nuid:` through the remaining gaps in `Work` / `Collection`
  / `Community` / `FileSet` / `Delegate`.
- Fixed `multipart({})` bug at `file_set.rb:83` — the literal `{}`
  bound to the `nuid` positional arg, so the gem emitted
  `User: NUID {}` on the wire for `FileSet.update`.

## 0.0.100 and earlier

See `git log` for pre-1.0 history.
