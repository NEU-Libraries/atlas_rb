# atlas_rb

Ruby client for the **Atlas** API — Northeastern University's institutional
digital repository.

The gem wraps Atlas's REST endpoints in a small set of class-method-only
modules, one per resource type. There is no client object to instantiate;
calls are made directly on the resource class:

```ruby
AtlasRb::Work.find("w-789")
```

## Installation

Add to your Gemfile:

```ruby
gem "atlas_rb"
```

Then `bundle install`, or install standalone with `gem install atlas_rb`.

## Configuration

### Environment variables

Every regular-path request reads two environment variables:

| Variable      | Purpose                                                       |
|---------------|---------------------------------------------------------------|
| `ATLAS_URL`   | Base URL of the Atlas API (e.g. `https://atlas.example.edu`). |
| `ATLAS_TOKEN` | Bearer token used in the `Authorization` header.              |

```ruby
ENV["ATLAS_URL"]   = "https://atlas.example.edu"
ENV["ATLAS_TOKEN"] = "..."
```

### Ambient identity (`default_nuid` / `default_on_behalf_of`)

Every resource method that talks to Atlas accepts a `nuid:` kwarg (the
acting user) and an `on_behalf_of:` kwarg (the user the call is being
made *for*, used by acting-as / view-as flows). Both are forwarded as
`User: NUID <nuid>` and `On-Behalf-Of: NUID <nuid>` headers
respectively.

Rather than threading them at every call site, register callables
once on app boot and let the gem read them as defaults:

```ruby
# config/initializers/atlas_rb.rb (Rails)
AtlasRb.configure do |config|
  config.default_nuid         = -> { Current.nuid }
  config.default_on_behalf_of = -> { Current.on_behalf_of }
end
```

The lambdas run **at request time** in whatever thread / fiber is
making the call, so they pick up per-request `Current.*` values that
`ApplicationController` set up via Devise + Rails 7's
`ActiveSupport::CurrentAttributes`. Background jobs work the same way
(ActiveJob ↔ CurrentAttributes integration restores the values on
`perform`).

Caller-passed kwargs always win over the configured defaults:

```ruby
# Uses Current.nuid:
AtlasRb::Work.find("w-789")

# Uses "X" — explicit kwarg overrides the default:
AtlasRb::Work.find("w-789", nuid: "X")
```

If neither the call site nor the registered default supplies a value,
no header is sent (legacy bearer-only path preserved).

### System-path credentials

Calls under `AtlasRb::System::*` (currently just SSO user provisioning)
authenticate as the seeded Atlas `:system` fixture, not as a real user.
They use a **separate** bearer token, looked up from
`Rails.application.credentials.atlas_system_token`. Storing it in
encrypted credentials rather than `ENV` halves the blast radius of a
`.env` leak — the user token and the system token can't both leak
through the same channel.

```yaml
# config/credentials.yml.enc (Cerberus side)
atlas_system_token: <token-Atlas-side-recognises-as-:system>
```

The system NUID itself is hardcoded as `AtlasRb::System::NUID =
"000000000"`, matching Atlas's seeded `:system` fixture row.

## Resource hierarchy

```
Community  →  Collection  →  Work
                              ↓
                            FileSet
                              ↓
                             Blob
```

| Class                  | Represents                                                                |
|------------------------|---------------------------------------------------------------------------|
| `AtlasRb::Community`   | Top-level org unit; may nest sub-Communities.                             |
| `AtlasRb::Collection`  | Holds Works; lives directly under a Community.                            |
| `AtlasRb::Work`        | Bibliographic unit (article, thesis, dataset…); MODS metadata lives here. |
| `AtlasRb::FileSet`     | Classified slot under a Work (e.g. `"primary"`, `"supplemental"`).        |
| `AtlasRb::Blob`        | The binary bytes; supports streaming downloads.                           |
| `AtlasRb::Authentication` | NUID → user record / group lookup.                                     |
| `AtlasRb::Resource`    | Generic resolver, permissions lookup, and audit-event history.            |
| `AtlasRb::Reset`       | Test-only — wipes Atlas state via `GET /reset`.                           |

