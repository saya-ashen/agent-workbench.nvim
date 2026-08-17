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
          demoNvim = pkgs.wrapNeovim pkgs.neovim-unwrapped {
            extraName = "-agent-workbench-demo";
            configure = {
              packages.demo.start = [
                pkgs.vimPlugins.catppuccin-nvim
                pkgs.vimPlugins.lualine-nvim
                pkgs.vimPlugins.markview-nvim
                pkgs.vimPlugins.nvim-treesitter
                pkgs.vimPlugins.nvim-treesitter-parsers.markdown
                pkgs.vimPlugins.nvim-web-devicons
              ];
              customLuaRC = ''
                dofile(assert(vim.env.AGENT_WORKBENCH_REPO) .. "/scripts/demo/init.lua")
              '';
            };
          };
          demoNvimBin = pkgs.writeShellScriptBin "agent-workbench-demo-nvim" ''
            exec ${demoNvim}/bin/nvim "$@"
          '';
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              demoNvimBin
              btop
              ffmpeg
              fish
              git
              github-cli
              gnumake
              i3
              just
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
              ttyd
              vhs
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
