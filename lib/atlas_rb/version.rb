# frozen_string_literal: true

module AtlasRb
  # Current gem version, read from the `.version` file at the gem root at load
  # time. Resolved relative to this file (not the process CWD) so a standalone
  # consumer — a headless BYO-JWT script run from anywhere — loads the gem's own
  # version rather than raising ENOENT (or reading some unrelated `.version`).
  VERSION = File.read(File.expand_path("../../.version", __dir__)).strip
end
