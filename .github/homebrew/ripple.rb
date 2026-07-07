# Homebrew formula for `ripple`, published to the dsaad68/homebrew-tap tap.
#
#   brew install dsaad68/tap/ripple
#
# This is a TEMPLATE: the release workflow (.github/workflows/release.yml) substitutes __VERSION__,
# __URL__, and __SHA256__ and pushes the result to the tap on each release. It installs a prebuilt
# Apple Silicon binary from the GitHub Release artifact -- no Xcode needed on the user's machine.
# Edit this template in the source monorepo (page/ripple/.github/homebrew/ripple.rb), not the tap.
class Ripple < Formula
  desc "Experimental batteries-included agent with MLX and Apple Containers, pure Swift"
  homepage "https://github.com/dsaad68/ripple"
  version "__VERSION__"
  url "__URL__"
  sha256 "__SHA256__"
  license "MIT"

  depends_on arch: :arm64
  # macOS 26+ (Tahoe); the Ripple package targets .macOS("26.0").
  depends_on macos: :tahoe

  def install
    # The artifact is the `ripple` binary plus its co-located *.bundle resources (MLX's Metal shader
    # library, model configs). Keep them together in libexec and shim a thin launcher into bin.
    libexec.install "ripple"
    libexec.install Dir["*.bundle"]
    # Re-sign the relocated binary: copying the linker/ad-hoc-signed Mach-O invalidates its
    # signature, so macOS would SIGKILL it at exec ("Code Signature Invalid"). An ad-hoc re-sign
    # restores a valid one.
    system "codesign", "--force", "--sign", "-", libexec/"ripple"
    (bin/"ripple").write_env_script libexec/"ripple", {}
  end

  def caveats
    <<~EOS
      ripple runs a deep agent on-device with MLX (Apple Silicon, macOS 26+).

      Models come from your local Hugging Face cache; ones that aren't already cached are skipped
      rather than downloaded. Pre-fetch a planner first, e.g.:
        hf download LiquidAI/LFM2.5-1.2B-Instruct-MLX-bf16

      The Apple Notes tools ask for Automation permission on first use
      (System Settings > Privacy & Security > Automation).

      Usage:
        ripple              interactive deep-agent REPL
        ripple -p "..."     one-shot, non-interactive run
        ripple run <files>  headless scenario harness
    EOS
  end

  test do
    assert_match "usage:", shell_output("#{bin}/ripple --help 2>&1")
  end
end
