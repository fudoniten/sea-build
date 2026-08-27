{
  description = "Deployment using deploy-rs";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-26.05";

    deploy-rs = { url = "github:serokell/deploy-rs"; };

    utils.url = "github:numtide/flake-utils";

    fudo-nixos = {
      url = "git+ssh://git@github.com/fudoniten/nixos-config.git?ref=26.05-aegis";
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

      # Hosts that serve the game-site static bundle via its own profile.
      gameSiteHosts = [ "arx" ];
      gameSitePackage = game-site.packages.x86_64-linux.default;

      allNodes = let
        nodeEntities = filterAttrs (_: hostOpts: hostOpts.deploy.enable)
          fudo-entities.entities.hosts;
      in mapAttrs (hostname: hostOpts: {
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
        profilesOrder = [ "system" ]
          ++ (optional (elem hostname gameSiteHosts) "game-site");

        profiles = {
          system = {
            user = "root";
            path = deploy-rs.lib.x86_64-linux.activate.nixos
              fudo-nixos.nixosConfigurations."${hostname}";
          };
        } // (optionalAttrs (elem hostname gameSiteHosts) {
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
          deploy-rs-bin = "${deploy-rs.packages."${system}".deploy-rs}/bin/deploy";
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
