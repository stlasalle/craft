class Craft < Formula
  desc "Project orchestration system for autonomous Claude Code agents"
  homepage "https://github.com/stlasalle/craft"
  url "https://github.com/stlasalle/craft/archive/refs/tags/v0.7.5.tar.gz"
  sha256 "e6e39392c77665786df4b852d10c1d71f312de9359a14ce484697d27ae8c7269"
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
