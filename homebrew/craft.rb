class Craft < Formula
  desc "Project orchestration system for autonomous Claude Code agents"
  homepage "https://github.com/stlasalle/craft"
  url "https://github.com/stlasalle/craft/archive/refs/tags/v0.7.6.tar.gz"
  sha256 "76f47911245af8ff0f00e45e0f47824c379b3847818dcb1fc0d599adbea63d81"
  license "MIT"

  depends_on "git"
  depends_on "tmux"
  depends_on "gh"
  depends_on "jq"

  def install
    # Install all craft files into the libexec directory
    libexec.install Dir["*"]
    libexec.install Dir[".gitignore", ".linear.toml"]

    # Create a wrapper that sets CRAFT_ROOT to libexec and projects to ~/.craft
    (bin/"craft").write <<~SH
      #!/usr/bin/env bash
      export CRAFT_ROOT="#{libexec}"
      export CRAFT_PROJECTS="${CRAFT_PROJECTS:-$HOME/.craft/projects}"
      mkdir -p "$CRAFT_PROJECTS"
      exec "#{libexec}/bin/craft" "$@"
    SH
  end

  test do
    assert_match "craft #{version}", shell_output("#{bin}/craft --version")
    assert_match "Required:", shell_output("#{bin}/craft doctor")
  end
end
