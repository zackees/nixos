# mkforce-discards: report every lib.mkForce (or any mkOverride priority
# below 100) written in this repo that makes the module system throw away
# somebody else's definition of the same option.
#
# Why this exists: `boot.initrd.availableKernelModules = lib.mkForce [...]`
# silently discarded NixOS's own `[ "ext2" "ext4" ]` contribution from
# nixos/modules/tasks/filesystems/ext.nix, the next boot could not mount
# root, and the machine was down for days. Nothing syntactic catches that
# (statix, deadnix and nixf-tidy all see a well-formed expression); the
# discarded definitions only exist inside the module system's merge. So this
# asks the module system.
#
# How it works, in terms of nixpkgs lib/modules.nix:
#
#   * `options.<p>.definitionsWithLocations` is `defsFinal`, i.e. what is
#     LEFT after filterOverrides' has dropped everything but the highest
#     priority. The discarded definitions are never exposed. So the raw
#     definitions are recomputed: re-run collectModules on the evaluation's
#     own module list with the evaluation's own `config`/`options` as module
#     arguments (so every module function sees exactly what it saw the first
#     time), then walk each collected module's `config` down the option path
#     with pushDownProperties -- the same walk mergeModules' does.
#   * At each option: dischargeProperties (evaluates mkIf, flattens mkMerge),
#     take the minimum priority like filterOverrides' does, and if a repo
#     file supplies a winning definition below 100, list every definition it
#     beat that a plain (priority 100) definition would NOT have beaten. That
#     excludes mkDefault / option defaults, which are counted but not
#     reported: shadowing those is what any ordinary assignment does.
#   * Nested options: the merged value of attrsOf X is mergeDefinitions per
#     key, and of a submodule a whole sub-evaluation, which the option's
#     `valueMeta` exposes (`.attrs.<name>`, `.configuration`). The analysis
#     recurses through both, so `systemd.user.services.<n>.environment`,
#     `serviceConfig.ExecStart` (an attrsOf key, not an option) and anything
#     under `home-manager.users.<u>` are judged against the right siblings.
#
# Which options are looked at: those that repo modules define (found by
# walking their `config` against the options tree -- not by grepping, since a
# grep cannot tell `foo.bar = { baz = mkForce x; }` from a comment), limited
# to repo files whose text mentions mkForce/mkOverride/mkVMOverride/
# mkImageMediaOverride at all. That textual gate is only a speed filter: it
# keeps the walk from forcing every string in files that cannot contain an
# override. Inside an option the search follows the option's type (attrsOf
# keys, submodule evaluations), never the value's shape. Blind spots, all
# deliberate: freeform keys and other untyped nesting (`settings.*` of
# types.anything, types.attrs), listOf-submodule elements, nullOr-wrapped
# submodules, and a priority < 100 produced by a helper defined in another
# file.
#
# Allowlist: put `# mkforce-ok: <reason>` at the end of the line holding the
# overridden attribute (or alone on the line directly above it). The reason
# is mandatory; an empty marker does not count.
{
  lib,
  # Path to the nixpkgs source the configurations were built with.
  nixpkgs,
  # This repo's source root as the evaluation sees it (`self.outPath`).
  root,
  # Flake inputs, only used to print `<nixpkgs>/nixos/...` instead of hashes.
  inputs ? { },
}:
let
  inherit (builtins)
    attrNames
    isAttrs
    readFile
    unsafeGetAttrPos
    unsafeDiscardStringContext
    ;
  inherit (lib)
    any
    concatMap
    concatStringsSep
    filter
    hasPrefix
    length
    optional
    removePrefix
    ;

  # collectModules, pushDownProperties and dischargeProperties are not
  # exported except through `lib.modules`' deprecation wrapper, which prints
  # "External use of lib.modules.X is deprecated" once per evaluation. Import
  # a private copy of modules.nix with `warn` disarmed instead, so the lint
  # stays quiet in `nix flake check` and in scripts/sync.sh. If a nixpkgs
  # bump renames these, evaluation of this file fails -- the check then fails
  # loudly rather than passing silently.
  internal = import "${nixpkgs}/lib/modules.nix" {
    lib = lib // {
      warn = _: v: v;
    };
  };
  inherit (internal) pushDownProperties dischargeProperties collectModules;

  str = s: unsafeDiscardStringContext (toString s);
  rootPrefix = str root + "/";
  isRepo = file: hasPrefix rootPrefix (str file);

  # Not lib.hasInfix: that is builtins.match ".*x.*", and std::regex recurses
  # per character, so it overflows the stack on configuration.nix (3700 lines).
  contains = needle: haystack: builtins.replaceStrings [ needle ] [ "" ] haystack != haystack;

  overrideTokens = [
    "mkForce"
    "mkOverride"
    "mkVMOverride"
    "mkImageMediaOverride"
  ];
  # A module's `_file` is whatever was imported: a file, a directory (meaning
  # its default.nix, as `imports = [ ./hosts/x ]` does), or for definitions
  # handed to a submodule "file, via option ...".
  sourceOf =
    file:
    let
      p = lib.head (lib.splitString ", " (str file));
    in
    if builtins.readFileType p == "directory" then p + "/default.nix" else p;
  readSource = file: readFile (sourceOf file);

  # Speed gate only; see the header.
  mayHoldOverride = file: isRepo file && any (t: contains t (readSource file)) overrideTokens;

  inputRoots = lib.mapAttrsToList (name: i: {
    inherit name;
    prefix = str i.outPath + "/";
  }) (lib.filterAttrs (_: i: i ? outPath) inputs);
  showFile =
    file:
    let
      f = str file;
      hit = lib.findFirst (r: hasPrefix r.prefix f) null inputRoots;
    in
    if hasPrefix rootPrefix f then
      removePrefix rootPrefix f
    else if hit != null then
      "<${hit.name}>/" + removePrefix hit.prefix f
    else
      f;

  prioName =
    p:
    if p == 50 then
      "mkForce"
    else if p == 10 then
      "mkVMOverride"
    else if p == 60 then
      "mkImageMediaOverride"
    else
      "mkOverride ${toString p}";

  # ---- raw definitions -----------------------------------------------------

  # The module list of an evaluation, as collectModules produced it for that
  # evaluation. `cfg.type.getSubModules` is the evaluation's own module list
  # (evalModules exposes it as submoduleWith { modules = ...; }), and the
  # arguments are the ones evalModules passes, built from the evaluation's
  # fixpoint, so module functions return the same definitions as before.
  modulesOf =
    loc: cfg:
    let
      specialArgs = cfg._module.specialArgs;
    in
    (collectModules (specialArgs.modulesPath or "") cfg.type.getSubModules (
      {
        inherit lib specialArgs;
        inherit (cfg) options;
        _class = cfg.class;
        _prefix = loc;
        config = cfg.config // {
          inherit (cfg) _module;
        };
      }
      // specialArgs
    )).modules;

  # Every definition one module makes at `path`, with the source position of
  # the attribute that made it.
  descend =
    file: path: node: pos:
    if path == [ ] then
      [ { inherit file pos; value = node; } ]
    else
      let
        h = lib.head path;
      in
      concatMap (
        a: if isAttrs a && a ? ${h} then descend file (lib.tail path) a.${h} (unsafeGetAttrPos h a) else [ ]
      ) (pushDownProperties node);
  rawDefsAt = ms: path: concatMap (m: descend (str m._file) path m.config null) ms;

  # Option paths below `opts` that a module's `config` sets.
  definedPaths =
    opts: node: path:
    concatMap (
      a:
      if !(isAttrs a) || a ? _type then
        [ ]
      else
        concatMap (
          n:
          if n == "_module" || !(opts ? ${n}) then
            [ ]
          else if lib.isOption opts.${n} then
            [ (path ++ [ n ]) ]
          else if isAttrs opts.${n} then
            definedPaths opts.${n} a.${n} (path ++ [ n ])
          else
            [ ]
        ) (attrNames a)
    ) (pushDownProperties node);

  uniquePaths =
    ps: lib.attrValues (lib.listToAttrs (map (p: lib.nameValuePair (concatStringsSep "\n" p) p) ps));

  # Could a definition of an option of this type hold a priority < 100 that
  # the module system would act on? Guided by the type, not by the value's
  # shape: blindly descending attrsets walks into things like
  # `extraSpecialArgs = { inherit inputs; }` and from there round the whole
  # flake. A submodule is always worth a look -- its definitions are modules
  # (functions, paths, attrsets of options) that only its own evaluation
  # can judge.
  isAttrsType = t: lib.elem (t.name or null) [ "attrsOf" "lazyAttrsOf" ];
  mayForce =
    type: v:
    let
      t = if isAttrs v then v._type or null else null;
    in
    if t == "override" then
      v.priority < 100 || mayForce type v.content
    else if t == "merge" then
      any (mayForce type) v.contents
    else if t == "if" || t == "order" then
      mayForce type v.content
    else if t == "definition" then
      mayForce type v.value
    else if (type.name or null) == "submodule" then
      true
    else if isAttrsType type && isAttrs v && t == null then
      any (mayForce type.nestedTypes.elemType) (lib.attrValues v)
    else
      false;

  # ---- priorities ----------------------------------------------------------

  prioOf = d: if d.value._type or null == "override" then d.value.priority else 100;
  strip = d: if d.value._type or null == "override" then d // { value = d.value.content; } else d;
  normalize =
    d:
    map (
      v:
      if v._type or null == "definition" then
        {
          file = str v.file;
          inherit (v) value;
          inherit (d) pos;
        }
      else
        d // { value = v; }
    ) (dischargeProperties d.value);

  # Strip the module system's wrappers out of a value for display: a nested
  # `mkIf true x` reads as x, a false one disappears.
  clean =
    v:
    if lib.isList v then
      map clean v
    else if !(isAttrs v) || lib.isDerivation v then
      v
    else
      let
        t = v._type or null;
      in
      if t == "if" then
        (if v.condition == true then clean v.content else "<mkIf false>")
      else if t == "override" || t == "order" then
        clean v.content
      else if t == "merge" then
        map clean v.contents
      else if t == null then
        lib.mapAttrs (_: clean) (lib.filterAttrs (_: x: !(isAttrs x && x._type or null == "if" && x.condition == false)) v)
      else
        v;
  # /nix/store/<32 chars>- is noise in a report; the package name is not.
  shortenStorePaths =
    s:
    lib.concatMapStrings (x: if lib.isList x then "" else x) (
      builtins.split "/nix/store/[0-9a-z]{32}-" s
    );
  pretty =
    v:
    let
      r = builtins.tryEval (str (lib.generators.toPretty { multiline = false; } (clean v)));
      s = if r.success then shortenStorePaths r.value else "<could not evaluate>";
    in
    if lib.stringLength s > 400 then lib.substring 0 397 s + "..." else s;

  # Where an override was written, and whether that line allowlists it.
  markerRe = ".*#[[:space:]]*mkforce-ok:[[:space:]]*([^[:space:]].*)";
  aloneRe = "[[:space:]]*#[[:space:]]*mkforce-ok:[[:space:]]*([^[:space:]].*)";
  locate =
    loc: d:
    let
      fallback =
        # Positions are lost when an attrset is rebuilt (e.g. `//`); fall back
        # to the single line in the file that both names the attribute and
        # applies an override, if there is exactly one.
        let
          lines = lib.splitString "\n" (readSource d.file);
          name = lib.last loc;
          hits = filter (i: let l = lib.elemAt lines i; in contains name l && any (t: contains t l) overrideTokens) (
            lib.range 0 (length lines - 1)
          );
        in
        if length hits == 1 then
          {
            inherit (d) file;
            line = lib.head hits + 1;
          }
        else
          null;
      p = if d.pos != null then d.pos else fallback;
      lines = lib.splitString "\n" (readSource p.file);
      at = i: if i >= 1 && i <= length lines then lib.elemAt lines (i - 1) else "";
      inline = builtins.match markerRe (at p.line);
      above = builtins.match aloneRe (at (p.line - 1));
      reason =
        if inline != null then
          lib.head inline
        else if above != null then
          lib.head above
        else
          null;
    in
    if p == null then
      {
        where = "${showFile d.file} (line unknown)";
        reason = null;
      }
    else
      {
        where = "${showFile p.file}:${toString p.line}";
        inherit reason;
      };

  # ---- the walk ------------------------------------------------------------

  analyzeDefs =
    loc: type: raw: meta:
    let
      norm = concatMap normalize raw;
      high = lib.foldl' (p: d: lib.min p (prioOf d)) 9999 norm;
      winners = filter (d: prioOf d == high) norm;
      forced = filter (d: isRepo d.file) winners;
      losers = filter (d: prioOf d > high) norm;
      # An empty list or attrset contributes nothing, so losing one is not a
      # loss (plasma-manager and others define `[ ]` placeholders freely).
      isEmpty = v: let c = clean v; in c == [ ] || c == { };
      discarded = filter (d: prioOf d <= 100 && !(isEmpty (strip d).value)) losers;

      here = optional (high < 100 && forced != [ ]) (
        let
          sites = map (locate loc) forced;
        in
        {
          option = lib.showOption loc;
          priority = high;
          how = prioName high;
          forcedAt = map (s: s.where) sites;
          # Every forcing site has to carry the marker for the finding to be
          # allowlisted; one reasoned site does not excuse another.
          reason =
            if any (s: s.reason == null) sites then null else concatStringsSep "; " (map (s: s.reason) sites);
          discarded = map (d: {
            file = showFile d.file;
            priority = prioOf d;
            value = pretty (strip d).value;
          }) discarded;
          shadowedDefaults = length (filter (d: prioOf d > 100) losers);
        }
      );

      survivors = map strip winners;
      hotSurvivors = filter (d: mayHoldOverride d.file) survivors;
      tname = type.name or null;
      elemType = type.nestedTypes.elemType or null;

      nested =
        if
          lib.elem tname [
            "attrsOf"
            "lazyAttrsOf"
          ]
        then
          let
            names = lib.unique (concatMap (d: lib.optionals (isAttrs d.value) (attrNames d.value)) hotSurvivors);
            hot = filter (
              n: any (d: isAttrs d.value && d.value ? ${n} && mayForce elemType d.value.${n}) hotSurvivors
            ) names;
          in
          concatMap (
            n:
            analyzeDefs (loc ++ [ n ]) elemType (concatMap (
              d:
              optional (isAttrs d.value && d.value ? ${n}) {
                inherit (d) file;
                value = d.value.${n};
                pos = unsafeGetAttrPos n d.value;
              }
            ) survivors) (meta.attrs.${n} or { })
          ) hot
        else if tname == "submodule" && meta ? configuration && hotSurvivors != [ ] then
          analyzeConfig loc meta.configuration
        else
          [ ];
    in
    here ++ nested;

  analyzeConfig =
    loc: cfg:
    let
      ms = modulesOf loc cfg;
      hotMs = filter (m: mayHoldOverride m._file) ms;
      paths = uniquePaths (concatMap (m: definedPaths cfg.options m.config [ ]) hotMs);
      hot = filter (p: any (d: mayForce (lib.getAttrFromPath p cfg.options).type d.value) (rawDefsAt hotMs p)) paths;
    in
    concatMap (
      p:
      let
        opt = lib.getAttrFromPath p cfg.options;
      in
      analyzeDefs (loc ++ p) opt.type (rawDefsAt ms p) (opt.valueMeta or { })
    ) hot;

  # ---- reporting -----------------------------------------------------------

  showFinding =
    f:
    concatStringsSep "\n" (
      [ "  ${f.option}: ${f.how} at ${concatStringsSep ", " f.forcedAt}" ]
      ++ optional (f.reason != null) "    allowlisted: ${f.reason}"
      ++ map (d: "    discards ${d.value}  (${d.file}${lib.optionalString (d.priority != 100) ", priority ${toString d.priority}"})") f.discarded
      ++ optional (
        f.shadowedDefaults > 0
      ) "    (+ ${toString f.shadowedDefaults} default-priority definition(s), which a plain assignment would replace too)"
    );

  lintConfiguration =
    name: cfg:
    let
      all = analyzeConfig [ ] cfg;
      withDiscards = filter (f: f.discarded != [ ]) all;
      findings = filter (f: f.reason == null) withDiscards;
      allowed = filter (f: f.reason != null) withDiscards;
      harmless = filter (f: f.discarded == [ ]) all;
    in
    {
      inherit findings allowed harmless;
      text = concatStringsSep "\n" (
        [
          "nixosConfigurations.${name}: ${toString (length findings)} finding(s), ${toString (length allowed)} allowlisted, ${toString (length harmless)} override(s) that discard nothing"
        ]
        ++ lib.optionals (findings != [ ]) ([ "" "FINDINGS (fix, or mark the line `# mkforce-ok: <reason>`):" ] ++ map showFinding findings)
        ++ lib.optionals (allowed != [ ]) ([ "" "ALLOWLISTED:" ] ++ map showFinding allowed)
        ++ lib.optionals (harmless != [ ]) (
          [ "" "DISCARD NOTHING (the override wins against defaults only):" ]
          ++ map (f: "  ${f.option}: ${f.how} at ${concatStringsSep ", " f.forcedAt}") harmless
        )
      );
    };
in
{
  inherit lintConfiguration;

  # A derivation that fails, printing the report, when any configuration has
  # a non-allowlisted finding. All the work happens at evaluation time; the
  # build itself is a `cat`.
  check =
    pkgs: configurations:
    let
      results = lib.mapAttrs lintConfiguration configurations;
      count = lib.foldl' (n: r: n + length r.findings) 0 (lib.attrValues results);
      report =
        concatStringsSep "\n\n" (lib.mapAttrsToList (_: r: r.text) results) + "\n";
    in
    pkgs.runCommandLocal "mkforce-discards"
      {
        inherit report;
        passAsFile = [ "report" ];
        passthru = {
          inherit report results;
          findings = count;
        };
      }
      ''
        cat "$reportPath"
        ${if count == 0 then ''cp "$reportPath" $out'' else "exit 1"}
      '';
}
