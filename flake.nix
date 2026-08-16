{
  description = "Agent Workbench development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              fish
              git
              github-cli
              gnumake
              i3
              lsof
              lua-language-server
              maim
              neovim
              nixfmt
              nodejs_22
              pi-coding-agent
              python3
              ripgrep
              stylua
              tea
              wezterm
              wmctrl
              xdotool
              xwininfo
            ];

            PLENARY_PATH = "${pkgs.vimPlugins.plenary-nvim}";
          };
        }
      );

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
