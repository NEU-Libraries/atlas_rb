# Changelog

## 1.15.0

### Changed — the transport reuses connections instead of opening one per request

`FaradayHelper` built a fresh `Faraday.new` for every call, and Faraday's
default `net_http` adapter wraps each request in its own `Net::HTTP#start`
block and closes the socket after it. So every Atlas call paid a TCP handshake,
and under TLS a full TLS handshake on top of that.

The three builders now hand back an `AtlasRb::Transport::Proxy` over a shared,
pooled connection — one per shape (`:json`, `:multipart`, `:system`) and base
URL — using the `net_http_persistent` adapter. The proxy answers `get`, `post`,
`patch`, `put` and `delete` like a `Faraday::Connection` and forwards a block to
the request, so no call site changes.

Measured on loopback inside the container, 100 requests per run, self-signed
ECDSA P-256:

| transport | before | after |
|---|---|---|
| plain HTTP | 1.21ms/req | 0.75ms/req |
| TLS | 3.07ms/req | 0.31ms/req |

Add a round trip each for TCP and TLS over a real network. The largest win is
a sequential migration script, where the saving is elapsed time and nothing
hides it; it also removes the `TIME_WAIT` pressure of a socket per request.

Per-request state — the signed assertion, the `Idempotency-Key`, query params —
now rides on the request rather than being baked into the connection, which is
what makes a connection safe to share. The pool is process-wide, not
thread-local, so a fan-out on short-lived threads reuses it.

Two knobs, both optional:

```ruby
AtlasRb.configure do |config|
  config.connection_pool_size    = 16  # sockets per Atlas host
  config.connection_max_requests = nil # cap only if a proxy in front caps it
end
```

`AtlasRb::Transport.reset_connections!` closes every pooled socket and drops the
cached connections. A suite that boots and tears down a real server should call
it between examples.

### Fixed — the signing key is parsed once, not per request

`assertion_signing_key` is configured as a callable returning a PEM, and
`OpenSSL::PKey.read` ran on every request: 0.367ms against the 0.072ms ES256
signature it exists to produce. The parse is now cached and re-run only when the
PEM changes.

## 1.14.0

### Added — `Blob.find_many_versions`, the batch version-history read

`AtlasRb::Blob.versions` takes one id, so a caller holding a set of Blob noids
had to fan out a request per noid. The admin file-manage listing does exactly
that: it reads every replaceable Blob on a Work, which on a multipage Work is
one request per page binary, all before the page returns a byte.

`Blob.find_many_versions` wraps Atlas's `POST /files/find_many_versions` and
answers one `versions`-shaped envelope per Blob in a single call.

```ruby
assets  = AtlasRb::Work.assets(work_noid).reject { |a| a[:uri].present? }
history = AtlasRb::Blob.find_many_versions(assets.map(&:noid))
                       .index_by { |h| h["blob_id"] }
history[assets.first.noid]["versions"].first["revision"] # => 3
```

The result is **unordered** and **may be shorter than the input** — an id that
resolves to nothing, or to a resource that is not a Blob, is dropped silently.
Index by `"blob_id"`.

Requires Atlas >= 0.6.161. Admin-gated exactly like `.versions`. `.versions`
itself is unchanged.

## 1.13.2

### Documentation — point `children` callers at the batch resolver

`Collection.children` and `Community.children` answer noids only, and nothing
on either method said how to turn those noids into something renderable. The
obvious reading — `find` per noid — costs a round-trip per child. Both now
point at {AtlasRb::Resource.find_many} for one-call resolution, and at
{AtlasRb::Resource.descendant_works} for a whole subtree.

No behaviour change.

## 1.13.1

### Fixed — `Maintenance.read` could not name an acting principal

`AtlasRb::Maintenance.read` took no `nuid:`, unlike every other read binding,
so on the relay-signing path it had no NUID to sign into the assertion `sub`
and raised `ConfigurationError`. It worked only in BYO-JWT mode or when the
host configured `AtlasRb.config.default_nuid`. It now takes `nuid:` and
`on_behalf_of:` like its neighbours.

```ruby
AtlasRb::Maintenance.read(nuid: current_user.nuid)
```

`.write` is unchanged — it runs on the system connection, which deliberately
never consults ambient identity.

## 1.13.0

### Added — maintenance mode no longer passes through silently

