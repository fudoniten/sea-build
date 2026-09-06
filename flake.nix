{
  description = "Deployment using deploy-rs";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-26.05";

    deploy-rs = { url = "github:serokell/deploy-rs"; };

    utils.url = "github:numtide/flake-utils";

    fudo-nixos = {
      url = "github:fudoniten/nixos-config/26.05-aegis";
      inputs = {
        fudo-entities.follows = "fudo-entities";
        nixpkgs.follows = "nixpkgs";
      };
    };

    fudo-entities = {
      url = "git+ssh://git@github.com/fudoniten/fudo-entities";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Deployed on its own as a standalone deploy-rs profile, so the static
    # site can ship without a full system rebuild. Kept out of fudo-nixos
    # so bumping it here doesn't invalidate any host's system closure.
    game-site = {
      url = "github:fudoniten/game-site";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, utils, deploy-rs, fudo-nixos, fudo-entities, game-site
    , ... }@inputs:
    with nixpkgs.lib;
    let
      defaultSshOpts = [ "-oControlMaster=no" "-oControlPath=none" ];

      # Every node is x86_64-linux (see deploy-rs.lib.x86_64-linux below), and
      # the node set is built outside eachDefaultSystem, so the Aegis
      # ciphertext derivations need a pkgs of their own here.
      hostPkgs = import nixpkgs { system = "x86_64-linux"; };

      # Hosts that serve the game-site static bundle via its own profile.
      gameSiteHosts = [ "arx" ];
      gameSitePackage = game-site.packages.x86_64-linux.default;

      # Hosts that take their secrets from their own profile rather than from
      # the system closure.
      #
      # Read off the host's own configuration rather than listed here: the
      # decrypt units read `aegis.secrets.runtimePath`, so taking the same
      # value as this profile's `profilePath` is what makes the units and the
      # profile point at the same directory by construction. A list here could
      # disagree with the host, and the failure would be secrets that decrypt
      # into a path nothing reads.
      aegisRuntimePath = hostname:
        let cfg = fudo-nixos.nixosConfigurations.${hostname}.config.aegis.secrets;
        in if cfg.enable then cfg.runtimePath else null;

      allNodes = let
        nodeEntities = filterAttrs (_: hostOpts: hostOpts.deploy.enable)
          fudo-entities.entities.hosts;
      in mapAttrs (hostname: hostOpts:
      let
        aegisPath = aegisRuntimePath hostname;
        aegisCiphertext = if aegisPath == null then
          null
        else
          fudo-nixos.lib.aegisProfile.forHost hostPkgs hostname;
      in {
        hostname = fudo-entities.lib.getHostIpv4 hostname;
        sshOpts = defaultSshOpts ++ hostOpts.deploy.ssh-options;
        sshUser = "root";

        inherit (hostOpts) site domain;

        # Batch targets. deploy-rs merges `groups` from deploy -> node ->
        # profile and filters on `--groups`, so tagging the node here is all
        # that `deploy .# --groups kerberos` needs.
        #
        # Membership is derived, not listed: fudo-nixos reads each host's
        # Aegis roles (accurate because that host's secrets depend on them
        # being accurate) and its profile (which is what says "desktop" --
        # Aegis has no opinion, since a desktop needs no special secrets).
        # A host that gains a role gains the group, with nothing to update
        # here.
        #
        # `site-*` and `domain-*` are deliberately absent: the deploy outputs
        # below already cover those, and a group of the same name would just
        # be a second spelling of `.#site-burg`.
        groups = fudo-nixos.lib.deployGroups.forHost {
          # Policy rather than a property of the host, so it cannot be
          # derived from anything: the canary is whichever host you would
          # rather find out about a bad release on first.
          extra = { };
        } hostname hostOpts;

        # Deploy the system profile first so nginx exists before the
        # game-site profile reloads it (attr order alone would run the
        # alphabetically-earlier "game-site" first).
        #
        # "aegis" is system-first for a different reason. Its activation
        # refuses ciphertext whose manifest does not match the one the running
        # generation was built against, and that fingerprint arrives with the
        # system profile -- so on a manifest change, aegis-first would be
        # rejected by design. Rotations, where the manifest is untouched, are
        # the case that skips the system profile entirely.
        profilesOrder = [ "system" ] ++ (optional (aegisPath != null) "aegis")
          ++ (optional (elem hostname gameSiteHosts) "game-site");

        profiles = {
          system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos
              fudo-nixos.nixosConfigurations."${hostname}";
          };
        } // (optionalAttrs (aegisPath != null) {
          # The host's .age files and manifest, and nothing else -- about 29 KB
          # against the 13 MB of aegis-secrets that otherwise rides in every
          # system closure.
          #
          # The point is not the size. It is that the ciphertext's store path
          # is baked into every decrypt script, so rotating one secret changes
          # the closure of every host that shares the repo, and a rotation --
          # the cheapest thing Aegis does -- costs a full system deploy of the
          # fleet. Split out, `aegis reencrypt` is followed by a deploy of this
          # profile alone. The system generation only has to move when the
          # manifest does, which is when a secret is added, moved or re-owned,
          # and that almost always arrives with the service that consumes it.
          #
          # Target it alone with `.#deploy.<host>.aegis`.
          aegis = {
            user = "root";

            # Profile-level groups are merged with the node's and filtered
            # per (node, profile) pair, so this makes
            #   deploy .# --groups aegis
            # a fleet-wide secrets deploy that touches no system profile.
            # With `--groups kerberos` it intersects the node's groups the
            # usual way, so `--groups aegis --groups kerberos` is "the KDCs'
            # secrets" -- which is the shape a role-secret rotation wants.
            groups = [ "aegis" ];

            # The same path the decrypt units read from: both sides take it
            # from the host's `aegis.secrets.runtimePath`, so they cannot be
            # pointed at different directories.
            profilePath = aegisPath;

            # The store path is interpolated rather than reached through
            # $PROFILE, as game-site does above: it keeps the ciphertext in
            # the profile's closure (so it is copied to the host and pinned as
            # a GC root) and it lets the verifier run against exactly the
            # content that is about to be linked.
            #
            # The units read through the profile link, not this path. That is
            # the whole point -- the link is what stays constant across
            # rotations, so the system generation does not have to move.
            # `hosts/<h>/../../roles/<r>` resolves correctly either way: the
            # profile's hosts/ and roles/ both come from this one derivation.
            path = deploy-rs.lib.x86_64-linux.activate.custom aegisCiphertext ''
              set -euo pipefail

              # Verify before restarting anything. A decrypt unit that is
              # restarted and then fails is not recoverable here: sshd
              # `Requires=` its host-key units, so systemd propagates the
              # failure and stops sshd, magic-rollback cannot reconnect, and
              # rolling this profile back does not bring sshd up again.
              #
              # aegis-verify-profile decrypts every secret to /dev/null with
              # the identity its unit would use and checks the manifest
              # fingerprint against the one this system generation was built
              # with. It writes nothing and touches no unit, so a profile that
              # cannot be decrypted -- or that belongs to a different manifest
              # -- is refused while the host still runs the old one.
              #
              # deploy-rs has already pointed the profile link at this closure
              # by the time we run (nix-env --set precedes activation), so a
              # failure here leaves the link ahead of the units until rollback.
              # autoRollback restores the previous generation *and* re-runs its
              # activation script, which relinks the old ciphertext and
              # restarts the units against it -- so the recovery is complete
              # rather than merely reverting the symlink.
              /run/current-system/sw/bin/aegis-verify-profile ${aegisCiphertext}

              # Restart in the order Aegis generated: by phase, and SSH host
              # keys last within each phase, so anything else that is going to
              # fail does so while sshd is still up to carry the rollback.
              while read -r unit; do
                [ -n "$unit" ] || continue
                echo "aegis: restarting $unit"
                systemctl restart "$unit"
              done < /etc/aegis/profile-units
            '';
          };
        }) // (optionalAttrs (elem hostname gameSiteHosts) {
          # Standalone static-site profile. Activation links the current
          # bundle into the path nginx serves (/srv/www/games) and reloads
          # nginx -- it never restarts sshd, so magic-rollback health checks
          # pass on a live deploy (no --boot needed). The interpolated store
          # path keeps the bundle in the profile closure, so it is copied to
          # the host and pinned as a GC root. Target it alone with
          # `.#deploy.<host>.game-site`.
          game-site = {
            user = "root";
            profilePath = "/nix/var/nix/profiles/game-site";
            path = deploy-rs.lib.x86_64-linux.activate.custom gameSitePackage ''
              mkdir -p /srv/www
              ln -sfn ${gameSitePackage} /srv/www/games
              systemctl reload nginx
            '';
          };
        });
      }) nodeEntities;

      domains = fudo-entities.entities.domains;
      sites = fudo-entities.entities.sites;

    in utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
          deploy-rs-bin = "${deploy-rs.packages."${system}".deploy-rs}/bin/deploy-rs";
      in {
        apps = {
          deploy = {
            type = "app";
            program = toString (pkgs.writeShellScript "deploy" ''
              host="''${1:?usage: nix run .#deploy -- <hostname> [deploy-rs flags...]}"
              shift
              exec ${deploy-rs-bin} ".#$host" "$@"
            '');
            meta = {
              description = "Deploy to a host via deploy-rs";
              longDescription = ''
                Invokes deploy-rs against `.#<hostname>`, forwarding any remaining
                arguments. Useful flags include `-s`/`--skip-checks` and `--boot`
                (defer activation until the next reboot).
              '';
            };
          };
        };

        devShells = rec {
          default = deploy;
          deploy = pkgs.mkShell {
            buildInputs = [ deploy-rs.packages."${system}".deploy-rs ];
          };
        };
      }) // (mapAttrs' (domainName: _:
        nameValuePair "domain-${domainName}" {
          type = "deploy";

          autoRollback = true;
          magicRollback = true;

          nodes =
            filterAttrs (_: hostOpts: hostOpts.domain == domainName) allNodes;
        }) domains) // (mapAttrs' (siteName: _:
          nameValuePair "site-${siteName}" {
            type = "deploy";

            autoRollback = true;
            magicRollback = true;

            nodes =
              filterAttrs (_: hostOpts: hostOpts.site == siteName) allNodes;
          }) sites) // {
            deploy = with nixpkgs.lib; {
              type = "deploy";

              autoRollback = true;
              magicRollback = true;
              fastConnection = true;

              nodes = allNodes;
            };

            checks = builtins.mapAttrs
              (system: deployLib: deployLib.deployChecks self.deploy)
              deploy-rs.lib;
          };
}
