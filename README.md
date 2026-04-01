

# Nix `vendorHash` for Go Modules: The What, Why, and How

## Plain English

### What's happening

You have a Nix flake that builds `golangci-lint` from source using `buildGoModule`. Go projects have dependencies (other libraries), and those dependencies need to be fetched somehow. The `vendorHash` parameter tells Nix **how to handle those dependencies**.

When you set `vendorHash = null`, you're saying: *"Hey Nix, the source repository already has a `vendor/` directory with all the dependencies checked in — just use that directly, don't fetch anything."*

The problem: golangci-lint v2.5.0's `vendor/` directory is **out of sync** with its `go.mod` / `go.sum`. The code says it needs certain dependencies, but the vendored copies don't match. So the build breaks.

### Why you need to fix it

Nix builds are **hermetic** — they happen in a sandbox with no network access. So Nix needs to know *in advance* exactly what bytes it's going to download, and it verifies them with a cryptographic hash. This is the core contract: **reproducibility**. Same inputs → same outputs, every time, on every machine.

When you provide a `vendorHash`, you're telling Nix: *"Ignore the vendor/ directory. Instead, run `go mod download` in a separate fixed-output derivation, fetch all the deps from the Go module proxy, and I promise the result will have this hash."*

### Why can't Nix figure this out automatically?

This is the deep question. The answer has multiple layers:

1. **Nix's evaluation is pure — no network access.** During evaluation (when it reads your `.nix` files and computes the dependency graph), Nix cannot reach out to the internet. It can't run `go mod download` to discover what hash the vendor tarball would have. The hash is a *property of the build output*, and Nix refuses to execute builds just to evaluate expressions.

2. **Fixed-output derivations require a declared hash.** Nix allows exactly one escape hatch for fetching from the network: fixed-output derivations (FODs). But FODs require you to declare the hash *upfront*. This is what makes Nix builds reproducible — the hash is a promise that the downloaded content is exactly what you expect. Without it, someone could MITM your build or an upstream server could silently change content.

3. **Go's module system is external to Nix's world.** Nix doesn't understand `go.mod`. It doesn't have a Go-specific solver built in. `buildGoModule` is a *helper* that wraps the general Nix machinery, but it still must obey Nix's rules: you declare inputs (with hashes), then you build.

4. **The `vendor/` directory is a trust decision.** When `vendorHash = null`, you're asserting the source tree is self-contained. Nix trusts you. If the vendor dir is broken, that's your problem — Nix has no basis for second-guessing what "correct" vendoring looks like.

So the manual step exists because **Nix's security and reproducibility model is fundamentally at odds with "just go figure out what I need from the internet."** That's a feature, not a bug — but it does create friction.

---

## Algebraic / Formal Terms

Think of a Nix derivation as a function:

$$D : \text{Inputs} \to \text{Output}$$

Nix enforces that the **hash of every input is known before the build starts**. For source code, that hash comes from the git revision. For fetched dependencies, it comes from you.

A **fixed-output derivation** (FOD) is a special case:

$$\text{FOD}(url, h_{\text{expected}}) = \begin{cases} \text{content} & \text{if } H(\text{content}) = h_{\text{expected}} \\ \bot & \text{otherwise} \end{cases}$$

where $$H$$ is a cryptographic hash function (SHA-256). The FOD is allowed to access the network, but the result is **verified** against the declared hash. This is the only way external content enters the Nix store.

Now, `buildGoModule` constructs two derivations:

1. **`goModules` (a FOD):** Downloads dependencies via `go mod download`, producing a vendor tree. You must supply $$h_{\text{expected}} = \texttt{vendorHash}$$.

2. **The main build:** Takes the source $$S$$ and the vendor tree $$V$$ and produces the binary:

$$\text{build}(S, V) \to \text{binary}$$

When `vendorHash = null`, derivation (1) is **skipped entirely**, and $$V$$ is taken directly from the source tree:

$$V = S|_{\texttt{vendor/}}$$

So the full picture:

$$\texttt{vendorHash} = \begin{cases} \texttt{null} & \Rightarrow V = S|_{\texttt{vendor/}} \quad \text{(trust the source)} \\ h & \Rightarrow V = \text{FOD}(\texttt{go mod download}, h) \quad \text{(fetch + verify)} \end{cases}$$

The **chicken-and-egg problem** is:

$$h_{\text{expected}} = H(\text{FOD\_output})$$

But you can't know $$H(\text{FOD\_output})$$ without running the FOD, and you can't run the FOD without declaring $$h_{\text{expected}}$$. Nix breaks this cycle with the **fake hash trick**: you supply a deliberately wrong hash (e.g., `lib.fakeHash`), Nix runs the FOD, it fails verification, but the error message tells you the *actual* hash it computed. You plug that back in. It's a manual two-pass bootstrap.