Atlas can now hold a repository-wide read-only window, refusing every write
with `503` + `error: "read_only_mode"`. Before this release a `503` reached
neither `RaiseOnStaleResource` (409-only) nor `RaiseOnResourceError`
(403/422-only), and the body carries no `"work"` / `"collection"` key — so the
binding unwrapped `nil` and returned it. The write silently no-opped and the
caller's UI reported success. During a window that meant a librarian saving
metadata, seeing no error, and losing the edit.

`AtlasRb::Middleware::RaiseOnReadOnlyMode` now raises
`AtlasRb::ReadOnlyModeError` on that pair, on every path and all three
connection builders. It carries `#code` and `#retry_after` (from Atlas's
`Retry-After` header).

```ruby
rescue AtlasRb::ReadOnlyModeError => e
  e.retry_after  # => 900
```

It is keyed on the discriminator as well as the status, so a bodyless `503`
from a reverse proxy while Atlas restarts still passes through untouched.

`AtlasRb::Maintenance.read` / `.write` read and set the flag. `.read` sits on
the authenticated read floor and is answered while the window is open, so a
client can always see the flag it is honouring; `.write` is system-gated.

A minor bump rather than a patch: a new exception can now raise where callers
previously got `nil`.

**This release requires Atlas 0.6.159 or newer** for the `/maintenance`
endpoints. The middleware is inert against an older Atlas, which never sends
the discriminator.

## 1.12.0

### Changed — index rows arrive flat

Atlas no longer wraps each row of a paginated index in its type name. `GET
/works` used to hand back `{"work" => {...}}` per row; it now hands back the
summary itself. The same applies to `/collections`, `/communities`, `/blobs`,
`/file_sets`, `/people` and `/compilations`. A single resource is still wrapped
in its type name — only rows inside a named collection changed.

```ruby
AtlasRb::Work.list(in_progress: true)["works"].map { |row| row["id"] }
# was: row["work"]["id"]
```

`Person.list` and `Person.resolve` unwrapped the row for you, so their return
value is unchanged. `Work.list` and `Compilation.list` return Atlas's envelope
as-is, so callers reading `row["work"]` or `row["compilation"]` must drop that
step.

**This release requires Atlas 0.6.158 or newer.** Pairing 1.12.0 with an older
Atlas makes `Person.list` and `Person.resolve` return rows of nils.

### Fixed — `Work.list` documentation

The envelope was described as matching `Community.children`, which returns a
bare array of noid strings — a third shape. It carries `works` and
`pagination`.

## 1.11.0

### Added — `Work.associations` / `.associate` / `.disassociate`

DRS v1 let a depositor declare that one object is the codebook, figure,
transcription, instructional material or supplemental material **for** another.
The two objects stayed separate records, and each one's page showed the link
from its own end. Atlas now records this again, and these three bindings reach
it.

```ruby
AtlasRb::Work.associate(codebook_id, dataset_id, type: "is_codebook_for")
AtlasRb::Work.associations(dataset_id)
# => {"outbound" => {}, "inbound" => {"is_codebook_for" => ["w-codebook"]}}
AtlasRb::Work.disassociate(codebook_id, dataset_id, type: "is_codebook_for")
```

All three return the same shape, so a mutation needs no follow-up read.
`outbound` is what the Work asserts; `inbound` is what other Works assert about
it. The edge is stored once, on the asserting Work, and Atlas derives the other
direction — so the two can never drift apart.

The five predicates are in `AtlasRb::Work::ASSOCIATION_TYPES`, for building a
select box without hard-coding the vocabulary. A sixth needs an Atlas release,
so the list cannot get ahead of the server.

Writes are admin / devolved-admin only: the claim renders on the target's page
too, and the asserter often holds no rights over it.

### Added — `WorkAssociationError`

A `422` on an association path now raises a typed error carrying `#code`
(`invalid_type`, `target_not_found`, `invalid_target_type`,
`self_association`, `tombstoned_work`, `tombstoned_target`). A `403` raises the
existing `ForbiddenError`. Without these the binding would return the envelope
as if it were a success and the rejection would be silently discarded.

### Changed — the `destroy` docstrings now describe a purge

`Admin::{Work,Collection,Community}.destroy`, `FileSet.destroy` and
`Blob.destroy` previously promised more than the server did: the docstrings
claimed a cascade and removal "from Atlas storage" while the server deleted one
Postgres row and one Solr document, leaving every byte on disk.

Atlas has since made `destroy` mean what the docstrings said, and they are
updated to match what it now does — including the parts they never mentioned:

