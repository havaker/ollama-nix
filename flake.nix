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
        llama-cpp = pkgs.llama-cpp.overrideAttrs (old: {
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

            version = "0.1.10";

            src = pkgs.fetchFromGitHub {
              owner = "jmorganca";
              repo = "ollama";
              rev = "v${version}";
              hash = "sha256-1MoRoKN8/oPGW5TL40vh9h0PMEbAuG5YmuNHPvNtHgA=";
            };

            postPatch = ''
              substituteInPlace llm/llama.go \
                --subst-var-by llamaCppServer "${llama-cpp}/bin/llama-cpp-server"
            '';

            # Inheriting ldflags from pkgs.ollama will inherit the old version setting.
            ldflags = [
              "-s"
              "-w"
              "-X=github.com/jmorganca/ollama/version.Version=${version}"
              "-X=github.com/jmorganca/ollama/server.mode=release"
            ];

            vendorHash = "sha256-9Ml5YvK5grSOp/A8AGiWqVE1agKP13uWIZP9xG2gf2o=";
          };

        default = ollama;
      };
    };
}
