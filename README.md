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

Every request reads two environment variables:

| Variable      | Purpose                                                       |
|---------------|---------------------------------------------------------------|
| `ATLAS_URL`   | Base URL of the Atlas API (e.g. `https://atlas.example.edu`). |
| `ATLAS_TOKEN` | Bearer token used in the `Authorization` header.             |

User-scoped calls (currently only `AtlasRb::Authentication`) additionally
accept an NUID — the Northeastern University ID — which is forwarded in a
`User: NUID <nuid>` header.

```ruby
ENV["ATLAS_URL"]   = "https://atlas.example.edu"
ENV["ATLAS_TOKEN"] = "..."
```

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
| `AtlasRb::Resource`    | Generic resolver and permissions lookup.                                  |
| `AtlasRb::Reset`       | Test-only — wipes Atlas state via `GET /reset`.                           |

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
AtlasRb::Work.files(work.id)

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