## Namespace gradient: regular / Admin / System

Operations are split across three namespaces, calibrated to the blast
radius and the kind of authentication they need:

| Namespace            | What it does                                                                       | Auth                                                | Friction                              |
|----------------------|------------------------------------------------------------------------------------|-----------------------------------------------------|---------------------------------------|
| `AtlasRb::*`         | Regular CRUD (find / list / create / update / tombstone / metadata, etc.)          | User token (`ATLAS_TOKEN`) + acting user's NUID     | None — these are the daily-use paths. |
| `AtlasRb::Admin::*`  | Hard delete (`destroy`) and un-tombstone (`restore`) for Work / Collection / Community. | Same as regular — a real operator is acting.        | `destroy` requires `confirm: :i_understand`. |
| `AtlasRb::System::*` | System-context provisioning (currently just SSO user find-or-create).              | System token (`Rails.application.credentials.atlas_system_token`) + `User: NUID 000000000`. | The namespace itself is the marker — there is no way to call these as a non-system principal. |

```ruby
# Regular daily use — picks up Current.nuid via the configured default:
AtlasRb::Work.find("w-789")
AtlasRb::Work.tombstone("w-789")     # withdrawal (reversible)

# Operator-only, with a friction marker:
AtlasRb::Admin::Work.destroy("w-789", confirm: :i_understand)
AtlasRb::Admin::Work.restore("w-789")

# System-only — authenticates as Atlas's :system fixture:
AtlasRb::System::User.find_or_create(
  nuid: "001234567",
  groups: ["northeastern:staff", "drs:editors"]
)
```

The `AtlasRb::System::*` path never consults `AtlasRb.config.default_nuid`
or `default_on_behalf_of` — there is no ambient user context on system
calls.

### A note on `create` argument shapes

The CRUD-twin classes look the same but pass different parent IDs:

```ruby
AtlasRb::Community.create(nil)             # top-level community (parent_id: nil)
AtlasRb::Community.create("c-123")         # sub-community of c-123
AtlasRb::Collection.create("c-123")        # collection under community c-123
AtlasRb::Work.create("col-456")            # work under collection col-456 (collection_id, not parent_id)
AtlasRb::FileSet.create("w-789", "primary") # file_set under work w-789, classification "primary"
AtlasRb::Blob.create("w-789", path, name)  # blob under work w-789 with original filename preserved
```

