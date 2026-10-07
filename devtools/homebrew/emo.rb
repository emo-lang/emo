# The Homebrew formula for the Emo toolchain. Copy into the project's
# own tap at release time — github.com/emo-lang/homebrew-emo, as
# Formula/emo.rb — filling the two sha256 values from the release's
# SHA256SUMS. The prebuilt archives carry the standard library inside
# the binary, so the formula installs one executable and nothing else;
# homebrew-core comes when the project qualifies for it.

class Emo < Formula
  desc "The Emo programming language toolchain"
  homepage "https://github.com/emo-lang/emo"
  version "1.0.0"
  license "MIT"

  on_arm do
    url "https://github.com/emo-lang/emo/releases/download/v#{version}/emo-v#{version}-macos-arm64.zip"
    sha256 "REPLACE_WITH_ARM64_SHA256"
  end
  on_intel do
    url "https://github.com/emo-lang/emo/releases/download/v#{version}/emo-v#{version}-macos-x86_64.zip"
    sha256 "REPLACE_WITH_X86_64_SHA256"
  end

  def install
    bin.install Dir["emo-v*/bin/emo"].first
  end

  test do
    (testpath / "hello.emo").write('println("Hello, world!")')
    assert_equal "Hello, world!", shell_output("#{bin}/emo run hello.emo").strip
  end
end
