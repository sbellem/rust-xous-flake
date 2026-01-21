# rust xous flake
An experimental nix flake for [rust xous](https://github.com/betrusted-io/rust).

[![FlakeHub](https://img.shields.io/endpoint?url=https://flakehub.com/f/gluonix/rust-xous-flake/badge)](https://flakehub.com/flake/gluonix/rust-xous-flake)

Add `rust-xous` to your `flake.nix`:

```nix
{
  inputs.rust-xous.url = "https://flakehub.com/f/gluonix/rust-xous-flake/*";

  outputs = { self, rust-xous }: {
    # Use in your outputs
  };
}
```