`Work.create`, `FileSet.create`, and `Blob.create` each accept an optional
`idempotency_key:` kwarg for retry-safe bulk-deposit jobs. The caller
generates the UUID; the Atlas server enforces uniqueness scoped to the
acting user. A repeat call with the same key returns the originally-created
resource (or `410` if it has since been tombstoned). The gem does **not**
generate keys, cache responses, or retry — those concerns belong to the
calling job runner (e.g. Cerberus's Solid Queue).

```ruby
key = SecureRandom.uuid
AtlasRb::Work.create("col-456", idempotency_key: key)
AtlasRb::FileSet.create("w-789", "primary", idempotency_key: key)
AtlasRb::Blob.create("w-789", path, name, idempotency_key: key)
```

### Listing and monitoring Works

`Work.list` exposes the paginated `GET /works` index, with an optional
`in_progress:` filter for finding deposits that haven't yet been marked
complete. `Work.complete` flips a Work's `in_progress` flag to `false`
once a bulk-deposit job confirms all expected children have been deposited.

```ruby
AtlasRb::Work.list(in_progress: true)             # stuck deposits
AtlasRb::Work.list(in_progress: false, page: 2)   # completed deposits, page 2
AtlasRb::Work.complete("w-789")                   # mark w-789 done
```

### Audit-event history

`Resource.history` wraps Atlas's `GET /resources/<id>/history` endpoint
and returns the full envelope — `resource_id` plus a reverse-chronological
`events` array — as an `AtlasRb::Mash`. It is type-agnostic: pass any
Community, Collection, Work, FileSet, or Blob ID. Pagination is not yet
supported on the server side; the endpoint returns the full history in
one shot.

```ruby
result = AtlasRb::Resource.history("w-789")
result["resource_id"]            # => "w-789"
result["events"].first["action"] # => "update"
```

Authorization errors (`401` / `403`) are not caught here — they surface as
raw Faraday responses for the calling application's rescue layer.

### Re-parenting

`reparent` moves a resource to a new structural parent, binding Atlas's
`PATCH /<type>/:id/parent` endpoint. It mirrors `create`'s "single parent
id" shape and returns the updated resource (same shape as `find`), so the
caller sees the new `a_member_of` without a follow-up GET. Atlas enforces
the structural rules (type, cycle, tombstone guards) server-side and
synchronously cascades the ancestry index over descendants; rule
violations come back as `422`.

```ruby
AtlasRb::Collection.reparent("col-456", "c-999")  # move collection to community c-999
AtlasRb::Work.reparent("w-789", "col-999")         # move work to collection col-999
AtlasRb::Community.reparent("c-123", "c-999")      # nest community under c-999
AtlasRb::Community.reparent("c-123", nil)          # promote community to top of tree
```

Only `Community.reparent` accepts a `nil` destination (move to the top of
the tree) — the same way `Community.create(nil)` makes a top-level
community. A `nil` destination for a Work or Collection is rejected by
Atlas.

### Linked members (the DAG overlay)

A Work has exactly one structural parent (`a_member_of`, set by `create` /
`reparent`) but may additionally be a *linked* member of any number of
other Collections (`a_linked_member_of`). The linked-member bindings on
`Work` manage that overlay without ever moving the Work:

```ruby
AtlasRb::Work.linked_members("w-789")                 # => ["col-456", "col-457"]
AtlasRb::Work.add_linked_member("w-789", "col-456")    # => ["col-456"]  (updated list)
AtlasRb::Work.remove_linked_member("w-789", "col-456") # => []           (updated list)
```

All three return the Work's current linked Collection noids as a bare
array (mirroring `Collection.children`); the two mutations return the list
*after* the change, so no follow-up `linked_members` GET is needed.
Resolving those Collections' full contents is a Cerberus/Solr concern —
this gem never queries the index.

## End-to-end example

JSON responses come back as `AtlasRb::Mash` (a `Hashie::Mash` subclass), so
you can use dot access — `community.id` — or string-keyed access —
`community["id"]` — interchangeably. Both return the same value, so existing
string-keyed callers keep working.

```ruby
require "atlas_rb"

ENV["ATLAS_URL"]   = "https://atlas.example.edu"
ENV["ATLAS_TOKEN"] = "..."

# 1. Build the org structure (each create can optionally seed MODS metadata).
community  = AtlasRb::Community.create(nil,           "/tmp/community-mods.xml")
collection = AtlasRb::Collection.create(community.id, "/tmp/coll-mods.xml")
work       = AtlasRb::Work.create(collection.id,      "/tmp/work-mods.xml")

# 2. Upload a binary attached to the work, preserving the user-facing filename.
blob = AtlasRb::Blob.create(work.id, "/tmp/upload.tmp", "thesis.pdf")

# 3. List everything attached to the work.
AtlasRb::Work.assets(work.id)

# 4. Stream the binary back without buffering it in memory.
File.open("out.pdf", "wb") do |f|
  headers = AtlasRb::Blob.content(blob.id) { |chunk| f.write(chunk) }
  puts headers["content-type"]
end

# 5. Look up the acting user and their groups.
AtlasRb::Authentication.login("001234567")
AtlasRb::Authentication.groups("001234567")
```

## Generated documentation

Full API reference, including `@param` / `@return` / `@example` for every
method, is generated with [YARD](https://yardoc.org/):

```bash
bundle exec yard doc
open doc/index.html
```

`yard stats --list-undoc` should report 100% coverage.

## Development

```bash
bin/setup            # install dependencies
bin/console          # IRB with atlas_rb loaded
bundle exec rspec    # run tests
bundle exec rubocop  # lint
```

To cut a release, bump the version in `.version` (which `lib/atlas_rb/version.rb`
reads at load time) and run `bundle exec rake release`.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
