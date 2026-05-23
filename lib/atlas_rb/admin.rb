# frozen_string_literal: true

module AtlasRb
  # Operator-only destructive lifecycle operations.
  #
  # Houses methods whose blast radius warrants more friction than the
  # regular CRUD surface: `destroy` (hard delete — content and metadata
  # are unrecoverable) and `restore` (un-tombstone — reverses a withdraw,
  # typically driven from a Rails console session or a future admin UI).
  #
  # ## Why a separate namespace
  #
  # The class itself is the marker: `AtlasRb::Admin::Work.destroy(...)`
  # is structurally distinct from `AtlasRb::Work.update(...)`. Mass-edits
  # and code-search across a consumer codebase can quickly find every
  # destructive call site by grepping `AtlasRb::Admin::`.
  #
  # ## `confirm: :i_understand`
  #
  # Every `destroy` method requires a `confirm: :i_understand` kwarg.
  # Forgetting (or misspelling) it raises `ArgumentError` before any
  # request goes out. The value is arbitrary — the point is that
  # boilerplate-generated or copy-pasted call sites can't accidentally
  # delete production data. `restore` does **not** require the marker;
  # restoring tombstoned content is reversible (by tombstoning again)
  # so the same friction isn't warranted.
  module Admin
  end
end
