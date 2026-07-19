# Registry of standalone, per-component deploy-rs profiles.
#
# Each module below is a function `hostname -> { <profile-name> = <profile>; }`
# returning the profiles that component contributes to a host (an empty set for
# hosts it doesn't apply to). The aggregate `hostname -> profiles` function is
# merged into each node's `profiles` in flake.nix, alongside the base `system`
# profile.
#
# To add a component: drop a file in this directory exporting the same shape
# and list its import below. flake.nix stays untouched. Whole `inputs` is
# threaded through so a new component needing a new flake input doesn't change
# any signature here.
{ inputs, lib }:

let
  modules = [
    (import ./game-site.nix { inherit inputs lib; })
  ];

in hostname: lib.foldl' (acc: module: acc // (module hostname)) { } modules
