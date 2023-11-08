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
        config.cudaSupport = true;
        config.allowUnfree = true;
        overlays = [ self.overlays.llama-cpp-with-cuda-and-shared-libs ];
      };
    in
    {
      formatter.${system} = pkgs.nixpkgs-fmt;

      overlays.default = final: prev: {
        ollama = self.packages.${system}.default;
      };

      overlays.llama-cpp-with-cuda-and-shared-libs = final: prev: {
        llama-cpp = prev.llama-cpp.overrideAttrs (old: {
          buildInputs = old.buildInputs ++ (with prev.cudaPackages; [ libcublas cudatoolkit ]);
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
      };

      packages.${system} = {
        default = pkgs.ollama;
        llama-cpp = pkgs.llama-cpp;
      };

      devShells.x86_64-linux.default = pkgs.mkShell {
        buildInputs = [
          self.packages.${system}.default
        ];
      };
    };
}