---

## The Three "Hows" (Copilot's Options Explained)

### Option 1 & 2: The fake-hash bootstrap

```nix
vendorHash = "";          # or pkgs.lib.fakeHash
```

Both do the same thing: supply a hash that's guaranteed wrong. Nix runs the FOD, downloads the Go modules, computes the real hash, then errors out with:

```
hash mismatch: got sha256-XXXXXX...
```

You copy-paste the real hash back into `vendorHash`. This is the standard workflow for any FOD in Nix. It's inelegant but correct.

### Option 3: `deleteVendor + proxyVendor`

```nix
deleteVendor = true;   # rm -rf vendor/ before building
proxyVendor = true;    # use GOPROXY instead of vendor/
```

This tells `buildGoModule`: *"The source's vendor/ directory is garbage — delete it and re-vendor from scratch using the Go module proxy."* You still need a `vendorHash`, but this ensures the vendor tree is rebuilt cleanly from `go.mod` rather than relying on whatever's committed in the repo.

---

## Summary

| Aspect | Explanation |
|---|---|
| **What** | `vendorHash` tells Nix whether to trust the repo's `vendor/` dir or fetch dependencies itself |
| **Why it's manual** | Nix's purity model forbids network access during evaluation; hashes must be declared upfront |
| **How (bootstrap)** | Use a fake hash → Nix tells you the real one → plug it in |
| **How (structural)** | `deleteVendor + proxyVendor` forces a clean re-vendor from `go.mod` |
| **Why Nix can't auto-solve** | Computing the hash requires running the build, but running the build requires the hash — a deliberate circular dependency that enforces reproducibility |

The manual friction is the *price* of deterministic, reproducible builds. Every byte that enters the build is accounted for. Nix chose correctness over convenience here.



Great question. Let me walk through the concrete mechanics of getting that hash value, because it's a bit unintuitive the first time.

## The Core Idea

Nix needs a SHA-256 hash of the Go module dependencies **before** it will build anything. But you don't know that hash yet. So you **intentionally provoke an error** that reveals it.

---

## Method 1: The Fake Hash Trick (Most Common)

### Step 1: Put in a wrong hash

Change your flake:

```nix
vendorHash = "";
```

or equivalently:

```nix
vendorHash = pkgs.lib.fakeHash;
```

(`lib.fakeHash` is just the string `"sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="` — a syntactically valid but obviously wrong hash.)

### Step 2: Try to build

```bash
nix build .#golangci-lint-v2
# or
nix develop .#v2
```

### Step 3: Read the error

Nix will:
1. See that `vendorHash` is not `null`, so it knows it needs to fetch dependencies
2. Run `go mod download` inside a sandbox (with network access, because this is a fixed-output derivation)
3. Produce a tarball of all the Go modules
4. Compute the SHA-256 of that tarball
5. Compare it to the hash you gave (`""` or the fake one)
6. **Fail**, because they don't match

The error message looks something like:

```
hash mismatch in fixed-output derivation '/nix/store/xxx-go-modules':
  specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
  got:       sha256-R3xF7k5bGEaq/LkERp8yDv4HPMwcYGoz99LPMBfhLbo=
```

### Step 4: Copy-paste the "got" value

```nix
vendorHash = "sha256-R3xF7k5bGEaq/LkERp8yDv4HPMwcYGoz99LPMBfhLbo=";
```

That's it. Now `nix build` will succeed.

---

## Method 2: Prefetch It Manually with `nix-prefetch`

If you want to compute the hash without triggering a build failure, you can use `nix-prefetch` or `nix hash` tooling, but honestly this is harder for Go modules because the "thing being hashed" is the output of `go mod download`, not a single URL. The fake-hash trick is what the Nix community actually uses day-to-day, even for nixpkgs itself.

---

## Method 3: For the Prebuilt Binary Hashes (Different Problem)

You also have empty hashes in `mkGolangciLintFromPrebuiltBinaryDerivation` — those `sha256s` entries with `""` and `"sha256-<fill-me>"`. These are simpler because they're hashing a single file from a known URL.

You can compute these directly:

```bash
nix-prefetch-url --unpack \
  "https://github.com/golangci/golangci-lint/releases/download/v2.5.0/golangci-lint-2.5.0-linux-amd64.tar.gz"
```

This downloads the tarball, unpacks it (because `fetchurl` + tar expects the unpacked hash), and prints the hash. Or with the newer SRI format:

```bash
nix hash to-sri --type sha256 $(nix-prefetch-url --unpack --type sha256 \
  "https://github.com/golangci/golangci-lint/releases/download/v2.5.0/golangci-lint-2.5.0-linux-amd64.tar.gz")
```