- Deleting a Blob or a FileSet removes the **whole OCFL object**, so every
  retained revision goes, not only the current one. `versions` and `rollback`
  have nothing left to work with afterwards.
- `Admin::Collection.destroy` and `Admin::Community.destroy` refuse with a
  `422` (`has_children`) while the container still holds a member, **including
  a tombstoned one**. That is stricter than `tombstone`, which counts only live
  members: a purge cannot be undone, so a member left behind is orphaned for
  good.

No signature changed; this release is additive.

## 1.10.1

### Added — `Work.mark_incomplete` / `Work.clear_incomplete`

A Work can now carry a second lifecycle state. `complete` says the deposit
finished; `incomplete` says something downstream of it gave up. Before this
there was no way to record that at all: every give-up handler wrote a
`Rails.logger.warn` and nothing else, so a deposit whose PDF rendition
exhausted its retries ended up with no rendition and no thumbnail, the
depositor was not told, and no surface listed it.

```ruby
AtlasRb::Work.mark_incomplete(work_id, reason: "pdf_rendition_gave_up")
AtlasRb::Work.clear_incomplete(work_id)
```

`reason` is a machine token, one per give-up handler. Atlas holds it as an
opaque string and does **not** validate it against a list, so the vocabulary
belongs to the caller and a new token needs no Atlas release. Map it to display
text at the point of use, with a fallback for a token the view has not been
taught.

The flag **never hides** the Work. A record with its file, title and metadata
but one missing derivative is degraded, not broken, and stays readable.

Both bindings return the updated Work. `mark_incomplete` is idempotent and the
last reason wins; `clear_incomplete` is idempotent too, and clears the flag and
the reason together. Call it when a later run of the same job succeeds, which
makes the state self-healing.

### Added — `incomplete:` filter on `Work.list`

`AtlasRb::Work.list(incomplete: true)` is the staff list of Works whose
pipeline gave up, the sibling of the existing `in_progress:` "what's stuck?"
view. The two are independent and combine: `in_progress: false, incomplete:
true` reads as "finished, but degraded".

Work summaries in the response now carry `incomplete` and `incomplete_reason`
alongside `in_progress`.

## 1.10.0

### Removed — `title` on `Person.create` and `Person.update`

Atlas no longer holds a job title on a Person. The attribute claimed
Blacklight's title namespace, where display and sorting expect the Person's
name, so Atlas dropped it rather than renamed it: the field was display-only,
optional, and absent from v1.

The parameter therefore had nothing to write to. Atlas ignores an unknown key in
a write body, so a caller that kept passing `title:` had its value discarded
with no error and nothing in a log. That is the reason to remove the parameter
rather than leave it accepted and inert.

**Breaking.** `Person.create(…, title: "Professor")` now raises
`ArgumentError: unknown keyword: :title`. Drop the argument at the call site;
there is no replacement field.

## 1.9.4

### Fixed — write bindings parsed the response body without checking the status

A write aimed at a resource that is not there raised
`JSON::ParserError: unexpected end of input at line 1 column 1`. Atlas is
correct here: it answers `head :not_found`, a `404` with an empty body. The
bindings then handed that empty body to `JSON.parse`.

The message named neither the verb nor the resource, so an operator whose XML
manifest carried a PID from another environment got five identical parser
errors and nothing to act on. `Resource.fetch_resource` already guarded the
**read** path against exactly this; the write half never got the same
treatment.

Every `create` / `update` / `metadata` / `parent` / `rollback` and sibling
across `Work`, `Collection`, `Community`, `Blob`, `FileSet`, `Compilation` and
`Person` now goes through a `write_resource` companion:

- `404` → {AtlasRb::NotFoundError}, naming the verb and path.
- `410` → the parsed body, as on the read path: an Idempotency-Key replay whose
  resource has since been tombstoned answers `410 Gone` *with* the tombstone.
- any other non-2xx → {AtlasRb::ResourceError}, carrying Atlas's status + body.
- `2xx` → the parsed body, exactly as before.

`NotFoundError` subclasses `ResourceError`, so a caller that only wants "the
write failed" rescues the parent.

Note the deliberate asymmetry with the read path, which keeps returning `nil`
on a `404`: that answers a read, but not a write — the caller asked for a
change and did not get one.

