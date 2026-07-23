# Adapted from nixpkgs pkgs/by-name/pi/pi-coding-agent/package.nix
# (nixos-26.05), with src taken from this repo and npm dependencies
# resolved via importNpmLock instead of a fixed npmDepsHash.
{
  lib,
  buildNpmPackage,
  importNpmLock,
  fetchurl,
  versionCheckHook,
  writableTmpDirAsHomeHook,
  ripgrep,
  fd,
  jq,
  makeBinaryWrapper,
  stdenvNoCC,
  src,
}:
let
  version = (lib.importJSON (src + "/packages/coding-agent/package.json")).version;
  modelData = fetchurl {
    url = "https://registry.npmjs.org/@earendil-works/pi-ai/-/pi-ai-${version}.tgz";
    hash = "sha512-hzHE7Z8l5mgJk+ke67Lge0rwS2+wbKJrFKl9o5M1R1rh33+cCT7D1AHz1OAtX5wFs90E1/BTGhyJRTUHaMxGvQ==";
  };
in
buildNpmPackage (finalAttrs: {
  pname = "pi-coding-agent";
  inherit version;

  inherit src;

  npmDeps = importNpmLock { npmRoot = src; };
  npmConfigHook = importNpmLock.npmConfigHook;

  npmWorkspace = "packages/coding-agent";

  # Skip native module rebuild for unneeded workspaces (e.g. canvas from web-ui)
  npmRebuildFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [
    jq
    makeBinaryWrapper
  ];

  # Build workspace dependencies in order, then the coding-agent.
  # The generated model values are ignored by the source repository, and
  # regenerating them requires network access. Hydrate them from the matching
  # published pi-ai package, then adapt its flat schema to the grouped schema
  # expected by the current source.
  buildPhase = ''
    runHook preBuild

    dataDir=packages/ai/src/providers/data
    mkdir -p "$dataDir"
    tar -xzf ${modelData} --strip-components=4 -C "$dataDir" package/dist/providers/data
    rm "$dataDir/.manifest.json"

    structures=$(mktemp)
    fileHashes=$(mktemp)
    fileHashesJson=$(mktemp)
    for path in "$dataDir"/*.json; do
      provider=$(basename "$path" .json)
      jq -cS \
        'if all(.[]; type == "object" and has("api")) then reduce to_entries[] as $model ({}; .[$model.value.api][$model.key] = $model.value) else . end' \
        "$path" > "$path.tmp"
      mv "$path.tmp" "$path"
      jq -c --arg provider "$provider" \
        '{key: $provider, value: (to_entries | map(.key as $api | .value | keys[] | {key: ., value: $api}) | from_entries)}' \
        "$path" >> "$structures"
      jq -nc --arg file "$(basename "$path")" \
        --arg hash "$(sha256sum "$path" | cut -d " " -f 1)" \
        '{key: $file, value: $hash}' >> "$fileHashes"
    done

    structure=$(jq -csS 'from_entries' "$structures")
    structureHash=$(printf '%s' "$structure" | sha256sum | cut -d ' ' -f 1)
    jq -csS 'from_entries' "$fileHashes" > "$fileHashesJson"
    jq -nS --arg structureHash "$structureHash" --slurpfile files "$fileHashesJson" \
      '{schemaVersion: 2, structureHash: $structureHash, files: $files[0]}' \
      > "$dataDir/.manifest.json"
    rm "$structures" "$fileHashes" "$fileHashesJson"

    npm run build:offline --workspace=packages/ai
    npx tsgo -p packages/tui/tsconfig.build.json
    npx tsgo -p packages/agent/tsconfig.build.json
    npm run build --workspace=packages/coding-agent

    runHook postBuild
  '';

  # npm workspace symlinks in the output point into packages/ which
  # doesn't exist there. Replace runtime deps with built content and
  # delete the rest.
  postInstall = ''
    local nm="$out/lib/node_modules/pi-monorepo/node_modules"

    # Replace workspace deps needed at runtime with real copies
    for ws in @earendil-works/pi-ai:packages/ai \
              @earendil-works/pi-agent-core:packages/agent \
              @earendil-works/pi-tui:packages/tui; do
      IFS=: read -r pkg src <<< "$ws"
      rm "$nm/$pkg"
      cp -r "$src" "$nm/$pkg"
    done

    # Delete remaining workspace symlinks
    find "$nm" -type l -lname '*/packages/*' -delete

    # Clean up now-dangling .bin symlinks
    find "$nm/.bin" -xtype l -delete
  ''
  + lib.optionalString stdenvNoCC.hostPlatform.isDarwin ''
    # Remove foreign Linux binaries that make audit-tmpdir try to inspect ELF
    # RPATHs with patchelf
    find "$nm/koffi/build/koffi" -mindepth 1 -maxdepth 1 -type d \
      ! -name 'darwin_*' -exec rm -r {} +
    rm -rf \
      "$nm/@anthropic-ai/sandbox-runtime/dist/vendor/seccomp" \
      "$nm/@anthropic-ai/sandbox-runtime/vendor/seccomp"
  '';

  postFixup = "wrapProgram $out/bin/pi --prefix PATH : ${
    lib.makeBinPath [
      ripgrep
      fd
    ]
  }";

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    writableTmpDirAsHomeHook
    versionCheckHook
  ];
  versionCheckKeepEnvironment = [ "HOME" ];
  versionCheckProgram = "${placeholder "out"}/bin/pi";
  versionCheckProgramArg = "--version";

  meta = {
    description = "Coding agent CLI with read, bash, edit, write tools and session management";
    homepage = "https://pi.dev/";
    changelog = "https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md";
    license = lib.licenses.mit;
    mainProgram = "pi";
  };
})