Alternatively, you can use the same fake-hash trick here too — put in `lib.fakeHash`, run the build, read the error.

---

## Why It Feels Weird

You're used to package managers that say *"let me figure out what I need and go get it."* Nix inverts this: **you** declare what will be fetched, and **Nix** verifies you were right. The two-pass dance (fake hash → real hash) is the bootstrap cost of that inversion.

It only happens once per version bump. Once the hash is in your flake, it's locked forever — anyone on any machine will get the exact same bytes.

---



# How to Get the `vendorHash` Value

There are several approaches, from most straightforward to most manual. Let me walk through each one concretely.

---

## Method 1: The Fake Hash Trick (Recommended)

This is the standard Nix workflow. You deliberately give a wrong hash, and Nix tells you the right one.

### Step 1: Set a fake hash in your flake

```nix
vendorHash = "";
# or equivalently:
vendorHash = pkgs.lib.fakeHash;
# which expands to: "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
```

### Step 2: Try to build it

```bash
nix build .#golangci-lint-v1 2>&1
```

Nix will:
1. See that `vendorHash` is not `null`, so it creates a **fixed-output derivation** for the Go modules
2. Download all dependencies via `go mod download`
3. Hash the result
4. Compare it to your declared hash (`""` or the fake one)
5. **Fail** — because the hashes don't match

The error output will look something like:

```
error: hash mismatch in fixed-output derivation '/nix/store/xxxxx-go-modules.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-r8K1Z3bJmGp4k7L9qN2xF5vT0wY6hD3mA8sE1cP4jXo=
```

### Step 3: Copy the "got" hash into your flake

```nix
vendorHash = "sha256-r8K1Z3bJmGp4k7L9qN2xF5vT0wY6hD3mA8sE1cP4jXo=";
```

### Step 4: Build again

```bash
nix build .#golangci-lint-v1
```

This time it succeeds. Done.

**Why this works:** Fixed-output derivations are the *one* place Nix allows network access. Nix fetches the content, then checks the hash. A wrong hash causes a failure, but the error message helpfully includes the actual hash. It's a controlled two-pass process.

---

## Method 2: Use `nix-prefetch` Tooling

If you want to compute the hash *without* a failed build, you can prefetch the Go module dependencies directly.

### For the Go vendor tarball specifically:

```bash
# Enter a shell with Go available
nix shell nixpkgs#go

# Clone or point to the source
cd /tmp
git clone --branch v2.5.0 https://github.com/golangci/golangci-lint.git
cd golangci-lint

# Download the modules
GOFLAGS=-mod=mod go mod download

# Now compute the hash of the module cache
# The vendor FOD in buildGoModule essentially tars up $GOPATH/pkg/mod/cache/download
nix hash path $GOPATH/pkg/mod/cache/download
```

This gives you the SRI hash (the `sha256-XXXX=` format) directly.

**Caveat:** This is trickier than Method 1 because you need to replicate *exactly* what `buildGoModule` does internally — same Go version, same module proxy, same directory structure. If anything differs, the hash won't match. Method 1 is more reliable because it uses the exact same code path as the real build.

---

## Method 3: Use `nix build` with `--rebuild` After Getting It Right Once

If you've already built successfully and later need to verify or recompute:

```bash
# See what the current hash resolves to
nix derivation show .#golangci-lint-v1 | grep -A2 "outputHash"
```

This inspects the derivation without building it, showing you the declared hash.

---

## Method 4: For the Prebuilt Binary Hashes (`sha256s`)

Your flake also has a *separate* hash problem — the `sha256s` map for `mkGolangciLintFromPrebuiltBinaryDerivation`. These are hashes of the **release tarballs from GitHub**, not Go module vendoring. Same principle, different target.

### Using `nix-prefetch-url`:

```bash
# For a specific platform tarball:
nix store prefetch-file --hash-type sha256 \
  "https://github.com/golangci/golangci-lint/releases/download/v1.64.8/golangci-lint-1.64.8-linux-amd64.tar.gz"
```

This downloads the file and prints the hash in SRI format. You plug that into the `sha256s` map:

```nix
sha256s = {
  x86_64-linux = "sha256-WHATEVER_IT_PRINTED=";
  # ...
};
```

### Or use the same fake-hash trick:

```nix
sha256s = {
  x86_64-linux = "";  # deliberately wrong
  # ...
};
```

Then `nix build .#golangci-lint-v1` will fail with the real hash in the error message, just like Method 1.

---

## Mental Model

Think of it as a **lock file workflow**, similar to `package-lock.json` or `go.sum`, but enforced at the build system level:

| Ecosystem | "I need these deps" | "Here's proof of what I got" |
|---|---|---|
| npm | `package.json` | `package-lock.json` |
| Go | `go.mod` | `go.sum` |
| Nix + Go | `go.mod` + `buildGoModule` | `vendorHash` in your `.nix` file |

