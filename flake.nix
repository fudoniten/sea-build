{
  description = "Deployment using deploy-rs";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-25.11";

    deploy-rs = { url = "github:serokell/deploy-rs"; };

    utils.url = "github:numtide/flake-utils";

    fudo-nixos = {
      url = "git+ssh://git@github.com/fudoniten/nixos-config";
      inputs = {
        fudo-entities.follows = "fudo-entities";
        nixpkgs.follows = "nixpkgs";
      };
    };

    fudo-entities = {
      url = "git+ssh://git@github.com/fudoniten/fudo-entities";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, utils, deploy-rs, fudo-nixos, fudo-entities, ... }@inputs:
    with nixpkgs.lib;
    let
      defaultSshOpts = [ "-oControlMaster=no" "-oControlPath=none" ];

      allNodes = let
        nodeEntities = filterAttrs (_: hostOpts: hostOpts.deploy.enable)
          fudo-entities.entities.hosts;
      in mapAttrs (hostname: hostOpts: {
        hostname = fudo-entities.lib.getHostIpv4 hostname;
        sshOpts = defaultSshOpts ++ hostOpts.deploy.ssh-options;
        sshUser = "root";

        inherit (hostOpts) site domain;

        profiles.system = {
          user = "root";
          path = deploy-rs.lib.x86_64-linux.activate.nixos
            fudo-nixos.nixosConfigurations."${hostname}";
        };
      }) nodeEntities;

      domains = fudo-entities.entities.domains;
      sites = fudo-entities.entities.sites;

    in utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
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
