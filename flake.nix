# Copyright (C) 2023-present:
#    Michał Sala <fmxloexp@msala.waw.pl>
# SPDX-License-Identifier: AGPL-3.0-or-later
{
  description = "Ollama with proper CUDA support enabled";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      formatter.${system} = pkgs.nixpkgs-fmt;

      overlays.default = final: prev: {
        ollama = self.packages.${system}.default;
      };

      packages.${system} = rec {
        llama-cpp = (
          # cudatoolkit does not like gcc12.
          pkgs.llama-cpp.override { stdenv = pkgs.gcc11Stdenv; }
        ).overrideAttrs (old: {
          buildInputs = old.buildInputs ++ (
            with pkgs.cudaPackages; [ libcublas cudatoolkit ]
          );
          cmakeFlags = [
            "-DLLAMA_BUILD_SERVER=ON"
            "-DBUILD_SHARED_LIBS=ON"
            "-DLLAMA_CUBLAS=ON"
            "-DCMAKE_SKIP_BUILD_RPATH=ON"
          ];

          # By default, llama-cpp package does not have a lib/ output. Ollama
          # requires libllama and others, so the install phase was modified to
          # copy all of built shared libraries to the $out/lib/.
          installPhase = ''
            runHook preInstall

            mkdir -p $out/bin

            # Ollama requires libllama and others
            mkdir -p $out/lib
            find . -type f -name "*.so" -exec cp {} $out/lib \;

            for f in bin/*; do
              test -x "$f" || continue
              cp "$f" $out/bin/llama-cpp-"$(basename "$f")"
            done

            runHook postInstall
          '';
        });

        ollama =
          let
            llama-cpp = self.packages.${system}.llama-cpp;
          in
          pkgs.buildGoModule rec {
            inherit (pkgs.ollama) pname meta patches;

            version = "0.1.17";

            src = pkgs.fetchFromGitHub {
              owner = "jmorganca";
              repo = "ollama";
              rev = "v${version}";
              hash = "sha256-eXukNn9Lu1hF19GEi7S7a96qktsjnmXCUp38gw+3MzY=";
            };

            postPatch = ''
              substituteInPlace llm/llama.go \
                --subst-var-by llamaCppServer "${llama-cpp}/bin/llama-cpp-server"
              substituteInPlace server/routes_test.go --replace "0.0.0" "${version}"
            '';

            # Inheriting ldflags from pkgs.ollama will inherit the old version setting.
            ldflags = [
              "-s"
              "-w"
              "-X=github.com/jmorganca/ollama/version.Version=${version}"
              "-X=github.com/jmorganca/ollama/server.mode=release"
            ];

            vendorHash = "sha256-yGdCsTJtvdwHw21v0Ot6I8gxtccAvNzZyRu1T0vaius=";
          };

        default = ollama;
      };

      nixosModules.default = { config, lib, ... }:
        let
          ollamaPackage = self.packages.${system}.ollama;
        in
        with lib; {
          options = {
            services.ollama.enable = mkEnableOption "Enable Ollama LLM runner service";
          };
          config = mkIf config.services.ollama.enable {
            assertions = [
              {
                assertion = config.nixpkgs.system == system;
                message = "Only ${system} is supported by this flake.";
              }
              {
                assertion = config.boot.kernelPackages ? nvidia_x11;
                message = "Nvidia driver has to be present.";
              }
            ];

            # Add the ollama system user for the system-wide service.
            users.users.ollama = {
              isSystemUser = true;
              group = "ollama";

              # All the requested LLM weights are stored in this directory.
              createHome = true;
              home = "/var/lib/ollama";
            };
            users.groups.ollama = { };

            # Make ollama package available system-wide.
            environment.systemPackages = [ ollamaPackage ];

            # Ollama server listens on http://127.0.0.1:49977, every user with network
            # access is able to access it and use to run chosen LLM. It does not make
            # sense to have a separate `ollama serve` instance for every user (there is
            # no data shared, only weights of the LLM), so it is reasonable to run it as
            # a system-wide service.
            systemd.services.ollama = {
              description = "Service for running LLMs";

              wantedBy = [ "multi-user.target" ];
              after = [ "network.target" ];

              path = [ config.hardware.nvidia.package.bin ];

              serviceConfig = {
                Type = "simple";

                User = "ollama";
                Group = "ollama";

                ExecStart = "${ollamaPackage}/bin/ollama serve";

                Restart = "always";
                RestartSec = 3;
              };
            };
          };
        };

    };
}