The difference is that npm and Go can generate their lock files automatically because they're allowed to hit the network during a normal workflow. Nix **cannot** — so you do a one-time bootstrap (the fake hash trick) and then you have your "lock" value.

Every time you bump the version of golangci-lint, you'll need to redo this: update the version, set `vendorHash = ""`, build, grab the new hash, plug it in. It's a 60-second chore per version bump.

---

Good — your flake already has `vendorHash = pkgs.lib.fakeHash;` set, which is exactly the right starting point. Here's what to actually do with it.

---

## Getting the `vendorHash` values

Your flake exposes two source-built packages. You need a hash for each independently, because `golangci-lint` v1 and v2 have different dependency trees.

### For `vendorHash` (source builds)

Your packages are named `golangci-lint-v1` and `golangci-lint-v2` in the `packages` output — **but those point to the prebuilt derivations**, not the source ones. The source derivations are only wired into the `devShells`. So you need to target the shells, or temporarily rewire a package to the source build.

**Easiest path** — build the dev shells, which use the source derivations:

```bash
# Get vendorHash for v1
nix build .#devShells.x86_64-linux.v1 2>&1 | grep "got:"

# Get vendorHash for v2
nix build .#devShells.x86_64-linux.v2 2>&1 | grep "got:"
```

Each will fail (because `fakeHash` is wrong by design) and print something like:

```
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-r8K1Z3bJmGp4k7L9qN2xF5vT0wY6hD3mA8sE1cP4jXo=
```

Copy the `got:` value for each version into `mkGolangciLintFromSourceDerivation`. Since both v1 and v2 call the same function, you'll need to make `vendorHash` a parameter:

```nix
mkGolangciLintFromSourceDerivation =
  { src, version, vendorHash }:   # <-- add vendorHash as a param
  pkgs.buildGoModule {
    pname = "golangci-lint";
    inherit version src vendorHash;  # <-- inherit it
    # ...
  };
```

Then pass it at the call sites:

```nix
golangci_lint_v1_from_source = mkGolangciLintFromSourceDerivation {
  src = inputs.golangci1-src;
  version = "1.64.8";
  vendorHash = "sha256-<got from the error output above>";
};

golangci_lint_v2_from_source = mkGolangciLintFromSourceDerivation {
  src = inputs.golangci2-src;
  version = "2.5.0";
  vendorHash = "sha256-<got from the error output above>";
};
```

---

### For the prebuilt `sha256s` (tarball hashes)

These are completely separate — they're the hashes of the GitHub release tarballs, not Go modules. Use `nix store prefetch-file`:

```bash
# v1 — fill in each platform you need
nix store prefetch-file \
  "https://github.com/golangci/golangci-lint/releases/download/v1.64.8/golangci-lint-1.64.8-linux-amd64.tar.gz"

nix store prefetch-file \
  "https://github.com/golangci/golangci-lint/releases/download/v1.64.8/golangci-lint-1.64.8-linux-arm64.tar.gz"

nix store prefetch-file \
  "https://github.com/golangci/golangci-lint/releases/download/v1.64.8/golangci-lint-1.64.8-darwin-amd64.tar.gz"

# v2 same pattern, change version
nix store prefetch-file \
  "https://github.com/golangci/golangci-lint/releases/download/v2.5.0/golangci-lint-2.5.0-linux-amd64.tar.gz"
```

Each prints a hash in SRI format. Plug them into the `sha256s` maps:

```nix
sha256s = {
  x86_64-linux  = "sha256-<output of linux-amd64 prefetch>";
  aarch64-linux = "sha256-<output of linux-arm64 prefetch>";
  x86_64-darwin = "sha256-<output of darwin-amd64 prefetch>";
  aarch64-darwin = "sha256-cFQ9IeWwKpQHm+iqESZ6WwYIZVg+M3/naNObXT4vrx8="; # you already have this
};
```

---

## The full order of operations

```
1. nix build .#devShells.x86_64-linux.v1 2>&1 | grep "got:"
   → fills vendorHash for v1

2. nix build .#devShells.x86_64-linux.v2 2>&1 | grep "got:"
   → fills vendorHash for v2

3. nix store prefetch-file <url> for each platform × version combination
   → fills the sha256s maps (8 total: 4 platforms × 2 versions,
     minus the 2 you already have)

4. nix build .#devShells.x86_64-linux.default
   → should succeed now
```

> **Note on cross-platform hashes:** The `vendorHash` is platform-independent — Go module downloads produce the same hash regardless of OS/arch. But the prebuilt tarball hashes *are* platform-specific, which is exactly why `sha256s` is a map. You can run the `nix store prefetch-file` commands from any machine regardless of the target platform.