Blast radius is which exception surfaces, not whether one does. The typed
`403` / `422` translations raise inside the Faraday stack, so they still fire
first; a `422` the middleware passes through on purpose (`tombstone`'s
`has_live_children`) is unaffected, because `tombstone`, `destroy` and
`complete` return the raw response and never parsed.

## 1.9.3

### Added — `depositor:` on `Collection.create` and `Community.create`

`AtlasRb::Collection.create(parent_id, depositor: "000000099")` (and the same
on `Community.create`) stamps a container's intellectual owner, matching what
`Work.create` has always supported. Atlas already read the param; only the
bindings couldn't pass it.

The case it unblocks is seeding an institutional tree: the caller acts as an
admin (the only identity whose wildcard carries a whole seed sequence) while
attributing the containers to the anonymous NUID, since nobody personally owns
them and access is via Grouper groups. That matters now that a depositor
carries edit rights on their own resource — a container stamped with a real
person's NUID would hand them edit over that whole subtree.

Omitted, the depositor still falls through to the acting user, so existing
callers are unaffected.

### Added — typed errors for Atlas's container-create `403` and ACL-write `422`

Atlas gained two refusals that the bindings previously swallowed, because
`RaiseOnResourceError` was scoped to the re-parent / linked-member /
Compilation / derivative-permissions / upload paths:

- **A refused create.** `POST /{works,collections,communities}` now `403`s when
  the caller holds no edit rights on the destination container. The binding's
  `["collection"]` unwrap returned `nil`, so the caller's next `.id` raised
  `NoMethodError` — an unhandled 500 instead of an authorization failure. Now
  {AtlasRb::ForbiddenError}, carrying `action: "create_child"` and the parent
  container's class as `subject`.
- **A refused ACL write.** `PATCH /{type}/:id` with `metadata[permissions]`
  now `422`s with `visibility_exceeds_parent` when the read audience would
  exceed the structural container. The parsed envelope looked like a success
  payload, so a user's visibility edit was discarded silently. Now
  {AtlasRb::PermissionsError}, keyed on the `error` code rather than the path —
  the same endpoint's other `422`s (tombstone's `has_live_children`) still pass
  through untouched, which a path rule could not distinguish.

The create branch matches the three paths exactly and only on `POST`, so member
actions under the same prefix and the index `GET` are unaffected.

## 1.9.2

### Added — `read_only:` on `System::Token.mint`

`AtlasRb::System::Token.mint(nuid:, read_only: true)` mints a token Atlas
structurally restricts to read-shaped actions, independent of what `nuid`
could otherwise do — the shape to hand to a non-human caller (e.g. an Atlas
MCP client) that must never be able to mutate the repository. Omitted, mint
is unchanged (full-privilege, as before).

## 1.8.8

### Added — type-agnostic current MODS (`Resource.mods`)

New polymorphic wrapper `AtlasRb::Resource.mods(id, kind = nil, …)` for Atlas's
`GET /resources/:id/mods` — fetch the current descriptive MODS of any Modsable
resource (Work / Collection / Community) by NOID, without knowing its type.
Returns the raw response body, mirroring the typed `Work.mods` / `Collection.mods`
/ `Community.mods`; output is byte-identical to the typed routes. `kind` omitted
yields the JSON projection (server default); pass `"xml"` for MODS XML.

Collapses the `children → find_many (for klass) → dispatch-by-klass` two-step a
bulk MODS exporter needed just to pick the typed MODS URL down to one call per
member. `404` (unknown id / non-Modsable / no MODS) comes back as an empty body.

## 1.8.7

### Added — personal-access token lifecycle (`System::Token.mint` / `.revoke`)

New system-context binding for the `POST /nuid` / `DELETE /nuid` endpoints so a
host app can mint and revoke a user's personal-access JWT (`ATLAS_JWT`, BYO-JWT
mode). Both are :system-gated on Atlas ("minting for an arbitrary NUID is
'become anyone'"), so they authenticate via `FaradayHelper#system_connection`
(hard-pinned system token + `User: NUID` header) — never the ambient-user
relay-signing path — mirroring `System::User`.

- `AtlasRb::System::Token.mint(nuid:)` → the JWT (`String`), or `nil` when the
  NUID has no Atlas User row (404). The token is full-privilege for that user,
  1-week TTL, single-jti.
- `AtlasRb::System::Token.revoke(nuid:)` → `true` on success (204), `false` on
  404. Rotates the user's jti (single-jti model → all outstanding tokens die at
  once). "Regenerate" is `revoke` followed by a fresh `mint`.

