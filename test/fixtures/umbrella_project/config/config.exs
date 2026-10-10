import Config

# The machina-ex umbrella's settings: an absolute contracts_dir makes every app resolve the same
# directory whichever app `mix` runs in; Covenant.root/0 is its parent, and test_paths resolve
# against that root.
config :covenant,
  contracts_dir: Path.expand("../contracts", __DIR__),
  test_paths: ["apps/*/test/contract"]
