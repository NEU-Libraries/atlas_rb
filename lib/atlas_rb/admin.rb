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
  # The namespace itself is the marker: `AtlasRb::Admin::Resource.destroy(...)`
  # is structurally distinct from every other write. Mass-edits and code-search
  # across a consumer codebase can find every destructive call site by grepping
  # `AtlasRb::Admin::`. That is also why purge did not move onto
  # {AtlasRb::Resource} beside the other type-agnostic writes.
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