Unblocks Cerberus's "My DRS → Programmatic access" section (generate / regenerate
/ revoke), gated to the `northeastern:drs:repository:api` Grouper group.

## 1.8.5

### Fixed — `find` returns a tombstone (`410`) instead of raising

The status-aware `find` (1.8.3) raised `AtlasRb::ResourceError` on any non-2xx
other than `404`. But Atlas returns a **tombstoned** resource as `410 Gone`
**with its full body** (carrying `tombstoned` / `tombstoned_at` / `tombstoned_by`)
— a "gone, but here it is" tombstone, not an error envelope. `fetch_resource`
now parses a `410` like a `2xx`, so every typed `find` (`Work` / `Collection` /
`Community` / `FileSet` / `Person` / `Compilation` / `Blob` / `Delegate` and the
polymorphic `Resource.find`) yields the tombstone rather than raising. Genuine
error statuses (400/401/403/422) still raise; a `404` still returns `nil`.

## 1.8.4

### Added — per-tier derivative-visibility policy (`Work.set_derivative_permissions`)

New binding for the departmental "each download rendition has its own permissions"
model: `AtlasRb::Work.set_derivative_permissions(id, policy:, …)` PATCHes a per-tier
read policy to `PATCH /works/:id/derivative_permissions`. `policy` is a map of tier
(`small` / `medium` / `large` / `service`) => array of read-group tokens (the resource
vocabulary: `"public"`, Grouper group names, `[]` = private). Whole-object replace;
omitted tiers inherit by cascade (an absent tier inherits the next lower-resolution
tier; `small` inherits the Work). Atlas enforces two invariants — a tier may not be
more visible than the Work, and visibility must narrow as resolution grows
(`service` ⊆ `large` ⊆ `medium` ⊆ `small`).

The effective per-Delegate gate surfaces on `Work.assets` entries as `gated` (must be
authorized, not linked directly) and `permission` (the effective read-group set;
`null` for guests). No `assets` change is needed — the new fields flow through the
existing polymorphic Mash. The gate is advisory: Cerberus and the IIIF auth layer
enforce it.

A `422` rejection (`tier_exceeds_resource` / `tier_ordering_violation` /
`unknown_tier`) now raises the typed `AtlasRb::DerivativePermissionsError` (with `code`
/ `resource_id`) via `RaiseOnResourceError`, mirroring the re-parent / linked-member /
Compilation mappings; a `403` raises `AtlasRb::ForbiddenError`; a `409` raises
`AtlasRb::StaleResourceError`.

## 1.8.3

### Changed — `find` is status-aware (stops swallowing Atlas error envelopes)

Every typed single-resource reader — `Resource.find` (the polymorphic resolver)
and the `Work` / `Collection` / `Community` / `FileSet` / `Person` /
`Compilation` / `Blob` / `Delegate` overrides — now routes through a shared
status-aware read path instead of blindly `JSON.parse`-ing the body and
unwrapping a fixed key.

Previously, any non-2xx that wasn't a re-parent/linked-member/Compilation/upload
signal (which `RaiseOnResourceError` already translates) passed straight through:
Atlas renders its auth/validation failures as a JSON envelope (`{ "error" => …}`,
status 400/401/403/422), so `JSON.parse(body)["work"]` found no `"work"` key and
returned **`nil`**. Callers then dereferenced that `nil` far from the cause — the
canonical symptom being `undefined method 'tombstoned' for nil`, a 500 surfaced
nowhere near the request that actually failed.

Now:

- **`404` → `nil`** — a clean "not found" (and no more `JSON::ParserError` on the
  empty `head :not_found` body, which is what a missing id used to raise).
- **any other non-2xx → `AtlasRb::ResourceError`** — a new typed error carrying
  Atlas's `status`, `body`, and `response`, raised **at the boundary** so the
  real cause (e.g. `GET /works/abc → 401: {"error":"invalid bearer token"}`) is
  attributable everywhere `find` is used.
- **`2xx`** → unchanged (the unwrapped resource).

Authorization failures on the narrow re-parent / linked-member / Compilation
write paths still surface as `AtlasRb::ForbiddenError` via
`RaiseOnResourceError`; `ResourceError` is the catch-all for the read path that
middleware intentionally does not cover.

**Behavior change to note:** `find` of a missing id now returns `nil` rather than
raising `JSON::ParserError`. Callers that relied on the parse error (none known)
should nil-check instead.

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
