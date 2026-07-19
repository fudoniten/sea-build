# Standalone game-site static-site deploy-rs profile.
#
# game-site ships as its own profile rather than being baked into any host's
# system closure, so the static bundle can be updated without a full rebuild.
# Activation links the current bundle into the path nginx serves and reloads
# nginx -- it never restarts sshd, so magic-rollback health checks pass on a
# live deploy (no --boot needed). The interpolated store path keeps the bundle
# in the profile closure, so it is copied to the host and pinned as a GC root.
# Target it alone with `.#deploy.<host>.game-site`.
{ inputs, lib }:

let
  inherit (inputs) deploy-rs game-site;

  # Hosts that serve the game-site bundle.
  hosts = [ "arx" ];

  package = game-site.packages.x86_64-linux.default;

in hostname:
lib.optionalAttrs (lib.elem hostname hosts) {
  game-site = {
    user = "root";
    profilePath = "/nix/var/nix/profiles/game-site";
    path = deploy-rs.lib.x86_64-linux.activate.custom package ''
      mkdir -p /srv/www
      ln -sfn ${package} /srv/www/games
      systemctl reload nginx
    '';
  };
}
