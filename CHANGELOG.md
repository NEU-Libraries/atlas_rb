# Changelog

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
